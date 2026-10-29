#!/usr/bin/env bash
# plan-gate.sh: fail if a Terraform plan deletes or replaces anything that is
# not on the allow-list of resource types where that is expected.
#
# Usage: scripts/plan-gate.sh plan.json [allowed_resource_type ...]
#   plan.json comes from:  terraform show -json tfplan
#
# Why a script and not inline YAML: it can be tested without AWS (see
# scripts/test-plan-gate.sh) and run on a laptop before pushing.

set -euo pipefail

plan="${1:?usage: plan-gate.sh plan.json [allowed_type ...]}"
shift
allow_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)

blocked=$(jq -r --argjson allow "$allow_json" '
  (.resource_changes // [])[]
  | select(.change.actions | index("delete"))
  | select((.type as $t | $allow | index($t)) | not)
  | "  \(.address)  [\(.change.actions | join(","))]"
' "$plan")

if [ -n "$blocked" ]; then
  echo "plan-gate: this plan deletes or replaces resources that are not on the allow-list:"
  echo "$blocked"
  echo
  echo "If a replacement is truly intended, get a second reviewer and a rollout note first (see ROLLOUT.md)."
  exit 1
fi

echo "plan-gate: no unexpected deletes or replacements."
