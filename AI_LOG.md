# AI and tools log

## Tools used

| Tool | Version | Used for |
|---|---|---|
| Claude Code (Claude Sonnet 5.5) | desktop app | Drafting, analysis, running the tools below, checking claims against documentation |
| Checkov | 3.3.30 | Scanning `main.tf` before and after (terraform and secrets frameworks) |
| Trivy | 0.76.1 (`trivy config`) | Second scanner, before and after |
| Terraform | 1.10.5 | `fmt` and `validate` (no apply, no AWS access) |
| actionlint, jq | 1.7.12, 1.7.1 | Linting the workflow; the plan-gate logic |
| Claude Code web search and fetch | n/a | AWS docs and Terraform provider source (links in `FINDINGS.md`) |

Nothing was deployed. No AWS account was used.

## How I worked

I used Claude Code for most of the writing and the hands-on work, and I made the judgment calls. The order mattered: the manual review of `main.tf` came **before** any scanner ran, so the scanners were a cross-check and not the source of the findings. Every claim about AWS or Terraform behaviour that a fix depends on was checked against documentation or provider source, not taken from memory.

## Log

| # | Task | Tool | Approach | Used as-is / modified / discarded, and why |
|---|---|---|---|---|
| 1 | Understanding the brief | Claude Code | Asked for a plain-language explanation of the scenario, the problems, and what the assignment is testing | Used for orientation only |
| 2 | First-pass review and severity | Claude Code | Read `main.tf` and drafted candidate findings and severities, before running scanners | **Used, with my approval.** Claude recommended four calls and I approved each: Admin CI identity as #1, landing bucket as High, ship the bucket guardrail flags behind a pre-check, adopt GuardDuty in code with all-severity alerts |
| 3 | Scanner runs | Checkov, Trivy | Ran on the original and on the fixed file; findings tabulated in `scans/results.csv` | **Used as a cross-check.** Discarded the S3 housekeeping noise (18 of Checkov's 59) and the scanners' own advice on `storage_encrypted` and tag immutability, which would break production. Neither scanner flagged several of the worst items (see `FINDINGS.md`) |
| 4 | Verifying behaviour | Claude Code (web fetch) | Checked: how S3 defines a "public" policy, RDS backup-retention outage, `ForceNew` attributes in provider source, `skip_destroy` semantics, RDS Blue/Green encryption and switchover, SCP scope, the HIPAA Security Rule's required vs addressable labels, the breach-notification sections (164.402, 164.404, 164.410), and AWS's HIPAA-eligible services list | **All used.** One was a **correction of the model's assumption**: it had assumed RDS Blue/Green could not encrypt an unencrypted instance. The docs say it can (KMS key on the green side). Adopted as the encryption plan |
| 5 | `main.tf` changes | Claude Code | Drafted the changes with a three-part test for inclusion: no destroy/replace, no reboot, no removal of access something unknown may use. Ran `terraform fmt` and `validate` | **Modified during testing, see #6 and #7** |
| 6 | A mistake caught by testing | Claude Code | First put the new deny statements inside the existing pipeline policy. Scanners then reported its wildcards as fixed. Tested the cause by swapping interpolated ARNs for literals | **Discarded that design.** Moved the denies into a separate policy so the original stays visible and unchanged. Also noted Trivy drops `AWS-0345` whenever any S3 deny is attached |
| 7 | A mistake in my own check | Claude Code | A script comparing Trivy runs read the wrong JSON field, which briefly suggested the tool was non-deterministic | Caught by re-running against the saved output; fixed the script; results were consistent all along |
| 8 | Guardrail workflow | Claude Code | Wrote the workflow, tripwire script and plan gate; tested locally (see `GUARDRAIL.md`) | Used. The static job passed on GitHub (manual run); the plan job has never run against real AWS |
| 9 | `FINDINGS.md`, `ROLLOUT.md`, `INCIDENT.md` | Claude Code | Drafted each from the analysis above; trimmed the rollout from 807 to about 650 words to fit one page | Drafts. See "My review" below |
| 10 | CTO summary and reflection | Claude Code | First drafts | **Mine to rewrite.** See below |

## Decisions I made and directions I gave

- Chose to use scanners and approved installing Checkov and Trivy. Chose to work in checkpoints, where Claude proposes and I decide.
- Approved Claude's four severity and scope recommendations (row 2) at the first checkpoint.
- Decided not to inspect any real AWS account, so nothing from my employer's systems is in this submission.
- Directed the rewrite for shorter, more precise writing, and for a HIPAA reference on each finding.

## Ideas I contributed

During the work I proposed these, and they were checked against documentation before going in:

- **Use a blue/green approach to encrypt the database and then shift traffic.** Verified that RDS Blue/Green supports this, that switchover keeps the same endpoint, and what it needs. Now the encryption plan in `ROLLOUT.md` and `FINDINGS.md` (F6).
- **Move the database password to Secrets Manager.** Already part of the plan; refined with a sequencing catch (Blue/Green doesn't support an RDS-managed Secrets Manager password, so use a self-managed secret first).
- **Restrict the database at the security group, subnet or route-table level.** Layered: security group first (precise, instant, reversible); subnet and route-table changes are the structural end state because they affect everything else in the shared public subnets.
- **Use deny policies and SCPs on the S3 bucket.** Deny policies adopted with a carve-out for our own roles. SCPs kept as a guardrail for internal misconfiguration, with the limit noted: they don't apply to anonymous partners or to the management account.
- **Put the master keys in a secured store with restricted access.** Adopted: Secrets Manager plus a KMS key policy, with an SCP or permissions boundary as the outer fence. Better still for the admin key: remove it (OIDC) rather than store it.

## My review

**[TODO before sending: replace this section with what you really did. Be specific and honest. A good version names things you read, tested, changed or disagreed with.]**

- Parts of the work I read line by line and understood:
- Things I changed or rejected, and why:
- Things I checked myself (commands I ran, docs I read):
- Things I'm least sure about:
- Time I actually spent:

## Reflection: with another hour

**[TODO before sending: rewrite these in your own words and add your own. The ones below are true of the work as it stands.]**

- Run the plan gate against a sandbox AWS account or LocalStack. The static job has run on GitHub (one manual run); the plan job never has, and the `pull_request` trigger is untested.
- Confirm the S3 "non-public policy" behaviour with `get-bucket-policy-status` on a real bucket. I relied on AWS's documentation.
- Pin the Actions to commit SHAs, add a secret scanner for git history, and move the tripwires from line patterns to policy-as-code over the plan JSON.
- Write the Blue/Green runbook as concrete commands and rehearse it on a copy, checking every table has a primary key.
- Give the alert topic a proper KMS key and key policy instead of leaving it unencrypted.
- Put the CTO paragraph in front of a non-technical reader, and put real costs (data events, GuardDuty, Multi-AZ) next to the recommendations.
