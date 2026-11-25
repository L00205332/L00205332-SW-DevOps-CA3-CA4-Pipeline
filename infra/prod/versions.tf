# PRODUCTION stack - the application's AWS infrastructure. This is what the
# Jenkinsfile's "Deploy to Prod" stage applies. It requires infra/bootstrap
# to have been applied first (it provides the state bucket used below).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state: Jenkins applies from a fresh checkout each run, so Terraform's
  # memory of what exists must live somewhere durable. A backend block can't
  # use variables, so the bucket name is written out; it must match
  # infra/bootstrap's `state_bucket_name`.
  backend "s3" {
    bucket  = "l00205332-sw-devops-ca3-tfstate"
    key     = "prod/terraform.tfstate"
    region  = "eu-west-1"
    encrypt = true

    # S3-native locking (Terraform >= 1.10): stops two applies running at the
    # same time and corrupting state, with no extra DynamoDB table needed.
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  # No credentials here: Jenkins injects them as environment variables
  # (from its credential store); locally, use AWS_PROFILE.

  default_tags {
    tags = {
      Project     = "SW-DevOps-CA3-CA4"
      Owner       = "L00205332"
      Environment = "production"
      ManagedBy   = "terraform"
    }
  }
}
