#!/usr/bin/env bash
set -euo pipefail

probe() {
  local result
  if result=$(kubectl --request-timeout=8s exec smoke-client -- python -c '
import json
import sys
from urllib.error import HTTPError
from urllib.request import urlopen

try:
    response = urlopen("http://app-service" + sys.argv[1], timeout=3)
except HTTPError as error:
    response = error
with response:
    try:
        version = json.load(response)["version"]
    except (ValueError, KeyError, TypeError):
        version = "invalid"
    print(response.status, version)
' "$1"); then
    printf '%s\n' "$result"
  else
    echo '000 unavailable'
  fi
}

wait_response() {
  local path=$1 version=$2 result deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    result=$(probe "$path")
    if [[ $result == "200 $version" ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for $path (expected 200 $version, last response: $result)" >&2
  return 1
}

rollout() {
  kubectl rollout status "deployment/app-$1" --timeout=150s
}

setup() {
  kubectl apply -f k8s/deployment.yaml
  rollout blue
  kubectl run smoke-client --image=lab11-app:v1 --image-pull-policy=Never \
    --restart=Never --dry-run=client -o yaml --command -- sleep 3600 | kubectl apply -f -
  kubectl wait --for=condition=Ready pod/smoke-client --timeout=90s
  wait_response / v1
}

workdir=''
monitor_pid=''
watch_pid=''

stop_monitors() {
  if [[ -n $monitor_pid ]]; then
    touch "$workdir/stop"
    wait "$monitor_pid" || true
    monitor_pid=''
  fi
  if [[ -n $watch_pid ]]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
    watch_pid=''
  fi
}

cleanup() {
  stop_monitors
  rm -rf -- "$workdir"
}

experiment() {
  local surge=$1 old=$2 new=$3 start duration success failed
  kubectl patch deployment app-blue --type=merge \
    -p "{\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":$surge,\"maxUnavailable\":0}}}}"
  wait_response / "$old"
  rm -f "$workdir/stop"
  : > "$workdir/requests"
  (
    while [[ ! -f $workdir/stop ]]; do
      probe / >> "$workdir/requests"
      sleep 0.2
    done
  ) &
  monitor_pid=$!
  kubectl get pods -l color=blue -w &
  watch_pid=$!

  until [[ -s $workdir/requests ]]; do
    kill -0 "$monitor_pid"
    sleep 0.1
  done
  start=$(date +%s%3N)
  if ! kubectl set image deployment/app-blue "app=lab11-app:$new" || ! rollout blue; then
    stop_monitors
    kubectl rollout undo deployment/app-blue
    rollout blue
    wait_response / "$old"
    return 1
  fi
  duration=$(awk -v ms="$(( $(date +%s%3N) - start ))" 'BEGIN {printf "%.3f", ms / 1000}')
  probe / >> "$workdir/requests"
  stop_monitors
  read -r success failed < <(awk -v old="$old" -v new="$new" '
    $1 == "200" && ($2 == old || $2 == new) {ok++; next}
    {print "Failed sample: " $0 > "/dev/stderr"}
    END {print ok+0, NR-ok}
  ' "$workdir/requests")
  printf 'ROLLING RESULT: maxSurge=%s, maxUnavailable=0\n' "$surge"
  printf 'Duration: %s seconds\nSuccessful requests: %s\nFailed requests: %s\n' "$duration" "$success" "$failed"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '| %s → %s | %s | 0 | %s | %s | %s |\n' \
      "$old" "$new" "$surge" "$duration" "$success" "$failed" >> "$GITHUB_STEP_SUMMARY"
  fi
  wait_response / "$new"
  echo 'ROLLOUT SUCCESS'
}

rolling() {
  workdir=$(mktemp -d)
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '%s\n' '| Update | maxSurge | maxUnavailable | Duration (s) | Successful requests | Failed requests |' \
      '|---|---:|---:|---:|---:|---:|' >> "$GITHUB_STEP_SUMMARY"
  fi
  experiment 1 v1 v2
  experiment 2 v2 v1
}

switch_service() {
  kubectl patch service app-service --type=merge -p "{\"spec\":{\"selector\":{\"color\":\"$1\"}}}"
}

blue_green() {
  local result code version failed=0 broken_503=0
  [[ $(kubectl get service app-service -o jsonpath='{.spec.selector.color}') == blue ]]
  wait_response / v1
  kubectl scale deployment/app-green --replicas=3
  rollout green
  [[ $(kubectl get deployment app-green -o jsonpath='{.spec.template.spec.containers[0].image}') == lab11-app:v2 ]]
  switch_service green
  wait_response /health v2
  wait_response / v2
  echo 'BLUE-GREEN SUCCESS: Green is active, version=v2'

  kubectl set image deployment/app-blue app=lab11-app:broken
  rollout blue
  switch_service blue
  if ! wait_response /health broken; then
    switch_service green
    wait_response / v2
    return 1
  fi
  for ((i=1; i<=5; i++)); do
    result=$(probe /)
    read -r code version <<< "$result"
    if [[ $code != 200 || $version != broken ]]; then
      failed=$((failed + 1))
      echo "SMOKE FAILED: version=$version, HTTP $code"
    fi
    if [[ $result == '503 broken' ]]; then
      broken_503=$((broken_503 + 1))
    fi
  done
  echo "Failed requests: $failed"
  if (( failed == 0 )); then
    echo 'Smoke test unexpectedly passed; rollback was not triggered.' >&2
    return 1
  fi
  switch_service green
  wait_response /health v2
  wait_response / v2
  kubectl get service app-service -o 'jsonpath=Final selector: {.spec.selector}{"\n"}'
  echo 'ROLLBACK SUCCESS: Green is active, version=v2'
  if (( broken_503 == 0 )); then
    echo 'No HTTP 503 response from the broken version was observed.' >&2
    return 1
  fi
}

case ${1:-} in
  setup) setup ;;
  rolling) rolling ;;
  blue-green) blue_green ;;
  *) echo 'Usage: bash scripts/deploy.sh {setup|rolling|blue-green}' >&2; exit 2 ;;
esac
