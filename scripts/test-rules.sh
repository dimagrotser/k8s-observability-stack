#!/usr/bin/env bash
#
# Runs `promtool test rules` over the unit tests in monitoring/rules/tests.
#
# Same trick as check-rules.sh: promtool wants plain rule files, so the .spec of
# each PrometheusRule is extracted into a scratch directory. The test files are
# copied in beside them, which is why they can reference the rule files by bare
# name.
set -euo pipefail

RULES_DIR="${1:-monitoring/rules}"
TESTS_DIR="${2:-monitoring/rules/tests}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

for manifest in "$RULES_DIR"/*.yaml; do
  [ "$(basename "$manifest")" = "kustomization.yaml" ] && continue
  [ "$(yq -r '.kind' "$manifest")" = "PrometheusRule" ] || continue
  yq -r '.spec' "$manifest" > "$workdir/$(basename "$manifest")"
done

cp "$TESTS_DIR"/*.yaml "$workdir/"

status=0
for test_file in "$TESTS_DIR"/*.yaml; do
  echo "--- $test_file"
  promtool test rules "$workdir/$(basename "$test_file")" || status=1
done

exit "$status"
