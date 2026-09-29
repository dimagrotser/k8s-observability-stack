#!/usr/bin/env bash
#
# Small load generator. No extra tooling: a handful of curl workers hammering
# one URL until the deadline, then a summary of what came back.
#
#   URL=http://demo.localhost:8080/api/items DURATION=60 CONCURRENCY=2 scripts/load.sh
#
# The pacing matters. Left unthrottled on a laptop this saturates the node,
# Grafana starts failing its probes and the dashboards you wanted to watch stop
# answering. A steady ~40 rps is far more than enough to hold an error rate
# above any threshold in this project.
set -euo pipefail

URL="${URL:-http://demo.localhost:8080/api/items}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-2}"
# Seconds between requests per worker. Set to 0 to go as fast as the box allows.
DELAY="${DELAY:-0.05}"

workdir="$(mktemp -d)"

cleanup() {
  # Stop the workers before the scratch directory goes away. Removing it first
  # leaves them writing to files that no longer exist, which is noisy and
  # pointless when this script is killed by a caller such as demo-alert.sh.
  local pids
  pids="$(jobs -p)"
  if [ -n "$pids" ]; then
    kill $pids 2>/dev/null || true
    wait 2>/dev/null || true
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT INT TERM

echo "load: $CONCURRENCY workers against $URL for ${DURATION}s, ${DELAY}s between requests"

deadline=$(( SECONDS + DURATION ))

for worker in $(seq 1 "$CONCURRENCY"); do
  (
    while [ "$SECONDS" -lt "$deadline" ]; do
      # 000 is curl's own failure (timeout, connection refused). Keeping it in
      # the summary means a broken ingress does not look like zero traffic.
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "$URL" \
        >> "$workdir/worker-$worker" 2>/dev/null || echo "000" >> "$workdir/worker-$worker"

      if [ "$DELAY" != "0" ]; then
        sleep "$DELAY"
      fi
    done
  ) &
done

wait

total=$(cat "$workdir"/worker-* | wc -l | tr -d ' ')
echo "load: $total requests in ${DURATION}s (~$(( total / DURATION )) rps)"
cat "$workdir"/worker-* | sort | uniq -c | awk '{printf "  %s: %s\n", $2, $1}'
