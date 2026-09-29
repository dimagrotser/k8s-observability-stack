#!/usr/bin/env bash
#
# Small load generator. No extra tooling: a handful of curl workers hammering
# one URL until the deadline, then a summary of what came back.
#
#   URL=http://demo.localhost:8080/api/items DURATION=60 CONCURRENCY=4 scripts/load.sh
set -euo pipefail

URL="${URL:-http://demo.localhost:8080/api/items}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-4}"

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

echo "load: $CONCURRENCY workers against $URL for ${DURATION}s"

deadline=$(( SECONDS + DURATION ))

for worker in $(seq 1 "$CONCURRENCY"); do
  (
    while [ "$SECONDS" -lt "$deadline" ]; do
      # 000 is curl's own failure (timeout, connection refused). Keeping it in
      # the summary means a broken ingress does not look like zero traffic.
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "$URL" \
        >> "$workdir/worker-$worker" 2>/dev/null || echo "000" >> "$workdir/worker-$worker"
    done
  ) &
done

wait

total=$(cat "$workdir"/worker-* | wc -l | tr -d ' ')
echo "load: $total requests in ${DURATION}s (~$(( total / DURATION )) rps)"
cat "$workdir"/worker-* | sort | uniq -c | awk '{printf "  %s: %s\n", $2, $1}'
