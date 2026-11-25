output "state_bucket" {
  description = "S3 bucket holding infra/prod's Terraform state."
  value       = aws_s3_bucket.tfstate.bucket
}

output "ecr_registry" {
  description = "Registry host the pipeline pushes to (the Jenkinsfile's ECR_REGISTRY must match this)."
  value       = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repositories" {
  description = "Repository URLs, one per image."
  value       = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "jenkins_iam_user" {
  description = "The IAM user to create an access key for (in the AWS console) and give to Jenkins."
  value       = aws_iam_user.jenkins.name
}
