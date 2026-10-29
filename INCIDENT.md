# Incident: `ci-deployer` key used from outside

Tuesday 14 April, 10:14 UTC. A Low (2.0) GuardDuty finding, found by accident, turns out to be the first step of an account compromise.

Confidence: **High** = read directly from the logs. **Medium** = a reasonable inference. **Low** = a hunch to test.

## 4a. What happened

| Time (UTC) | Event | Reading | Confidence |
|---|---|---|---|
| 02:47:11 | `GetCallerIdentity` with the `ci-deployer` key from 203.0.113.45 (a hosting company in the Netherlands) | The attacker checks the stolen key works. Normal use is GitHub-hosted runners in working hours. | High: unauthorised, key compromised |
| 02:47:30 to 02:48:40 | `ListBuckets`, `GetBucketPolicy` on `acme-health-raw-landing`, `ListUsers` | Recon. They asked for the PHI bucket's policy by name. | High (calls), Medium (intent) |
| 02:51:15 to 02:51:18 | `CreateUser svc-backup-02`, attach `AdministratorAccess`, `CreateAccessKey` | Persistence. Three calls in three seconds is a script. The name imitates a backup service. Disabling `ci-deployer` alone will not evict them. | High |
| 03:01:52 | GuardDuty creates the finding. Nothing routes it. | Detection fired 14 minutes after the first call. Nobody was told. | High |
| 03:05:52 | New key used from 203.0.113.200: `DescribeDBInstances` | They test the foothold about 15 minutes later and look for the database. Same /24 as the first IP. | High (use), Medium (same actor) |
| 03:06:30 | `CreateDBSnapshot acme-clinical-prod-0414` | A full copy of the clinical database. | High |
| 03:41:09 | `ModifyDBSnapshotAttribute`: restore access added for account **444455556666** | The snapshot is shared with an outside AWS account: the exfiltration. Possible because the database is unencrypted. The 35-minute gap is consistent with creating the snapshot (inference). | High that it was shared |
| 03:43:55 | `DescribeRegions` | Looking at other regions, where our single-region trail is blind. | Low |
| after 03:43:55 | Nothing in the events I have | Unknown. Not evidence they stopped. | n/a |

GuardDuty's "Low" scored only the discovery calls. Four minutes later the same actor created an admin user. Severity rates one behaviour, not its place in a chain.

### What I don't know yet

1. **How the key leaked, and since when.** A GitHub Actions secret, a laptop, the state file (it holds the secret in plaintext), CI logs. The first misuse may predate 02:47. I'd search 90 days of `ci-deployer` calls for any non-GitHub source IP.
2. **Whether account 444455556666 copied or restored the snapshot.** I can't see their account. A 30-second check that it isn't an Acme, partner or vendor account changes the message, not the containment.
3. **What happened after 03:43:55 and in other regions.** One-region trail, no log validation: I can't rule out other activity, or that the attacker edited the logs.
4. **Whether data was read without a trace.** No S3 data events and no database logs; the database was internet-reachable with a default password.
5. **Whether there is a second foothold.** The table is a selection of related events.
6. **Whether the two IPs are one actor.** Probably, but a shared range proves little.

## 4b. My first 60 minutes

I assume admin access and an attacker who is still active. I delete nothing, and I save the `describe` output before each change so I have the "before".

1. **T+0: open the incident record.** Private channel, a scribe, every action logged in UTC, and a heads-up to the CTO ("possible account compromise, containing now, written update in 45 minutes"). Why first: it takes three minutes, and a timeline rebuilt later is weak evidence.
2. **T+3: disable both identities.** Set every access key on `ci-deployer` and `svc-backup-02` to Inactive, and attach the "revoke older sessions" deny (`aws:TokenIssueTime`) so temporary credentials already issued die too. Pause the Terraform apply workflow: `aws_iam_access_key` defaults to Active, and the next apply would switch the stolen key back on. Why now: an active admin is the only thing still getting worse. Inactive, not deleted, keeps last-used data as evidence. Cost: the two legacy deploy pipelines stop; the nightly data run doesn't use this key (I'd confirm).
3. **T+8: cut the exfiltration channel.** Save the snapshot's attributes, then remove 444455556666 from restore access. Keep the snapshot as evidence. Why: it stops any copy not yet started. It can't undo one already made.
4. **T+12: look for a second foothold.** Everything created or changed since 02:47 by any principal: users, roles, keys, login profiles, trust policies, OIDC providers. The IAM credential report and `get-account-authorization-details`. Compute in every region. The trail itself (`StopLogging`, `UpdateTrail`, `DeleteTrail`, `PutEventSelectors`). Why before calling it contained: `svc-backup-02` shows they plant persistence, and a second one means steps 2 and 3 evicted nobody.
5. **T+20: close the database.** The attacker's admin could read the password in plain text from the task definition, and the database is open to the internet. Remove `0.0.0.0/0` from its security group (the pipeline rule stays), end unknown sessions in `pg_stat_activity`, and rotate the master password in the daytime gap (nothing runs 06:00 to 22:00 UTC), updating the task definition in the same window so tonight's run connects. Why now, when `ROLLOUT.md` waits a week for evidence: in an active incident an analyst losing access is acceptable and an attacker holding the password is not. The pipeline owner confirms tonight's run before 22:00.
6. **T+30: preserve evidence.** Copy the audit bucket (it has no versioning), export 90 days of CloudTrail history from every region, the GuardDuty findings and the IAM exports to a new locked bucket, preferably in another account, and record hashes. Why after containment: while they held admin credentials they could delete the logs I'm copying.
7. **T+40: restore visibility.** Multi-region trail with validation and landing-bucket data events, and GuardDuty routed to a person. Review all GuardDuty findings in the window, any severity. Why: we're blind outside us-east-1 and on data access. This does not recover what was missed.
8. **T+45: scope it.** Every call by both key IDs and both IPs over 90 days, in every region: `GetSecretValue`, `StartExportTask`, `CopyDBSnapshot`, restores, S3 management events. Look before 02:47 for earlier non-GitHub use of `ci-deployer`. Check GitHub's audit log for secret access or workflow edits, and rotate secrets in the two legacy repos. Why: it sets the start of the breach window.
9. **T+50: escalate in writing.** Update the CTO and the privacy/compliance lead (4c). Open a high-severity AWS Support case and an abuse report with AWS Trust & Safety about 444455556666, the only party that can act on the copy. Counsel decides on outside notices; I don't contact partners or regulators.

Not done in the hour, on purpose: deleting `svc-backup-02` or the snapshot, restoring the database, a broad `terraform apply` (CLI changes get recorded as drift to reconcile later), any public statement.

## 4c. Was patient data exposed?

**What I can say from the logs.** A full copy of the production clinical database was created (03:06) and shared with an unknown external AWS account (03:41). The database holds PHI. The copy was unencrypted, which is what made sharing possible and why the encryption safe harbour can't apply. I treat PHI exposure as probable, not just possible, even though I can't yet show anyone opened the copy.

**What I can't say, and why.**
- Whether the landing bucket was read. No S3 data events. The attacker looked up its policy at 02:48 and held admin.
- Whether the database was queried directly. Internet-reachable, default password, no database logs.
- Whether anything happened in other regions or after the last event. One region, no validation, no versioning on the audit bucket, so I can't prove the logs are complete. The silence after 03:43 is unexplained, not reassuring.
- Whose data, and how much. There is no data inventory.

I would not say "no PHI was exposed". I would say: "PHI was almost certainly copied to an external account. We can't yet show it was used, and we can't rule out other access."

**Who I tell, and when** (I'm not a lawyer; counsel owns the decisions here):

| When | Who | What |
|---|---|---|
| T+0, a call | CTO | "Possible account compromise, containing now." Written update at T+45 to T+60. |
| T+50, in writing | CTO and privacy/compliance lead | Confirmed, probable and unknown, as above, plus what is and isn't contained. |
| Within the day | Privacy lead, then counsel, then (their call) the cyber insurer | Whether this is a reportable breach, and when the clock started. |
| As counsel directs | Partners, then regulators | Acme most likely handles PHI as a business associate for its partner clinics. Those contracts often require notice within days, well inside HIPAA's 60-day outer limit. Some US states are shorter. |

Two reasons not to wait for certainty. First, a breach is treated as discovered on the first day it is known or would have been known with reasonable diligence (45 CFR 164.404(a)(2); 164.410(a)(2) for a business associate). The finding existed from 03:01 and sat unread for over seven hours, so the clock may already be running. Notice is due without unreasonable delay and never later than 60 days. Second, an impermissible disclosure is presumed to be a breach unless we document a low probability of compromise (164.402), judged on four factors:

| Factor | Where we stand |
|---|---|
| 1. Nature of the data, likelihood of re-identification | A whole clinical database, identifiers included. Bad. |
| 2. Who received it | An unknown outside account. Bad. |
| 3. Whether it was actually acquired or viewed | Unknown. The only factor evidence could improve, and the missing logs are why it can't yet. |
| 4. How far the risk has been mitigated | Partly: share removed (step 3). The Trust & Safety report (step 9) could move it. |

Because the database was unencrypted this is "unsecured PHI", so there is no encryption safe harbour. That is why steps 3 and 9 matter even though they can't undo a copy already made.

Evidence I'd need to finish the assessment: the full CloudTrail export, Trust & Safety's response on 444455556666, any trace of direct database connections, the data inventory, and the first-compromise date from step 8.

## 4d. Prevention: what would have broken this chain

| Step of the attack | What stops it | Finding |
|---|---|---|
| A stolen permanent key works from anywhere | Remove long-lived credentials: OIDC only, delete `ci-deployer`, pin the OIDC `sub`. If a key must exist, restrict it by source. | F1, F2 |
| Creates an admin user and key in three seconds | A guardrail on identity creation: an SCP or permissions boundary denying `iam:CreateUser`, `CreateAccessKey` and admin policy attachment to everyone but a break-glass role, plus an alert on those events. An SCP needs AWS Organizations with this account as a member (SCPs don't apply to the management account). Today it's a single account, so a permissions boundary is the fallback. | F1, F7 |
| Nobody saw it for seven hours | Alerts that reach a person: GuardDuty at every severity, plus a few high-signal CloudTrail rules (`CreateUser`, `CreateAccessKey`, `ModifyDBSnapshotAttribute`, `StopLogging`). This attack would have alerted at 03:01, before the exfiltration at 03:41. | F10 |
| Snapshot shared to a stranger | Encrypt the database with a customer-managed key and deny `rds:ModifyDBSnapshotAttribute` except to break-glass. A shared snapshot is useless without the key, and AWS documents that one encrypted with the default key can't be shared at all. Make the database private. | F6, F3 |
| Can't tell what was read | Logs you can trust: multi-region, validation, data events on PHI buckets, database connection logging, and a separate log-archive account with Object Lock. | F9 |

The first two rows matter most: with no permanent key and no way to mint an admin user, the attack stops at step one or two. The rest limit the damage if it doesn't.

Already in the Part 2 change set: multi-region trail with validation and data events, GuardDuty with all-severity alerts, audit-bucket hardening, `prevent_destroy` and delete protection. Still needing the rollout: removing the key, encrypting the database, closing it to the internet.
