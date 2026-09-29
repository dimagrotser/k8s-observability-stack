#!/usr/bin/env bash
#
# Makes HighErrorRate fire, end to end: turn the chaos knob up, drive traffic,
# and watch the alert move inactive -> pending -> firing, then show what
# Alertmanager did with it.
#
# The alert has `for: 5m` and a 5m rate window, so this takes roughly six
# minutes. That is the point: an alert that fires instantly is an alert that
# pages on every blip.
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo-dev}"
DEPLOYMENT="${DEPLOYMENT:-demo-api}"
ALERT="${ALERT:-HighErrorRate}"
DEMO_ERROR_RATE="${DEMO_ERROR_RATE:-0.5}"
BASE_URL="${BASE_URL:-http://demo.localhost:8080}"
PROM_URL="${PROM_URL:-http://prometheus.localhost:8080}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://alertmanager.localhost:8080}"
TIMEOUT="${TIMEOUT:-600}"

here="$(cd "$(dirname "$0")" && pwd)"
load_pid=""

cleanup() {
  if [ -n "$load_pid" ] && kill -0 "$load_pid" 2>/dev/null; then
    kill "$load_pid" 2>/dev/null || true
    wait "$load_pid" 2>/dev/null || true
  fi

  echo
  echo "resetting ERROR_RATE to 0"
  kubectl -n "$NAMESPACE" set env "deploy/$DEPLOYMENT" ERROR_RATE=0 >/dev/null
  echo "the alert resolves on its own once the error rate drops"
}
trap cleanup EXIT

alert_state() {
  curl -sfG "$PROM_URL/api/v1/rules" --data-urlencode 'type=alert' 2>/dev/null \
    | jq -r --arg a "$ALERT" '[.data.groups[].rules[] | select(.name == $a) | .state] | first // "unknown"'
}

error_rate_now() {
  curl -sfG "$PROM_URL/api/v1/query" --data-urlencode \
    'query=100 * sum(rate(http_request_errors_total{job="demo-api", route!~"/health|/ready|/metrics"}[5m])) / sum(rate(http_requests_total{job="demo-api", route!~"/health|/ready|/metrics"}[5m]))' \
    2>/dev/null | jq -r '.data.result[0].value[1] // "n/a"'
}

# printf with %f on a non-numeric value still prints something and then returns
# non-zero, so the error rate has to be checked before it is formatted rather
# than relying on printf failing.
report() {
  local elapsed="$1" text="$2" rate
  rate="$(error_rate_now)"

  case "$rate" in
    ''|n/a|null|NaN)
      printf '  [%3ds] %s\n' "$elapsed" "$text"
      ;;
    *)
      printf '  [%3ds] %s (error rate %.1f%%)\n' "$elapsed" "$text" "$rate"
      ;;
  esac
}

echo "==> setting ERROR_RATE=$DEMO_ERROR_RATE on deploy/$DEPLOYMENT"
kubectl -n "$NAMESPACE" set env "deploy/$DEPLOYMENT" ERROR_RATE="$DEMO_ERROR_RATE" >/dev/null
kubectl -n "$NAMESPACE" rollout status "deploy/$DEPLOYMENT" --timeout=120s

echo "==> starting load for up to ${TIMEOUT}s"
URL="$BASE_URL/api/items" DURATION="$TIMEOUT" CONCURRENCY=4 "$here/load.sh" >/dev/null &
load_pid=$!

echo "==> waiting for $ALERT (expect pending in about a minute, firing after its 5m hold)"

started=$SECONDS
last_state=""

while [ $(( SECONDS - started )) -lt "$TIMEOUT" ]; do
  state="$(alert_state)"
  elapsed=$(( SECONDS - started ))

  if [ "$state" != "$last_state" ]; then
    report "$elapsed" "${last_state:-inactive} -> $state"
    last_state="$state"
  elif [ $(( elapsed % 30 )) -lt 5 ]; then
    report "$elapsed" "still $state"
  fi

  if [ "$state" = "firing" ]; then
    echo
    echo "==> $ALERT is firing in Prometheus"
    echo
    echo "--- Alertmanager ---"
    curl -sf "$ALERTMANAGER_URL/api/v2/alerts" \
      | jq -r '.[] | select(.labels.alertname != "Watchdog")
               | "  \(.labels.alertname)  severity=\(.labels.severity)  state=\(.status.state)\n    \(.annotations.summary)\n    runbook: \(.annotations.runbook_url)"'
    echo
    echo "--- routing ---"
    curl -sf "$ALERTMANAGER_URL/api/v2/alerts/groups" \
      | jq -r '.[] | select(.labels.alertname != "Watchdog")
               | "  receiver=\(.receiver.name)  group=\(.labels | to_entries | map("\(.key)=\(.value)") | join(","))"'
    exit 0
  fi

  sleep 5
done

echo
echo "gave up after ${TIMEOUT}s, $ALERT never reached firing"
exit 1
