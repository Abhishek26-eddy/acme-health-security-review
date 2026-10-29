# Findings: Acme Health `main.tf`

I read the file first and wrote down my concerns before running any tool. Then I ran Checkov 3.3.30 and Trivy 0.76.1 as a cross-check, and checked the AWS and Terraform behaviour that each fix depends on against AWS's documentation and the provider source (links at the end).

Severity is the realistic damage to patient data and how many steps an attacker needs, not a scanner label. Critical: a short path to full compromise or loss of PHI. High: serious, but needs one more weakness. Medium: weakens defence or recovery. Low: hygiene.

## 1a. Findings

The three Critical findings (F1 to F3) are the ones Part 2 does not change. That is deliberate: each needs evidence or a coordinated step first, and the reasons and the safe order are in `ROLLOUT.md`. Part 2 fixes what can be fixed safely in one apply.

| ID | Severity | Finding | After Part 2 | HIPAA hook (45 CFR) |
|---|---|---|---|---|
| F1 | Critical | `ci-deployer`: permanent admin key, secret in state | Not changed (live pipelines use it) | 164.312(a)(2)(i), (d) |
| F2 | Critical | GitHub deploy role: any repo in the org becomes admin | Not changed (could lock out our own deploys) | 164.312(a)(1); 164.308(a)(4) |
| F3 | Critical | Clinical DB reachable from the internet | Not changed; groundwork added | 164.312(a)(1); 164.308(a)(1)(ii)(B) |
| F4 | High | Landing bucket: anonymous principal, IP-only, every partner can read every partner | Guardrail flags on, data events added | 164.502(b); 164.312(a)(1) |
| F5 | High | DB password: default in code, plaintext in task definition, master user | Hidden from plans; rotation planned | 164.312(a)(1), (d) |
| F6 | High | DB: no encryption, no backups, no delete protection | Delete protection, final snapshot added | 164.308(a)(7)(ii)(A) *required*; 164.312(a)(2)(iv) |
| F7 | High | Pipeline role: `s3:*`, all secrets, any role, on `*` | Two deny guardrails added | 164.308(a)(4); 164.502(b) |
| F8 | High | `LOG_LEVEL=DEBUG` writes patient text to CloudWatch | Prepared; flip is the next apply | 164.502(b); 164.312(a)(1) |
| F9 | High | Weak audit trail; audit bucket can be wiped | Fixed | 164.312(b), (c)(1) |
| F10 | High | No alerting; GuardDuty not in code, routes nowhere | Fixed in code; needs a subscriber | 164.308(a)(1)(ii)(D) *required* |
| F11 | Medium | Terraform state: secrets in plaintext, no locking | Not changed | 164.312(a)(1), (c)(1) |
| F12 | Medium | ECR: mutable tags, `:latest`, no scanning | Scanning on | 164.312(c)(1) |
| F13 | Medium | Open egress from the parser | Not changed | 164.312(e)(1) |
| F14 | Medium | Single AZ, random maintenance window | Windows pinned | 164.308(a)(7)(ii)(B), (C) |
| F15 | Low | Container runs as root with a writable filesystem | Not changed | 164.308(a)(1)(ii)(B) |
| F16 | Low | Housekeeping: CMKs, retention, lifecycle | Not changed | 164.316(b)(2)(i) |

### F1. Critical: `ci-deployer` is a permanent admin key

Where: `aws_iam_user.ci_deployer`, its admin attachment, `aws_iam_access_key.ci_deployer`, both outputs.

The key never expires, isn't tied to a network or repo, and its secret is stored in plaintext in state (`sensitive = true` only hides it from the terminal). Two legacy pipelines use it, so nobody wants to touch it. Whoever gets the key can read every partner file, copy the database, create their own admin user and delete the audit trail. It is the entry point in Part 4.

Fix: move both pipelines to the OIDC role, deactivate the key, delete it after a quiet week, then remove the user, attachment, key and outputs from code.

Part 2: not changed. Removing the resource deletes the key in the same apply and breaks two live pipelines.

### F2. Critical: any repo in the GitHub org can become admin

Where: `aws_iam_role.github_deploy` and its admin attachment.

The trust policy accepts any token whose `sub` matches `repo:acme-health/*`: every repo, every branch, including pull requests. The role is `AdministratorAccess`. Anyone who can open a PR in any repo in the org can add a workflow, assume the role and own the account.

Fix: pin `sub` to the infrastructure repo and `ref:refs/heads/main` (or a GitHub Environment with reviewers). Split a read-only plan role (pull requests) from a scoped apply role (main).

Part 2: not changed on purpose. This role applies this code. A wrong guess at the repo or branch name locks out the next apply and any rollback. The real `sub` values are in CloudTrail (`AssumeRoleWithWebIdentity`).

### F3. Critical: the clinical database is reachable from the internet

Where: `aws_db_instance.clinical` (`publicly_accessible`), `aws_security_group.db` (5432 from `0.0.0.0/0`), `aws_db_subnet_group.clinical` (public subnets). `private_subnet_ids` is declared and never used.

Subnets, public address and firewall all say yes. The only barrier is the password, which is the default committed in code (F5). Anyone with that password, from the repo, state or ECS console, can connect from anywhere and dump the database. With no query logging, nobody would see it.

Fix: record who really connects (Flow Logs, a week), remove `0.0.0.0/0`, allow the pipeline security group and a named admin path, then set `publicly_accessible = false` and move the instance to private subnets.

Part 2: not changed. Something outside the pipeline probably connects (an analyst, a BI tool, Airflow) and nothing records who. I added the pipeline's own security-group rule beside the open one, so removing the open rule later is a pure deletion. Moving subnets isn't an in-place edit: AWS won't drop a subnet the instance is using.

### F4. High: the landing bucket trusts "anyone, from these IPs"

Where: `aws_s3_bucket_policy.raw_landing`, `aws_s3_bucket_public_access_block.raw_landing`.

The policy grants `Principal "*"` with only a source-IP condition. An IP is a location, not an identity. It allows `GetObject` and `ListBucket` on the whole bucket, although each partner is meant to write under `incoming/<partner_id>/`, so any partner can read every other partner's PHI. `block_public_policy` and `restrict_public_buckets` were false, so one edit dropping the IP condition would make the bucket public and S3 would allow it. Reads aren't logged.

I rate it High, not Critical: it isn't world-readable today (two /24s). It becomes Critical if those ranges are shared hosting space.

Fix: give each partner an authenticated path scoped to its own prefix (a role in their account, SFTP with per-partner directories, or pre-signed URLs). Interim: one statement per partner allowing only `incoming/<partner_id>/*` from that partner's ranges. Any explicit Deny must carve out our pipeline and break-glass roles, because a bucket Deny also hits our own principals. An SCP can't fix this: SCPs don't apply to anonymous callers.

Part 2: both flags set to true. Per the S3 docs, a policy granting only narrow fixed `aws:SourceIp` ranges (nothing wider than a /8) is non-public, so partners are unaffected. Gate: `aws s3api get-bucket-policy-status` must return `IsPublic: false` before apply. CloudTrail data events added for the bucket. The policy itself is unchanged, since removing `GetObject` or `ListBucket` could break a partner I know nothing about.

### F5. High: the database password is everywhere

Where: `variable "db_password"`, `DB_PASSWORD` in the task definition, `aws_db_instance.clinical`, `DB_USER = acme_admin`.

The default (`Acme-Clinical-2024!`) is in git history. The password is also in state, in plaintext in the task definition (visible in the ECS console and in every plan that touches it), and the app logs in as the master user.

Fix: store it in Secrets Manager, inject it with the task definition's `secrets` block, rotate it, give the app its own limited user, remove the default. Blue/Green doesn't support an RDS-managed Secrets Manager password, so use an ordinary secret first.

Part 2: marked `sensitive`, so plans stop printing it. Default and plaintext env var left alone: removing the default makes apply ask for a value, and any other value resets the live master password and breaks tonight's run. Rotation order is in `ROLLOUT.md`.

### F6. High: no encryption, no backups, no delete protection

Where: `aws_db_instance.clinical`: `storage_encrypted = false`, `backup_retention_period = 0`, `deletion_protection = false`, `skip_final_snapshot = true`, single AZ.

A bad destroy, migration or ransomware loses the only copy of the clinical data. An unencrypted snapshot can also be shared to another AWS account with one API call, which is what the Part 4 attacker does. AWS documents that a snapshot encrypted with the default key can't be shared at all.

Fix: encrypt with a customer-managed KMS key using RDS Blue/Green. AWS lets you set a KMS key on the green copy at creation, keeps it in sync, and at switchover renames green to the old name and endpoint, so applications keep the same hostname. Then enable backups (7+ days) and consider Multi-AZ. Afterwards set `storage_encrypted = true` in code so the plan stays clean.

Part 2: added delete protection, a final snapshot, `prevent_destroy` and pinned windows. `storage_encrypted` is left false on purpose: it is `ForceNew` (confirmed in the provider source), so setting it makes the plan read "must be replaced", and Terraform would delete the live database and create an empty one. Both scanners recommend exactly that. Backups wait for their own apply: going from 0 to a positive retention reboots a single-AZ instance, and AWS documents an outage for it.

### F7. High: the parser's role can do almost anything

Where: `aws_iam_role_policy.pipeline_task`.

`s3:*` on every bucket (including delete and policy changes), `GetSecretValue` on every secret, `ecs:RunTask` plus `iam:PassRole` on `*`. This role runs inside the container that parses untrusted partner PDFs, and OCR and PDF libraries have a long record of memory-safety bugs. A parser exploit inherits all of it: it reads every bucket and secret, deletes audit logs, rewrites bucket policies, and uses `PassRole` to escalate if a stronger ECS-assumable role exists. Open egress (F13) lets it send credentials out.

Fix: scope S3 to named buckets and prefixes, secrets to named ARNs, `RunTask` to the `document-parser` family, `PassRole` to the two roles in this file with `iam:PassedToService`. Derive the lists from what the role actually does: CloudTrail already records `GetSecretValue` and `RunTask`; S3 needs the new data events.

Part 2: the policy is unchanged (the plan shows nothing on it). A separate policy adds two explicit denies: touching the audit bucket, and editing bucket policies, public access blocks or versioning. A Deny beats the `s3:*` allow, and a parser has no reason to do either.

### F8. High: patient text is written to the logs

Where: `LOG_LEVEL = DEBUG` in the task definition; `aws_cloudwatch_log_group.document_parser` (no retention, no KMS).

The comment says DEBUG logs "the extracted text of every page". That puts PHI where far more people can read it than can read the database, kept forever, and impossible to delete on request.

Fix: INFO in production. Decide retention with the privacy lead, then purge existing PHI from the log group.

Part 2: the level is now a variable with the same value, so this apply shows no change, and the task definition gets `skip_destroy = true`. The flip to INFO is the next apply. `container_definitions` is `ForceNew`, so any edit replaces the task definition, and by default Terraform then deregisters the old revision. The provider reads `skip_destroy` from the value already in state, so it has to be live first. Done together, any DAG pinned to a revision (say `document-parser:17`) fails to launch at 22:00. No retention set: existing logs hold PHI and may be evidence, and deletion is irreversible.

### F9. High: weak audit trail; the audit bucket can be wiped

Where: `aws_cloudtrail.main`, `aws_s3_bucket.audit_logs` and its policy.

The trail covers one region, has no log file validation and no S3 data events, so we can see that someone listed buckets but not which patient files they read. The audit bucket has `force_destroy = true`, no public access block, no versioning and no TLS-only rule. An attacker with admin works in another region, deletes the logs, and nobody can prove what happened.

Fix: multi-region, validation, data events on PHI buckets, a hardened bucket. Later: Object Lock and a separate log-archive account.

Part 2: all of it except Object Lock, which is a one-way door. The new `event_selector` must keep `include_management_events = true`, or CloudTrail silently stops logging management calls. Data events are billed per event; check the cost after a week.

### F10. High: nothing alerts a human

Where: absent from `main.tf`. GuardDuty was enabled by hand, so it is unmanaged and routes nowhere.

In Part 4 the finding was created at 03:01 and found by chance at 10:14, over seven hours later.

Fix: bring GuardDuty into code and send every severity to a person. The finding that preceded the Part 4 compromise was severity 2.0 (Low); an alert on severity 7 and up would never have fired.

Part 2: imports the existing detector (ID from the finding ARN) rather than creating a second one, plus an EventBridge rule on all findings, an SNS topic, and an optional email subscription. The plan must say "1 to import". Someone still has to subscribe and read it.

### F11. Medium: state is a secret store with no lock

Where: `backend "s3"`.

State holds the DB password and the `ci-deployer` secret in plaintext, so read access to the state bucket is effectively admin. There is no lock table, so two applies at once can corrupt it.

On `encrypt = false`: scanners rank it high, but S3 has applied SSE-S3 to every new object since January 2023, so state is already encrypted at rest. I left it alone, because changing it forces a re-init everywhere for almost no gain.

Fix: restrict the bucket to the apply role, remove the secrets from state (F1, F5), add a lock table.

### F12. Medium: the image that handles all PHI can be swapped silently

Where: `aws_ecr_repository.document_parser`, `image = "...:latest"`.

Mutable tags plus `:latest` mean anyone with push rights, including the F1 key, can replace the image that parses every document without any Terraform change, and there is no known-good image to roll back to. Scan-on-push was off.

Fix: pin by digest, then set `IMMUTABLE`. In that order: `IMMUTABLE` first breaks the legacy builds, which re-push `:latest`.

Part 2: scan-on-push on (report-only). Mutability left, with the reason in the code.

### F13. Medium: the parser can reach the whole internet

Where: `aws_security_group.pipeline` egress to `0.0.0.0/0`.

A task that parses untrusted files needs S3, the database, ECR and logs. Open egress is where stolen role credentials leave after an exploit (F7).

Fix: VPC endpoints, record real destinations with Flow Logs, then restrict. Part 2: not changed. I can't see whether it also calls an OCR service or a partner endpoint, and tightening blind risks a silent nightly failure.

### F14. Medium: reliability

Where: `aws_db_instance.clinical`.

Single AZ, no storage autoscaling, and a random maintenance window that could fall inside the 22:00 to 06:00 UTC pipeline run. Part 2: backup window (07:00 UTC) and maintenance window (Tuesday 14:00 UTC) pinned outside the run; no reboot. Multi-AZ is a cost and failover decision for the CTO.

### F15. Low: container defaults

No `readonlyRootFilesystem`, no non-root `user`, no resource limits. Worth doing alongside F7, but it replaces the task definition, so it rides with a later task-definition change.

### F16. Low: housekeeping left on purpose

S3 access logging, lifecycle rules, landing-bucket versioning, IAM database authentication, Performance Insights, KMS on CloudWatch and ECR, replication, event notifications. Two notes. A KMS key on the landing bucket would break partner uploads, because an anonymous principal can't use a key; SSE-S3 already applies. Retention is a legal decision: audit and security documentation is commonly kept six years under HIPAA, while logs that contain PHI should be kept as short as possible. I left both numbers to the privacy lead.

## The compliance lens

"Addressable" does not mean optional. An addressable specification must be implemented, or you document why not and what you did instead. Encryption of ePHI at rest and in transit is addressable. A data backup plan, a disaster recovery plan, unique user identification, audit controls and activity review are Required. That is why F6 lists backups next to encryption. Encryption also matters beyond the rule: HHS treats encrypted PHI as "secured", which is the safe harbour from breach notification (164.402), so an unencrypted snapshot leaving the account (Part 4) is notifiable in a way an encrypted one might not be.

Not visible in this file, but I'd check on day one:

1. A signed AWS Business Associate Agreement, and PHI only on eligible services. Everything in this file is on AWS's HIPAA-eligible list. The alert topic must stay PHI-free: metadata only.
2. A data inventory: which partner's PHI sits in which prefix and table, and what happens to it when a partner leaves. "Minimum necessary" (F4, F7, F8) can't be enforced without it.
3. Account basics outside Terraform: MFA or SSO for people, root locked away, account-wide S3 Block Public Access, a region restriction so nothing runs where the trail can't see, Config and Security Hub.
4. A documented risk analysis (164.308(a)(1)(ii)(A), required). This review is an input to it, not a replacement.

## Reviewed and fine

- `public_assets` bucket: the correct CloudFront (OAC) setup. Public access fully blocked; one grant, to one distribution. Both scanners flagged it anyway.
- OIDC thumbprint: the standard GitHub value; AWS validates the chain itself.
- `AmazonECSTaskExecutionRolePolicy` and the ECS trust policies: standard.
- `block_public_acls` and `ignore_public_acls` on the landing bucket: already on.
- `sensitive = true` on the secret output: right as far as it goes, but it doesn't keep the secret out of state (F1).

## What the scanners did

Raw results are reproducible with the commands in `scans/README.md`.

| | Checkov 3.3.30 | Trivy 0.76.1 |
|---|---|---|
| Original | 59 failed, 79 passed | 37 (2 critical, 16 high, 7 medium, 12 low) |
| After Part 2 | 52 | 25 |
| Real fixes in that drop | 9 | 12 |
| New findings from my changes | 2 | 1 |

- **Missed by both** (I checked the output): Postgres open to `0.0.0.0/0` as a firewall rule (both flagged `publicly_accessible`, neither the rule), the wildcard OIDC trust, `Principal "*"` on the landing bucket, `DEBUG` logging, and the hardcoded password. Checkov's separate secrets scan reported 0 resources scanned.
- **Noise:** 18 of Checkov's 59 are S3 housekeeping repeated across three buckets, including the `public_assets` bucket that is fine.
- **Ranked oddly:** Trivy's only two CRITICAL findings are open egress rules. It never flagged the open ingress.
- **Advice that breaks production:** both recommend `storage_encrypted = true` (F6, destroys the database) and immutable ECR tags (F12, breaks the legacy builds). Neither can know that.
- **False greens, found while testing my own change:** when I first put the new denies inside the existing pipeline policy, Checkov stopped reporting its four IAM wildcard checks. The wildcards were unchanged. Swapping the interpolated ARNs for literals made all four fire again, so the scanner skips policies containing references it can't resolve. Trivy drops `AWS-0345` as soon as any S3 deny is attached to the role, though `s3:*` on `*` still applies to every other bucket. I moved the denies into a separate policy. A clean scan is not proof.
- **My new findings:** Checkov `CKV_AWS_26` and `CKV2_AWS_3`, Trivy `AWS-0095`, on the alert topic and detector. The topic is unencrypted on purpose: EventBridge can't publish with the AWS-managed SNS key, and the payload is GuardDuty metadata, not PHI.

## 1b. For the CTO

Three things could badly hurt Acme, and they link together. First, the keys we use to deploy (an old administrator key that never expires, and a role that any repository in our GitHub organisation can use) open the entire building, so anyone who gets one can read every patient file, copy the database and erase the logs. Second, the patient database is reachable from the internet and protected only by a password that is written in our code, and it has no backups and no encryption, so one leak or one mistake could expose it or destroy it. Third, we mostly can't see trouble coming: logs cover one region, nothing records which patient files were read, and security alerts go to nobody, so a break-in could run for days and we could not prove what was taken. This week: take a database backup today, make sure someone receives the security alerts, and switch off the old admin key after warning the two teams that use it; the remaining fixes can follow safely over the quarter, in the order in `ROLLOUT.md`.

## Sources checked

- S3 "meaning of public" and Block Public Access: [AWS docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- Backup retention 0 to positive causes an outage: [AWS docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithAutomatedBackups.BackupRetention.html)
- RDS Blue/Green encryption and switchover: [limitations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-considerations.html), [switching over](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/blue-green-deployments-switching.html)
- SCPs don't act on resource policies or outside principals: [AWS Organizations](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- `storage_encrypted` is `ForceNew`: [provider v5.100.0 `rds/instance.go`](https://github.com/hashicorp/terraform-provider-aws/blob/v5.100.0/internal/service/rds/instance.go)
- `container_definitions` is `ForceNew`, `skip_destroy` read at delete: [provider v5.100.0 `ecs/task_definition.go`](https://github.com/hashicorp/terraform-provider-aws/blob/v5.100.0/internal/service/ecs/task_definition.go)
- HIPAA Security Rule: [164.312](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-164/subpart-C/section-164.312), [164.308](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-164/subpart-C/section-164.308)
- Breach rule: [164.402](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-164/subpart-D/section-164.402), [164.404](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-164/subpart-D/section-164.404), [164.410](https://www.ecfr.gov/current/title-45/subtitle-A/subchapter-C/part-164/subpart-D/section-164.410)
- HIPAA-eligible AWS services and the BAA: [aws.amazon.com/compliance/hipaa-eligible-services-reference](https://aws.amazon.com/compliance/hipaa-eligible-services-reference/)
