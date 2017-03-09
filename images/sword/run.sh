#!/bin/bash

set -e
set -u
set -x

readonly namespace="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)"
readonly service_domain="_$SERVICE_PORT._tcp.$SERVICE.$namespace.svc.cluster.local"

redis_info () {
  set +e
  timeout 10 redis-cli -h "$1" -a "$service_domain" info replication
  set -e
}

redis_info_role () {
  echo "$1" | grep -e '^role:' | cut -d':' -f2 | tr -d '[:space:]'
}

server_domains () {
  dig +noall +answer srv "$1" | awk -F' ' '{print $NF}' | sed 's/\.$//g'
}

sentinel_master () {
  redis-cli -p 26379 --raw sentinel master mymaster
}

reset_sentinel () {
  redis-cli -p 26379 --raw sentinel reset mymaster
}

change_ip_sentinel () {
  redis-cli -p 26379 shutdown nosave
  cat /opt/sentinel.template.conf | \
    sed "s/%MASTER%/$1/g" | \
    sed "s/%PASSWORD%/$service_domain/g" \
    > /opt/sentinel.conf
}

domain_ip () {
  dig +noall +answer a "$1" | head -1 | awk -F' ' '{print $NF}'
}

sentinel_num_slaves () {
  echo "$1" | awk '/^num-slaves$/{getline; print}'
}

sentinel_master_down () {
  set +e
  echo "$1" | awk '/^flags$/{getline; print}' | grep -e '[so]_down' > /dev/null
  local -r res="$?"
  set -e
  if [ "$res" = '0' ]; then
    echo 'true'
  else
    echo 'false'
  fi
}

reflect_recreated_servers () {
  local -r servers="$(server_domains "$service_domain")"

  local master_ip=''

  local s
  for s in $servers; do
    local s_ip="$(domain_ip "$s")"

    if [ -z "$s_ip" ]; then
      >&2 echo "Failed to resolve: $s"
      continue
    fi

    local i="$(redis_info "$s_ip")"
    if [ -n "$i" ]; then
      if [ "$(redis_info_role "$i")" = 'master' ]; then
        master_ip="$s_ip"
      fi
    else
      >&2 echo "Unable to get Replication INFO: $s ($s_ip)"
      continue
    fi
  done

  if [ -z "$master_ip" ]; then
    >&2 echo "Master not found."
    return 1
  fi

  change_ip_sentinel "$master_ip"
}

reflect_scale_in () {
  # Resetting during failover causes disastrous result.
  # Be sure to wait enough and once again confirm running Master exists.
  sleep 10

  local -r master="$(sentinel_master)"
  local -r master_down="$(sentinel_master_down "$master")"

  if [ "$master_down" = 'false' ]; then
    reset_sentinel
  fi
}

run () {
  local -r srv_count="$(server_domains "$service_domain" | wc -l)"
  local -r master="$(sentinel_master)"
  local -r num_slaves="$(sentinel_num_slaves "$master")"
  local -r master_down="$(sentinel_master_down "$master")"

  if [ "$num_slaves" = '0' ] && [ "$master_down" = 'true' ]; then
    # If the Redis server StatefulSet is once deleted and created again,
    # Sentinel can't recognize it because Master server the Sentinel knows
    # has now disappeared.
    # To let the Sentinel find the
    reflect_recreated_servers
  elif [ "$(echo "$srv_count - 1" | bc)" -lt "$num_slaves" ]; then
    # If Sentinel recognizes more Slaves than what really exist, the Sentinel
    # might have stale data.
    # This happens when the Redis server StatefulSet is scaled in,
    # such as from 5 replicas to 3 replicas.
    # Sentinel thinks this descrease as failure.
    # To tell that this is not a failure but a scale in, resetting is needed.
    reflect_scale_in
  fi
}

while true; do
  sleep 60
  run
done