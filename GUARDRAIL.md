# Guardrail (Part 2b)

Files: [workflow](.github/workflows/terraform-guardrails.yml), [`scripts/tripwires.sh`](scripts/tripwires.sh), [`scripts/plan-gate.sh`](scripts/plan-gate.sh) and its [tests](scripts/test-plan-gate.sh), [`.checkov.baseline`](.checkov.baseline).

## What runs on every pull request

| Step | What it does |
|---|---|
| `fmt`, `init -backend=false`, `validate` | Syntax, references, types. No AWS access needed. |
| Checkov against a baseline | Fails only on new findings. Today's debt is in `.checkov.baseline`, so the job can be switched on without being red forever. Two noise checks skipped (replication, event notifications). |
| Tripwires | A short script for what the scanners missed on this file: open ingress, wildcard principals, `AdministratorAccess`, wildcard OIDC `sub`, `DEBUG`, IAM keys, public or unencrypted DB, `force_destroy`, a password default. A hit fails the build unless the same line carries `tripwire:ack <reason>`, which a reviewer then sees in the diff. |
| Plan gate (optional job) | `terraform plan` with a read-only role; fails if anything is deleted or replaced outside an allow-list. Skipped until `PLAN_ROLE_ARN` is set. |

## What it would have caught here

| Mistake | Caught by |
|---|---|
| `storage_encrypted = true`, which destroys the live database | Plan gate (delete + create). Also `prevent_destroy`. Neither scanner can catch this. |
| A new `0.0.0.0/0` rule on 5432 | Tripwire TW01 (neither scanner flagged the original) |
| A bucket policy edited to `Principal "*"` | TW02 |
| Another admin attachment, or a wildcard `sub` | TW03, TW04 |
| `LOG_LEVEL` back to `DEBUG` | TW05 |
| A new IAM user or key | TW06 |
| A new bucket without a public access block, versioning, etc. | Checkov (baseline) |
| Unformatted or invalid Terraform | fmt, validate |

On the original file the tripwires hit all 14 rules. On the fixed file they report only the debt I left on purpose, each acknowledged on its own line.

## What it would not catch

- **Meaning.** It can't see that `GetObject` on the whole bucket lets one partner read another's PHI, or that a policy is broader than the role needs.
- **The live account.** Console changes and drift are invisible. It reads code and a plan.
- **Whether a removal is safe.** It can't know an analyst's laptop uses port 5432. That needs the evidence steps in `ROLLOUT.md`.
- **Rollout order.** It wouldn't notice that `skip_destroy` must land before the log-level change.
- **Secrets already in git history.** Add a secret scanner such as gitleaks. Checkov's secrets scan found nothing on the original.
- **False greens.** Both scanners skip policies containing references they can't resolve.
- **Evasion.** The tripwires are line patterns; a CIDR built from a variable walks past them. They make a person look; they aren't clever.
- **Edits to the guardrail itself.** It only protects `main` if it is a required status check and CODEOWNERS covers `.github/`, `scripts/` and `.checkov.baseline`. A change to the baseline deserves its own review.

## Tested, and not tested

Tested locally: tripwires on the original (14 of 14 rules hit) and the fixed file (clean after acknowledgements); the Checkov baseline (current code exits 0, a deliberately bad new bucket exits 1); the plan gate (7 cases, both replacement orderings); the workflow with `actionlint`; `terraform fmt` and `validate`.

Not tested: a real run on GitHub, and the plan job against real AWS. Actions are pinned to major-version tags, not commit SHAs; pin them before relying on this. The plan job runs the pull request's Terraform with a role, so the role must be read-only and trust only this repo's `pull_request` events (never `pull_request_target`).
