# Rollout plan

**Rules.** Additive, then observe, then restrict, then remove. No apply inside 22:00 to 06:00 UTC; risky changes go Tue to Thu around 14:00 UTC with someone on call. Every plan must say **0 to destroy** (only the task definition may be replaced; CI's `plan-gate` enforces it). Ship the reversible form first: deactivate, don't delete; add a deny, don't remove an allow.

## Today: no downtime, all reversible

| Change | Check before applying | Verify after | Roll back |
|---|---|---|---|
| **1. Manual RDS snapshot** (backups are off) | none | Status `available` | n/a |
| **2. Apply the Part 2 PR** | 0 destroy; nothing "must be replaced"; GuardDuty says `1 to import`; task definition shows only `skip_destroy`; `get-bucket-policy-status` returns `IsPublic: false`; how Airflow names the task definition | No pending DB changes; trail has no delivery error; test alert arrives; a partner test upload works | Revert the PR |
| **3. Second apply, 1h later: `parser_log_level = "INFO"`** (must be separate, see F8) | Exactly one `-/+`, on the task definition | Tonight's logs say INFO; old revision still ACTIVE | Variable back to `DEBUG` |
| **4. Warn the `ci-deployer` pipeline owners** | n/a | They confirm | n/a |

## This week: evidence, then restrict

Evidence from 90 days of CloudTrail: the pipeline's `GetSecretValue` and `RunTask` calls, every OIDC `sub` seen, every `ci-deployer` call by source IP.

| Change | Check before applying | Verify after | Roll back |
|---|---|---|---|
| **Retire `ci-deployer`:** move both pipelines to OIDC, deactivate the key, wait 7 days, delete | Plan shows exactly 3 destroys | Pipelines green | Reactivate key |
| **Narrow the OIDC `sub`:** add exact subs beside the wildcard, prove one real run uses one, then drop the wildcard | Keep a break-glass admin path | A plan and a deploy work | Re-add via break-glass |
| **Rotate the DB password:** secret holds the *current* value, then task definition `secrets`, one run, then change RDS and secret together at 14:00 UTC, then drop the default | Never delete the default first | Tonight's run connects | Secret keeps old value |
| **Close port 5432:** 7 days of Flow Logs, allow the real sources, then remove `0.0.0.0/0` | `pg_stat_activity` clients all known | Nightly job fine | Re-add rule (instant) |
| **Backups 0 to 7:** its own apply, on-call watching | Only retention changes | Brief reboot, then first snapshot | Set to 0 |
| **Narrow the pipeline policy** from the evidence, new policy first | Run a night with both | No `AccessDenied` | Restore old |

## This quarter

Partners to authenticated access (interim: one prefix-scoped statement per partner IP range, then drop `Principal "*"`). **Encrypt the DB with RDS Blue/Green**, setting a KMS key on the green side: build green in the morning, switch over in the daytime gap (green takes the old name and endpoint, so `DB_HOST` is unchanged), keep the old instance locked down for the backup window, then set `storage_encrypted = true` in code so the plan is clean. First check: every table has a primary key, no schema changes while it runs, and no RDS-managed Secrets Manager password (unsupported with Blue/Green). Never flip it in place. Then image digests and `IMMUTABLE`, split plan/apply roles, Object Lock and a log-archive account, log retention.

## Who I need

Partners (IPs, new auth, anyone on plain HTTP). Data team (Airflow's task-definition reference, DB clients, secrets and buckets really used, who reads DEBUG logs). Legacy pipeline owners. Leadership and the privacy lead (budget, downtime window, log retention and purging PHI already logged).

## Finding what nobody wrote down

Read logs, don't ask memories: CloudTrail, the new S3 data events, Flow Logs, `pg_stat_activity`, IAM Access Advisor, a grep of the Airflow repo. Then scream-test: ship the reversible form, revert PR ready, watch for `AccessDenied`.
