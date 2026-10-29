#!/usr/bin/env bash
# Tests plan-gate.sh against hand-written plan JSON. No AWS needed.
# Run: scripts/test-plan-gate.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0

check() { # $1 name, $2 expected exit code, $3 plan json, rest = allow-list
  local name="$1" want="$2" json="$3"; shift 3
  printf '%s' "$json" > "$tmp/plan.json"
  set +e; "$here/plan-gate.sh" "$tmp/plan.json" "$@" > "$tmp/out.txt" 2>&1; got=$?; set -e
  if [ "$got" -eq "$want" ]; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (wanted exit $want, got $got)"; cat "$tmp/out.txt"; fi
}

# The scenario this exists for: someone sets storage_encrypted = true.
check "RDS replacement is blocked" 1 \
  '{"resource_changes":[{"address":"aws_db_instance.clinical","type":"aws_db_instance","change":{"actions":["delete","create"]}}]}' \
  aws_ecs_task_definition

check "RDS replacement (create-before-destroy order) is blocked" 1 \
  '{"resource_changes":[{"address":"aws_db_instance.clinical","type":"aws_db_instance","change":{"actions":["create","delete"]}}]}' \
  aws_ecs_task_definition

check "plain delete is blocked" 1 \
  '{"resource_changes":[{"address":"aws_s3_bucket.audit_logs","type":"aws_s3_bucket","change":{"actions":["delete"]}}]}'

check "task definition replacement is allowed" 0 \
  '{"resource_changes":[{"address":"aws_ecs_task_definition.document_parser","type":"aws_ecs_task_definition","change":{"actions":["delete","create"]}}]}' \
  aws_ecs_task_definition

check "in-place updates and creates pass" 0 \
  '{"resource_changes":[{"address":"aws_db_instance.clinical","type":"aws_db_instance","change":{"actions":["update"]}},{"address":"aws_sns_topic.x","type":"aws_sns_topic","change":{"actions":["create"]}}]}' \
  aws_ecs_task_definition

check "empty plan passes" 0 '{}' aws_ecs_task_definition

check "allowed AND blocked in one plan: still blocked" 1 \
  '{"resource_changes":[{"address":"aws_ecs_task_definition.a","type":"aws_ecs_task_definition","change":{"actions":["delete","create"]}},{"address":"aws_db_instance.clinical","type":"aws_db_instance","change":{"actions":["delete","create"]}}]}' \
  aws_ecs_task_definition

echo; echo "plan-gate tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
