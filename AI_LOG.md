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
| Devin (Cognition) | desktop app | Second opinion on eight follow-up questions about the work; first draft of this review section and the CTO paragraph |

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
| 10 | CTO summary and reflection | Claude Code, then Devin | Claude's first drafts; Devin redrafted the CTO paragraph to five sentences and drafted "My review" from facts I supplied (time, what I read, what I ran) | **Edited by me before sending** |

## Decisions I made and directions I gave

- Chose to use scanners and approved installing Checkov and Trivy. Chose to work in checkpoints, where Claude proposes and I decide.
- Approved Claude's four severity and scope recommendations (row 2) at the first checkpoint.
- Decided not to inspect any real AWS account, so nothing from my employer's systems is in this submission.
- Directed the rewrite for shorter, more precise writing, and for a HIPAA reference on each finding.

## Answers to the eight follow-up problems

I put the eight questions to a second assistant (Devin) for an independent answer, then went through each answer and decided what to adopt. Claude checked the adopted points against documentation and built the changes. Two of those answers found flaws in Claude's draft plan, which is the main reason I asked a second tool:

1. The rollout attached the new narrow policy beside the old one and ran a night with both. IAM permissions add up, so that tests nothing. Replaced with a v2 role and repointing Airflow.
2. The rollout added exact OIDC `sub` values beside the wildcard. That is an OR, so it proves nothing. Replaced with a second role.

Other changes adopted from those answers: S3 data events on all buckets before narrowing anything; `RunTask` and `PassRole` are probably unnecessary on the parser role; check whether partners ever read the landing bucket and whether any share a /24; pin the GitHub trust by `repository_id` and a GitHub Environment; a plan for the PHI already in the logs (restrict access, map every sink, retention under legal hold); alert routing, CloudTrail rules for high-risk calls and an on-call check; database audit logging with `pgaudit`, including its reboot and statement-text risks; root MFA and account-wide S3 Block Public Access as the two cheapest controls; a Deny-all at T+3 in the incident and when to reorder the first steps.

Claude's checks and adjustments: `repository_id` is a supported AWS condition key. AWS's docs don't confirm that reads of CloudWatch log events appear in CloudTrail, so the documents say "can't prove" instead of stating it. Two details were adjusted: `ListBucket` is granted on the bucket ARN with a prefix condition, and the role a task runs as comes from its task definition, unless overridden.

## Ideas I contributed

During the work I proposed these, and they were checked against documentation before going in:

- **Use a blue/green approach to encrypt the database and then shift traffic.** Verified that RDS Blue/Green supports this, that switchover keeps the same endpoint, and what it needs. Now the encryption plan in `ROLLOUT.md` and `FINDINGS.md` (F6).
- **Move the database password to Secrets Manager.** Already part of the plan; refined with a sequencing catch (Blue/Green doesn't support an RDS-managed Secrets Manager password, so use a self-managed secret first).
- **Restrict the database at the security group, subnet or route-table level.** Layered: security group first (precise, instant, reversible); subnet and route-table changes are the structural end state because they affect everything else in the shared public subnets.
- **Use deny policies and SCPs on the S3 bucket.** Deny policies adopted with a carve-out for our own roles. SCPs kept as a guardrail for internal misconfiguration, with the limit noted: they don't apply to anonymous partners or to the management account.
- **Put the master keys in a secured store with restricted access.** Adopted: Secrets Manager plus a KMS key policy, with an SCP or permissions boundary as the outer fence. Better still for the admin key: remove it (OIDC) rather than store it.

## My review

- **What I read line by line and can explain without notes:** every `CHANGE:` and `NOT CHANGED` in `main.tf`, and why each one passes the three-part test. Same for `ROLLOUT.md`, including why `skip_destroy` has to go live one apply before the log level flips.
- **What I read but not line by line:** `INCIDENT.md` and the guardrail scripts (`tripwires.sh`, `plan-gate.sh`, the workflow). I know what they do and why. I couldn't walk you through every line yet.
- **What I changed or threw out:** both scanners said set `storage_encrypted = true`. That's `ForceNew`, so it'd delete the database. No. Same with immutable ECR tags, which break the legacy builds. I dropped the first version of the pipeline denies too: once they sat inside the old policy, the scanners stopped flagging its wildcards. And I replaced two rollout steps ("run both policies for a night", "add the exact `sub` next to the wildcard") because neither one actually tests anything.
- **What I checked myself:** ran `terraform fmt` and `terraform validate`. Kicked off the workflow on GitHub (`workflow_dispatch`) and watched the static job go green. Read the AWS and provider docs behind the three riskiest calls: `ForceNew` on `storage_encrypted`, Blue/Green encryption, and what S3 counts as a public policy.
- **What I'm least sure about:** the plan gate's never run against real AWS. I haven't seen `get-bucket-policy-status` say `IsPublic: false` for our two /24s on a real bucket. I don't know if GuardDuty Extended Threat Detection would've caught the Part 4 chain. And the HIPAA breach-notice reasoning is really counsel's call, not mine.
- **Time:** under 4 hours. Honestly, that's only possible because AI did most of the drafting and the tool runs. My time went on the decisions, and on double-checking anything that could break prod.

## Reflection: with another hour

- Run the plan gate against a sandbox account or LocalStack. It's the check I lean on most to stop a destructive apply, and it's never run for real. The `pull_request` trigger's untested too.
- Read `INCIDENT.md` and the scripts as closely as I read `main.tf`. I'll get asked about them.
- Put the same IP-only policy on a throwaway bucket and run `get-bucket-policy-status`. The landing-bucket change rests on AWS's definition of "public", and so far I've only read about it.
- Turn the Blue/Green encryption into an actual runbook and rehearse it on a copy, starting with "does every table have a primary key?"
- Pin the Actions to commit SHAs, run gitleaks over history (the DB password's already in there), and give the alert topic its own KMS key.
- Put monthly costs next to the asks (data events, GuardDuty, Multi-AZ, Transfer Family). A CTO decides on numbers, not adjectives.
