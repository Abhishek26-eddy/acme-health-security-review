#!/usr/bin/env bash
# tripwires.sh: catch the specific mistakes that Checkov 3.3.30 and Trivy 0.76.1
# did NOT flag on Acme's main.tf (see FINDINGS.md, "What the scanners missed").
#
# This is deliberately blunt: line-level pattern checks, no HCL parsing. It
# exists to make a human look, not to be clever. A hit fails the build unless
# the SAME line carries `tripwire:ack` and a reason, for example:
#     publicly_accessible = true # tripwire:ack removal planned, see ROLLOUT.md
# The ack shows up in the pull request diff, so a new one gets reviewed.
#
# Usage: scripts/tripwires.sh [directory]   (default: current directory)
# Exit:  0 = nothing unacknowledged, 1 = at least one hit.

set -uo pipefail

root="${1:-.}"
files=$(find "$root" -name '*.tf' -not -path '*/.terraform/*' | sort)
if [ -z "$files" ]; then
  echo "tripwires: no .tf files under $root"
  exit 0
fi

failures=0

report() { # $1 id, $2 why, $3 hits
  if [ -n "$3" ]; then
    failures=$((failures + 1))
    printf '\n[%s] %s\n%s\n' "$1" "$2" "$3"
  fi
}

# Single-line rule. Skips comment-only lines and acknowledged lines.
# NB: patterns avoid backslashes on purpose: awk -v processes escapes.
line_rule() { # $1 id, $2 why, $3 extended regex
  local hits
  hits=$(awk -v re="$3" '
    /^[[:space:]]*#/            { next }
    /tripwire:ack/              { next }
    $0 ~ re { printf "  %s:%d: %s\n", FILENAME, FNR, $0 }
  ' $files)
  report "$1" "$2" "$hits"
}

line_rule TW02 'Wildcard principal in a resource policy. Anonymous access is only as good as its conditions.' \
  'Principal[[:space:]]*=[[:space:]]*"[*]"|"AWS"[[:space:]]*:[[:space:]]*"[*]"'

line_rule TW03 'AdministratorAccess attached. Applying Terraform needs wide rights, not all rights.' \
  'AdministratorAccess'

line_rule TW04 'GitHub OIDC "sub" claim contains a wildcard: any matching repo/branch/PR can assume the role.' \
  ':sub"[[:space:]]*=.*[*]'

line_rule TW05 'DEBUG logging. In the document parser this writes the text of every page (PHI) to CloudWatch.' \
  '"DEBUG"'

line_rule TW06 'Long-lived IAM user or access key. Use roles (OIDC) so there is no secret to steal.' \
  'resource[[:space:]]+"aws_iam_(user|access_key)"'

line_rule TW07 'Database/instance publicly_accessible = true.' \
  'publicly_accessible[[:space:]]*=[[:space:]]*true'

line_rule TW08 'Storage encryption disabled. On an existing RDS instance, flipping it later REPLACES the instance.' \
  'storage_encrypted[[:space:]]*=[[:space:]]*false'

line_rule TW09 'force_destroy = true on a bucket: a destroy empties and deletes it, audit logs included.' \
  'force_destroy[[:space:]]*=[[:space:]]*true'

line_rule TW11 'skip_final_snapshot = true: deleting the database leaves no snapshot behind.' \
  'skip_final_snapshot[[:space:]]*=[[:space:]]*true'

line_rule TW12 'Automated backups off (backup_retention_period = 0).' \
  'backup_retention_period[[:space:]]*=[[:space:]]*0([^0-9]|$)'

line_rule TW14 'An S3 public access block flag is false.' \
  '(block_public_acls|ignore_public_acls|block_public_policy|restrict_public_buckets)[[:space:]]*=[[:space:]]*false'

line_rule TW15 'CloudTrail single-region or without log file validation.' \
  'is_multi_region_trail[[:space:]]*=[[:space:]]*false|enable_log_file_validation[[:space:]]*=[[:space:]]*false'

# TW01: any security-group INGRESS rule open to the whole internet (multi-line).
hits=$(awk '
  FNR == 1                                  { inb = 0; depth = 0 }
  /^[[:space:]]*#/                          { next }
  /^[[:space:]]*ingress[[:space:]]*[{]/     { inb = 1; depth = 0 }
  inb {
    o = gsub(/[{]/, "{"); c = gsub(/[}]/, "}"); depth += o - c
    if ($0 ~ /(0[.]0[.]0[.]0\/0|::\/0)/ && $0 !~ /tripwire:ack/)
      printf "  %s:%d: %s\n", FILENAME, FNR, $0
    if (depth <= 0) inb = 0
  }
' $files)
report TW01 'Security-group ingress open to the internet (0.0.0.0/0 or ::/0).' "$hits"

# TW10: a secret-looking variable with a real default value (multi-line).
hits=$(awk '
  FNR == 1 { inv = 0; depth = 0 }
  /^[[:space:]]*#/ { next }
  {
    l = tolower($0)
    if (l ~ /^variable[[:space:]]+"[^"]*(password|secret|token|api_key|private_key)[^"]*"/) { inv = 1; depth = 0 }
  }
  inv {
    o = gsub(/[{]/, "{"); c = gsub(/[}]/, "}"); depth += o - c
    if ($0 ~ /^[[:space:]]*default[[:space:]]*=[[:space:]]*"[^"]+"/ && $0 !~ /tripwire:ack/)
      printf "  %s:%d: %s\n", FILENAME, FNR, $0
    if (depth <= 0) inv = 0
  }
' $files)
report TW10 'A password/secret variable has a hard-coded default. It lives in git history forever.' "$hits"

echo
if [ "$failures" -gt 0 ]; then
  echo "tripwires: $failures rule(s) hit. Fix the code, or add 'tripwire:ack <reason>' on the line if it is a known, tracked exception."
  exit 1
fi
echo "tripwires: clean (everything flagged is acknowledged on its line)."
exit 0
