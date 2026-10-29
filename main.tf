terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "acme-health-terraform-state"
    key     = "platform/prod.tfstate"
    region  = "us-east-1"
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
  type    = string
  default = "Acme-Clinical-2024!"
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
  bucket                  = aws_s3_bucket.raw_landing.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "raw_landing" {
  bucket = aws_s3_bucket.raw_landing.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PartnerAccess"
        Effect    = "Allow"
        Principal = "*"
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
  bucket        = "acme-health-audit-logs"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

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
      }
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "acme-trail"
  s3_bucket_name                = aws_s3_bucket.audit_logs.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = false

  depends_on = [aws_s3_bucket_policy.audit_logs]
}

# -----------------------------------------------------------------------------
# Container platform
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "document_parser" {
  name                 = "document-parser"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
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

  container_definitions = jsonencode([
    {
      name      = "parser"
      image     = "${aws_ecr_repository.document_parser.repository_url}:latest"
      essential = true
      environment = [
        { name = "DB_HOST", value = aws_db_instance.clinical.address },
        { name = "DB_USER", value = "acme_admin" },
        { name = "DB_PASSWORD", value = var.db_password },
        # DEBUG logs the extracted text of every page, which makes OCR issues easy to troubleshoot.
        { name = "LOG_LEVEL", value = "DEBUG" },
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

  ingress {
    description = "Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

  publicly_accessible     = true
  storage_encrypted       = false
  backup_retention_period = 0
  deletion_protection     = false
  skip_final_snapshot     = true
}

# -----------------------------------------------------------------------------
# CI/CD
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

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
            "token.actions.githubusercontent.com:sub" = "repo:acme-health/*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Legacy CI user. Kept until the last two pipelines move to the OIDC role above.
resource "aws_iam_user" "ci_deployer" {
  name = "ci-deployer"
}

resource "aws_iam_user_policy_attachment" "ci_deployer" {
  user       = aws_iam_user.ci_deployer.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_access_key" "ci_deployer" {
  user = aws_iam_user.ci_deployer.name
}

output "ci_deployer_access_key_id" {
  value = aws_iam_access_key.ci_deployer.id
}

output "ci_deployer_secret_access_key" {
  value     = aws_iam_access_key.ci_deployer.secret
  sensitive = true
}
