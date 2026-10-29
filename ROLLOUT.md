# Rollout plan

**Rules.** Additive, then observe, then restrict, then remove. No apply 22:00 to 06:00 UTC; risky changes Tue to Thu around 14:00 UTC with on-call. Every plan must say **0 to destroy** (only the task definition may be replaced; CI's `plan-gate` enforces it). Test restrictions on a v2 role, not as a second policy beside the old one: IAM permissions add up, so that tests nothing.

## Today: no downtime, all reversible

| Change | Check before | Verify after | Roll back |
|---|---|---|---|
| **1. Manual RDS snapshot** (backups are off) | none | `available` | n/a |
| **2. Apply the Part 2 PR** | 0 destroy; no "must be replaced"; GuardDuty `1 to import`; task definition shows only `skip_destroy`; `IsPublic: false`; how Airflow names the task definition | No pending DB changes; no trail error; test alert (one expected, from our `UpdateTrail`); partner upload works | Revert the PR |
| **3. 1h later: `parser_log_level = "INFO"`** (separate apply, F8) | One `-/+`, on the task definition | Logs say INFO; old revision ACTIVE | Variable back |
| **4. Restrict who can read the parser log group; list every log sink** before deleting anything | Who has `logs:GetLogEvents` | Only responders | Restore policy |

Also today: warn the `ci-deployer` owners.

## This week: evidence, then restrict

Evidence: 90 days of CloudTrail (`GetSecretValue`, `RunTask`, every OIDC `sub`, `ci-deployer` calls by source IP), plus S3 data events on **all** buckets for a week; without them, access outside the landing bucket is invisible.

| Change | Check before | Verify after | Roll back |
|---|---|---|---|
| **Retire `ci-deployer`:** OIDC for both pipelines, deactivate, wait 7 days, delete | Plan: exactly 3 destroys | Pipelines green | Reactivate |
| **OIDC trust, second role:** prove a break-glass admin path first. New role trusted only for the infra repo's `production` Environment, pinned by `repository_id`; switch the workflow; delete the old role after a clean week. (An exact `sub` beside the wildcard is an OR: proves nothing.) | Break-glass apply works | Plan and deploy pass | Point workflow back |
| **Rotate DB password:** secret holds the current value, task definition `secrets`, one run, change RDS and secret together at 14:00 UTC, then drop the default | Never drop the default first | Tonight connects | Secret keeps old value |
| **Close 5432:** 7 days of Flow Logs, allow real sources, remove `0.0.0.0/0` | `pg_stat_activity` known | Nightly job fine | Re-add rule |
| **Backups 0 to 7 + DB audit logging, one reboot:** parameter group (`pgaudit` on patient tables, connection logs), logs to CloudWatch (lock down: statements can hold PHI), app off `acme_admin`. Own apply, snapshot first | Only retention and parameter group change | Brief reboot; snapshot; audit lines | Detach group, retention 0 |
| **Pipeline role v2:** narrow policy from the evidence; drop `RunTask`/`PassRole` if unused. Test off-peak (06:00 to 22:00 UTC), then repoint Airflow | A real test run | Nightly run ok | Repoint to old revision |
| **Account basics:** root MFA and lockdown; account-wide S3 Block Public Access | `get-bucket-policy-status` on every bucket | Site and partners fine | Remove setting |
| **Alert routing:** confirm a 24/7 on-call exists; high-risk API rules page, GuardDuty Low to a daily digest | On-call rota exists | Test event pages someone | One topic |

## This quarter

Partners: drop `GetObject`/`ListBucket` if data events show write-only; interim per-partner prefix rules (partners sharing a /24 can't be separated); SFTP (Transfer Family) for those who can't change integration. **Encrypt the DB with RDS Blue/Green** (KMS key on green): build in the morning, switch over in the daytime gap (endpoint unchanged), keep the old instance locked down for the backup window, then set `storage_encrypted = true` in code. First check primary keys, no schema changes, no RDS-managed secret. Then image digests and `IMMUTABLE`, plan/apply role split, Object Lock and a log-archive account, log retention.

## Who I need, and finding what nobody wrote down

Partners (IPs, new auth, a risk acceptance for any who can't change this year). Data team (Airflow's task-definition reference, DB clients, real secrets and buckets, log sinks). Pipeline owners. Privacy officer, counsel, security lead (log retention), leadership (budget, window). Read logs, don't ask memories; then ship the reversible form first, revert ready, and watch for `AccessDenied`.
