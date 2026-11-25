variable "aws_region" {
  description = "AWS region everything lives in."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix for resource names (repositories, IAM user and roles)."
  type        = string
  default     = "tasktracker"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for infra/prod's Terraform state. Must match the bucket in infra/prod/versions.tf."
  type        = string
  default     = "l00205332-sw-devops-ca3-tfstate"
}
