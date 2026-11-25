# ---------------------------------------------------------------------------
# 1. Remote state bucket for infra/prod
# ---------------------------------------------------------------------------
# Terraform records what it has built in a "state" file. Jenkins runs
# `terraform apply` from a fresh checkout every time, so that file can't
# live in the workspace - it has to be stored somewhere durable and shared.

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name
}

# Keep every previous version of the state: if a bad apply corrupts it, the
# last good one can be restored.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# State can contain sensitive values (e.g. the generated database password),
# so encrypt it at rest and never allow public access.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 2. ECR repositories (one per image the pipeline builds)
# ---------------------------------------------------------------------------
# These must exist before the pipeline's Containerise stage can push, and
# that stage runs BEFORE the stage that applies infra/prod - hence here.

locals {
  repositories = toset(["backend", "frontend", "db"])
}

resource "aws_ecr_repository" "app" {
  for_each = local.repositories

  name = "${var.name_prefix}-${each.key}"

  # MUTABLE so re-running a build of the same commit can re-push its tag.
  # (IMMUTABLE is stricter, but would fail a pipeline re-run.)
  image_tag_mutability = "MUTABLE"

  # Lets `terraform destroy` remove the repository even if it holds images,
  # so tearing the whole project down (to stop costs) never gets stuck.
  force_delete = true

  # AWS scans each pushed image for known vulnerabilities - a second opinion
  # on top of the pipeline's own Trivy scan.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Old images cost storage money; keep only the 10 most recent per repository.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------------------
# 3. A dedicated IAM user for Jenkins (least privilege)
# ---------------------------------------------------------------------------
# Jenkins must NOT use your personal admin keys: if they leaked, the whole
# account would be exposed. This user can only do what the pipeline needs:
# push images, keep infra/prod's state, and manage the project's own
# resources in one region.
#
# The access KEY is deliberately not created here: Terraform would store the
# secret in its state file. You create it by hand in the AWS console instead
# (see the README runbook) and paste it straight into Jenkins.

data "aws_caller_identity" "current" {}

resource "aws_iam_user" "jenkins" {
  name = "${var.name_prefix}-jenkins-ci"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  role_arn   = "arn:aws:iam::${local.account_id}:role/${var.name_prefix}-*"
}

data "aws_iam_policy_document" "jenkins" {
  # Log in to ECR (a token request has no resource to scope it to).
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push and inspect images - only in this project's repositories.
  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for repo in aws_ecr_repository.app : repo.arn]
  }

  # Read and write infra/prod's Terraform state - nothing else in S3.
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/prod/*"]
  }

  # The services infra/prod uses, limited to one region. Creating a VPC,
  # load balancer etc. can't be restricted to individual resources up front
  # (they don't exist yet), so the region is the boundary. Services the
  # project doesn't use (RDS, Lambda, DynamoDB, ...) are simply not granted.
  statement {
    sid = "ProjectServicesInOneRegion"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "ecs:*",
      "elasticfilesystem:*",
      "logs:*",
      "cloudwatch:*",
      "sns:*",
      "secretsmanager:*",
      "servicediscovery:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  # Cloud Map's private DNS namespace is backed by a Route 53 private hosted
  # zone. Route 53 is a global service, so it can't carry the region
  # condition above.
  statement {
    sid = "Route53ForCloudMap"
    actions = [
      "route53:AssociateVPCWithHostedZone",
      "route53:ChangeResourceRecordSets",
      "route53:ChangeTagsForResource",
      "route53:CreateHostedZone",
      "route53:DeleteHostedZone",
      "route53:GetChange",
      "route53:GetHostedZone",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # IAM is the dangerous one (it can grant itself more power), so it is the
  # most tightly scoped: only roles named "<prefix>-*", never users or
  # policies, never anything else in the account.
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [local.role_arn]
  }

  # Allow handing those roles to ECS tasks - and only to ECS tasks.
  statement {
    sid       = "PassRolesToEcsTasks"
    actions   = ["iam:PassRole"]
    resources = [local.role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # AWS creates these helper roles the first time ECS/load balancers/EFS are
  # used in an account.
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "elasticfilesystem.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_policy" "jenkins" {
  name        = "${var.name_prefix}-jenkins-ci"
  description = "Least-privilege permissions for the Jenkins pipeline (ECR push, Terraform state, project resources in one region)."
  policy      = data.aws_iam_policy_document.jenkins.json
}

resource "aws_iam_user_policy_attachment" "jenkins" {
  user       = aws_iam_user.jenkins.name
  policy_arn = aws_iam_policy.jenkins.arn
}
