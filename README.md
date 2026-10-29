# Acme Health: security review, fixes, rollout and incident response

Century Health DevSecOps take-home. Nothing here was deployed and no AWS account was used.

## Read in this order

| File | Part | What it is |
|---|---|---|
| [`FINDINGS.md`](FINDINGS.md) | 1a, 1b | Sixteen findings ranked by impact on patient data, what I left alone and why, how the scanners did, and the CTO summary |
| [`main.tf`](main.tf) | 2a | The hardened file. `grep "CHANGE:"` shows the edits, `grep "NOT CHANGED"` shows what I held back and why |
| [`GUARDRAIL.md`](GUARDRAIL.md) + [`.github/workflows/`](.github/workflows/terraform-guardrails.yml) | 2b | CI workflow, what it would and would not catch |
| [`ROLLOUT.md`](ROLLOUT.md) | 3 | One-page plan: today, this week, this quarter, with checks, verification and rollback |
| [`INCIDENT.md`](INCIDENT.md) | 4 | Timeline with confidence levels, first 60 minutes, the PHI question, prevention |
| [`AI_LOG.md`](AI_LOG.md) | log | Tools used, what was kept or discarded, and the reflection |

`scans/` has every scanner finding before and after (`results.csv`) and how to reproduce it. `git log` shows the original `main.tf` as the first commit, then the changes.

## The one idea behind Part 2

A fix only goes into this change set if applying it cannot destroy or replace anything, cannot reboot or take anything down, and cannot remove access that something undocumented might still use. The rest is left alone on purpose, with the reason beside the code and the safe path in `ROLLOUT.md`. The clearest example is `storage_encrypted`: it looks like a one-line fix, but it is `ForceNew`, so it would delete the live database.

## Reproduce the checks

```bash
terraform init -backend=false && terraform validate   # no AWS access needed
scripts/tripwires.sh .                                # clean: every exception is acknowledged
scripts/test-plan-gate.sh                             # 7 passed
checkov -d . --framework terraform --baseline .checkov.baseline \
  --skip-check CKV_AWS_144,CKV2_AWS_62                # exit 0 today, fails on new findings
```
