# Acme Health core platform. Change set 1 of 2 (see FINDINGS.md, ROLLOUT.md).
#
# A fix is in this file only if applying it cannot
#   1. destroy or replace anything,
#   2. reboot or take anything down, or
#   3. cut off a consumer we don't know about.
# Everything else is left as it was, marked "NOT CHANGED" with the reason.
# grep "CHANGE:" for the edits, "NOT CHANGED" for what was held back.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket = "acme-health-terraform-state"
    key    = "platform/prod.tfstate"
    region = "us-east-1"

    # NOT CHANGED: S3 has encrypted every new object (SSE-S3) since January
    # 2023, so state is already encrypted at rest. The real state risks are the
    # secrets stored in it and the missing lock table. ROLLOUT.md, "This week".
    encrypt = false
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "clinical-platform"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "site_distribution_arn" {
  type        = string
  description = "ARN of the CloudFront distribution that serves the marketing website."
}

variable "db_password" {
  type = string

  # CHANGE: sensitive, so plans stop printing the password in CI logs.
  sensitive = true

  # NOT CHANGED: the default. Removing it makes apply ask for a value, and any
  # other value resets the live master password and breaks tonight's run.
  # Rotate first (ROLLOUT.md). The password is already exposed either way.
  default = "Acme-Clinical-2024!" # tripwire:ack rotate then remove, ROLLOUT.md "This week"
}

variable "parser_log_level" {
  type        = string
  description = "LOG_LEVEL for the document parser. DEBUG writes the extracted text of every page (PHI) to CloudWatch."

  # NOT CHANGED yet: set to "INFO" in the next apply, not this one (see the
  # task definition for why).
  default = "DEBUG" # tripwire:ack flip to INFO in the next apply, ROLLOUT.md "Today"
}

variable "security_alert_email" {
  type        = string
  description = "Where GuardDuty alerts go. Leave null to create the topic without a subscriber."
  default     = null
}

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

# Partner organizations upload clinical documents here (PDFs, CSV extracts,
# FHIR bundles). Each partner writes under its own prefix: incoming/<partner_id>/
resource "aws_s3_bucket" "raw_landing" {
  bucket = "acme-health-raw-landing"
}

resource "aws_s3_bucket_public_access_block" "raw_landing" {
  bucket             = aws_s3_bucket.raw_landing.id
  block_public_acls  = true
  ignore_public_acls = true

  # CHANGE: false -> true. S3 treats a policy as non-public when it only allows
  # fixed, narrow aws:SourceIp ranges (nothing wider than a /8). Ours is two
  # /24s, so partner access is unaffected. These flags stop a future edit that
  # would make the bucket public.
  # Before applying, this must return "IsPublic": false (plan can't show it):
  #   aws s3api get-bucket-policy-status --bucket acme-health-raw-landing
  block_public_policy     = true
  restrict_public_buckets = true
}

# NOT CHANGED: an anonymous principal with Get and List on the whole bucket, so
# any partner can read another partner's files. Fixing it needs per-partner
# access and evidence of who reads what (data events, below). ROLLOUT.md.
# No TLS-only deny either: I can't rule out a partner uploading over plain HTTP.
resource "aws_s3_bucket_policy" "raw_landing" {
  bucket = aws_s3_bucket.raw_landing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PartnerAccess"
        Effect    = "Allow"
        Principal = "*" # tripwire:ack anonymous partner access, auth migration in ROLLOUT.md "This quarter"
        Action    = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.raw_landing.arn,
          "${aws_s3_bucket.raw_landing.arn}/*",
        ]
        Condition = {
          IpAddress = {
            "aws:SourceIp" = ["198.51.100.0/24", "192.0.2.0/24"]
          }
        }
      }
    ]
  })
}

# Logos and public PDFs for the marketing website, served through CloudFront.
# Reviewed, fine: the correct CloudFront (OAC) setup. Public access is fully
# blocked and the only grant is to one distribution.
resource "aws_s3_bucket" "public_assets" {
  bucket = "acme-health-public-assets"
}

resource "aws_s3_bucket_public_access_block" "public_assets" {
  bucket                  = aws_s3_bucket.public_assets.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "public_assets" {
  bucket = aws_s3_bucket.public_assets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.public_assets.arn}/*"
        Condition = {
          StringEquals = { "AWS:SourceArn" = var.site_distribution_arn }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Audit logging
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "audit_logs" {
  bucket = "acme-health-audit-logs"

  # CHANGE: true -> false. A destroy no longer empties the audit trail.
  # Terraform-side flag only; nothing changes in AWS.
  force_destroy = false

  # CHANGE: a plan that would delete this bucket now fails.
  lifecycle {
    prevent_destroy = true
  }
}

# CHANGE (new): versioning, so overwritten or deleted logs are recoverable.
resource "aws_s3_bucket_versioning" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  # Applied in sequence: S3 returns conflicts when bucket settings change together.
  depends_on = [aws_s3_bucket_versioning.audit_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.audit_logs.arn
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit_logs.arn}/AWSLogs/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      # CHANGE (new): refuse plain HTTP. CloudTrail delivers over HTTPS.
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*" # tripwire:ack this is a DENY statement (TLS only), not a grant
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.audit_logs.arn,
          "${aws_s3_bucket.audit_logs.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# CHANGE (new): the audit bucket had no public access block.
resource "aws_s3_bucket_public_access_block" "audit_logs" {
  bucket                  = aws_s3_bucket.audit_logs.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true

  depends_on = [aws_s3_bucket_policy.audit_logs]
}

resource "aws_cloudtrail" "main" {
  name                          = "acme-trail"
  s3_bucket_name                = aws_s3_bucket.audit_logs.id
  include_global_service_events = true

  # CHANGE: false -> true. Adds regions, removes nothing.
  is_multi_region_trail = true

  # CHANGE: false -> true. Digest files let us prove logs weren't edited. They
  # land under AWSLogs/, which the bucket policy already allows.
  enable_log_file_validation = true

  # CHANGE (new): data events for the landing bucket, so reads of patient files
  # are recorded. Keep include_management_events = true: any event_selector
  # replaces the default, and without it management events stop being logged.
  # Data events are billed per event; check the cost after a week.
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.raw_landing.arn}/"]
    }
  }

  depends_on = [aws_s3_bucket_policy.audit_logs]
}

# -----------------------------------------------------------------------------
# Container platform
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "document_parser" {
  name = "document-parser"

  # NOT CHANGED: IMMUTABLE would break the legacy builds, which re-push the
  # ":latest" tag the task definition pulls. Pin image digests first.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    # CHANGE: false -> true. Report-only; cannot block a push.
    scan_on_push = true
  }
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "acme-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "pipeline_task" {
  name               = "acme-pipeline-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# NOT CHANGED, byte for byte. s3:*, GetSecretValue and RunTask/PassRole on "*"
# are too broad for the role in the container that parses untrusted PDFs, but I
# can't see what else uses them. Narrow from CloudTrail evidence (GetSecretValue
# and RunTask are management events, so 90 days exist already). ROLLOUT.md.
resource "aws_iam_role_policy" "pipeline_task" {
  name = "pipeline-permissions"
  role = aws_iam_role.pipeline_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DataAccess"
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = "*"
      },
      {
        Sid      = "ReadSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      },
      {
        Sid      = "FanOut"
        Effect   = "Allow"
        Action   = ["ecs:RunTask", "iam:PassRole"]
        Resource = "*"
      }
    ]
  })
}

# CHANGE (new): explicit denies for things a document parser has no reason to
# do: touch the audit bucket, or edit bucket policies and public access blocks.
# A Deny beats the s3:* allow above. Kept as a separate resource so the original
# policy stays unchanged and scanners keep flagging its wildcards (when I first
# merged the two, both scanners reported those wildcards as fixed).
resource "aws_iam_role_policy" "pipeline_guardrails" {
  name = "pipeline-guardrails"
  role = aws_iam_role.pipeline_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyTouchingAuditLogs"
        Effect = "Deny"
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.audit_logs.arn,
          "${aws_s3_bucket.audit_logs.arn}/*",
        ]
      },
      {
        Sid    = "DenyBucketGuardrailTampering"
        Effect = "Deny"
        Action = [
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy",
          "s3:PutBucketPublicAccessBlock",
          "s3:PutBucketAcl",
          "s3:PutBucketOwnershipControls",
          "s3:PutBucketVersioning",
          "s3:PutEncryptionConfiguration",
          "s3:PutLifecycleConfiguration",
          "s3:DeleteBucket",
        ]
        Resource = "*"
      }
    ]
  })
}

# NOT CHANGED: no retention. Existing DEBUG logs hold patient text and may be
# evidence; deleting them is irreversible and needs the privacy lead's
# sign-off. ROLLOUT.md, "This quarter".
resource "aws_cloudwatch_log_group" "document_parser" {
  name = "/ecs/document-parser"
}

# Parses and OCRs every document partners upload, then loads the results into
# the clinical database.
resource "aws_ecs_task_definition" "document_parser" {
  family                   = "document-parser"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 4096
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.pipeline_task.arn

  # CHANGE (new): keep old revisions active. container_definitions is ForceNew,
  # so any edit to it replaces this resource and, by default, deregisters the
  # old revision; a DAG pinned to one would fail to launch at 22:00.
  # The provider reads skip_destroy from state, so this must be applied BEFORE
  # the log level changes. Separate applies (ROLLOUT.md, "Today").
  skip_destroy = true

  container_definitions = jsonencode([
    {
      name      = "parser"
      image     = "${aws_ecr_repository.document_parser.repository_url}:latest" # NOT CHANGED: pin a digest first (see ECR above)
      essential = true
      environment = [
        { name = "DB_HOST", value = aws_db_instance.clinical.address },
        { name = "DB_USER", value = "acme_admin" },
        # NOT CHANGED: plaintext password. Moving it to "secrets" needs the
        # secret to hold the live password and the execution role to read it
        # first. ROLLOUT.md, "This week".
        { name = "DB_PASSWORD", value = var.db_password },
        # Same value as before (DEBUG logs page text to CloudWatch), now a
        # variable. Set to "INFO" in the next apply.
        { name = "LOG_LEVEL", value = var.parser_log_level },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.document_parser.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "parser"
        }
      }
    }
  ])
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

# NOT CHANGED: open egress. The parser should only need S3, the DB, ECR and
# logs, but I can't see whether it also calls an OCR service. Flow Logs first.
resource "aws_security_group" "pipeline" {
  name        = "acme-pipeline-tasks"
  description = "ECS pipeline tasks"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "acme-clinical-db"
  description = "Clinical database"
  vpc_id      = var.vpc_id

  # NOT CHANGED: Postgres open to the internet. Something outside the pipeline
  # probably connects (analysts, BI, Airflow) and nothing records who. Remove
  # it after we have evidence. ROLLOUT.md.
  ingress {
    description = "Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # tripwire:ack remove once real clients are known, ROLLOUT.md
  }

  # CHANGE (new): the pipeline's own rule, beside the open one. Additive, so
  # removing 0.0.0.0/0 later is a pure deletion.
  ingress {
    description     = "Postgres from pipeline tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.pipeline.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------------------
# Database
# -----------------------------------------------------------------------------

# NOT CHANGED: public subnets (private_subnet_ids is declared and never used).
# AWS won't drop a subnet in use by a running instance, so moving needs a new
# subnet group and an outage.
resource "aws_db_subnet_group" "clinical" {
  name       = "acme-clinical-db"
  subnet_ids = var.public_subnet_ids
}

resource "aws_db_instance" "clinical" {
  identifier             = "acme-clinical-prod"
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.m6g.large"
  allocated_storage      = 200
  username               = "acme_admin"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.clinical.name
  vpc_security_group_ids = [aws_security_group.db.id]

  # NOT CHANGED: pointless while the security group is open and the subnets are
  # public, and an unknown client may depend on it.
  publicly_accessible = true # tripwire:ack ROLLOUT.md "This week"

  # NOT CHANGED: ForceNew. Setting true makes the plan read "must be replaced":
  # Terraform deletes the live database and creates an empty encrypted one, and
  # with no backups there is nothing to restore. Encrypt with RDS Blue/Green
  # (ROLLOUT.md, "This quarter"), then set true here. prevent_destroy below
  # turns a mistaken flip into a failed plan.
  storage_encrypted = false # tripwire:ack ForceNew; Blue/Green, ROLLOUT.md "This quarter"

  # NOT CHANGED: going from 0 to a positive value reboots a single-AZ instance
  # (AWS documents an outage). Its own watched apply, after a manual snapshot.
  backup_retention_period = 0 # tripwire:ack needs a watched reboot, ROLLOUT.md "This week"

  # CHANGE (new): pin both windows outside the 22:00-06:00 UTC pipeline run.
  # Applied immediately, no reboot. Pick hours your on-call is awake for.
  backup_window      = "07:00-08:00"
  maintenance_window = "tue:14:00-tue:15:00"

  # CHANGE: false -> true. Instant, no reboot.
  deletion_protection = true

  # CHANGE: true -> false, plus a name. Only acts on delete: leaves a final
  # snapshot instead of nothing.
  skip_final_snapshot       = false
  final_snapshot_identifier = "acme-clinical-prod-final"

  # CHANGE (new): a plan that would destroy or replace this instance now fails.
  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# CI/CD
# -----------------------------------------------------------------------------

# Reviewed, fine: the standard GitHub thumbprint; AWS validates the chain itself.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# NOT CHANGED: any repo in the org, on any branch or PR, can assume this admin
# role. Narrowing "sub" is the fix, but this role applies this very code: a
# wrong guess locks out the apply and the rollback. Read the real sub values
# from CloudTrail (AssumeRoleWithWebIdentity) first. ROLLOUT.md, "This week".
resource "aws_iam_role" "github_deploy" {
  name = "acme-github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:acme-health/*" # tripwire:ack narrow after reading real sub values from CloudTrail, ROLLOUT.md "This week"
          }
        }
      }
    ]
  })
}

# NOT CHANGED: AdministratorAccess. End state: a read-only plan role for pull
# requests and a scoped, main-only apply role.
resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess" # tripwire:ack split into plan/apply roles, ROLLOUT.md "This quarter"
}

# Legacy CI user. Kept until the last two pipelines move to the OIDC role above.
# NOT CHANGED: the user, key and outputs. This is finding #1, but two live
# pipelines use the key and removing it from code deletes it in the same apply.
# The secret is also in plaintext in state (sensitive = true only hides it from
# the terminal). Retire it per ROLLOUT.md.
resource "aws_iam_user" "ci_deployer" { # tripwire:ack retire path in ROLLOUT.md
  name = "ci-deployer"
}

resource "aws_iam_user_policy_attachment" "ci_deployer" {
  user       = aws_iam_user.ci_deployer.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess" # tripwire:ack user is being retired, ROLLOUT.md "Today"/"This week"
}

resource "aws_iam_access_key" "ci_deployer" { # tripwire:ack retire path in ROLLOUT.md
  user = aws_iam_user.ci_deployer.name
}

output "ci_deployer_access_key_id" {
  value = aws_iam_access_key.ci_deployer.id
}

output "ci_deployer_secret_access_key" {
  value     = aws_iam_access_key.ci_deployer.secret
  sensitive = true
}

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------

# CHANGE (new): bring the existing GuardDuty detector (enabled by hand in the
# console) into code, using the ID from the finding ARN in INCIDENT.md. The plan
# must say "1 to import", not "1 to add"; if it says add, stop. Remove this
# import block after the apply.
import {
  to = aws_guardduty_detector.main
  id = "12abc34d567e8fa901bc2d34e56789f0"
}

resource "aws_guardduty_detector" "main" {
  enable = true
}

# Unencrypted on purpose: EventBridge can't publish with the AWS-managed SNS
# key, and the payload is GuardDuty metadata, never PHI.
resource "aws_sns_topic" "security_alerts" {
  name = "acme-security-alerts"
}

data "aws_iam_policy_document" "security_alerts" {
  statement {
    sid       = "AllowEventBridgePublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.guardduty_findings.arn]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts.json
}

# All severities, on purpose: the finding before the Part 4 compromise was 2.0.
resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "acme-guardduty-findings"
  description = "All GuardDuty findings, all severities, to the security alert topic."

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule = aws_cloudwatch_event_rule.guardduty_findings.name
  arn  = aws_sns_topic.security_alerts.arn
}

resource "aws_sns_topic_subscription" "security_email" {
  count = var.security_alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.security_alert_email
}
