variable "aws_region" {
  description = "AWS region everything is deployed to."
  type        = string
  default     = "eu-west-1"
}

variable "name_prefix" {
  description = "Prefix for resource names. Must match the prefix used in infra/bootstrap (the Jenkins IAM policy only allows roles starting with it)."
  type        = string
  default     = "tasktracker"
}

variable "image_tag" {
  description = "Tag of the three container images to run - the pipeline passes the git commit SHA. No default on purpose: a deploy must always say WHICH build it is deploying."
  type        = string
}

variable "vpc_cidr" {
  description = "IP range of the project's private network."
  type        = string
  default     = "10.20.0.0/16"
}

variable "db_name" {
  description = "Name of the Postgres database."
  type        = string
  default     = "tasktracker"
}

variable "db_user" {
  description = "Postgres user the application connects as."
  type        = string
  default     = "tasktracker"
}

variable "alert_email" {
  description = "Email address to notify when an alarm fires. Leave empty to create the alarms without an email subscription."
  type        = string
  default     = ""
}
