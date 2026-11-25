# BOOTSTRAP stack - run ONCE, by hand, with your own admin AWS profile.
#
# It creates the things the pipeline needs BEFORE it can run at all, so
# they can't be created by the pipeline itself (a chicken-and-egg problem):
#   - the S3 bucket that stores Terraform's state for infra/prod
#   - the ECR repositories the pipeline pushes images to
#   - a dedicated, narrowly scoped IAM user for Jenkins
#
# Its own state is a LOCAL file (terraform.tfstate, git-ignored): the state
# bucket doesn't exist yet, so it can't be stored there. That's acceptable
# because this stack is tiny, rarely changes, and contains no secrets.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Credentials come from the environment (AWS_PROFILE=atu), not from this
  # file - nothing account-specific or secret is hardcoded in the repo.

  default_tags {
    tags = {
      Project   = "SW-DevOps-CA3-CA4"
      Owner     = "L00205332"
      ManagedBy = "terraform-bootstrap"
    }
  }
}
