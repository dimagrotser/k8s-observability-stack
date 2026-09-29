#!/usr/bin/env bash
#
# Runs `promtool check rules` over the PrometheusRule CRDs in monitoring/rules.
#
# promtool understands plain Prometheus rule files, not the Kubernetes wrapper,
# so the .spec of each CRD is extracted first.
set -euo pipefail

RULES_DIR="${1:-monitoring/rules}"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

status=0

for manifest in "$RULES_DIR"/*.yaml; do
  [ "$(basename "$manifest")" = "kustomization.yaml" ] && continue

  kind="$(yq -r '.kind' "$manifest")"
  if [ "$kind" != "PrometheusRule" ]; then
    continue
  fi

  extracted="$workdir/$(basename "$manifest")"
  yq -r '.spec' "$manifest" > "$extracted"

  echo "--- $manifest"
  promtool check rules "$extracted" || status=1
done

# --- annotations and runbook anchors --------------------------------------
#
# An alert without a runbook is an alert nobody knows what to do with, and a
# runbook_url pointing at a heading that does not exist is worse than none.
RUNBOOK="${RUNBOOK:-docs/runbook.md}"

for manifest in "$RULES_DIR"/*.yaml; do
  [ "$(basename "$manifest")" = "kustomization.yaml" ] && continue
  [ "$(yq -r '.kind' "$manifest")" = "PrometheusRule" ] || continue

  while IFS=$'\t' read -r name summary description url severity; do
    for field in summary description runbook_url severity; do
      case "$field" in
        summary)     value="$summary" ;;
        description) value="$description" ;;
        runbook_url) value="$url" ;;
        severity)    value="$severity" ;;
      esac
      if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "  FAIL: $name has no $field"
        status=1
      fi
    done

    anchor="${url##*#}"
    if [ -n "$anchor" ] && [ "$anchor" != "null" ]; then
      # GitHub lowercases heading text to build the anchor.
      if ! grep -qi "^## ${anchor}$" "$RUNBOOK"; then
        echo "  FAIL: $name runbook_url points at #$anchor, which is not a heading in $RUNBOOK"
        status=1
      fi
    fi
  done < <(yq -r '.spec.groups[].rules[] | [.alert, .annotations.summary, .annotations.description, .annotations.runbook_url, .labels.severity] | @tsv' "$manifest")
done

if [ "$status" -eq 0 ]; then
  echo "--- every alert has summary, description, severity and a runbook anchor that exists"
fi

exit "$status"
