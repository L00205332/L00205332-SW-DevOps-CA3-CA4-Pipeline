output "alb_dns_name" {
  description = "Public DNS name of the load balancer."
  value       = aws_lb.main.dns_name
}

output "alb_url" {
  description = "Where the application is reachable. The Jenkinsfile's last stage smoke-tests this."
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecs_cluster" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "log_groups" {
  description = "CloudWatch log groups, one per tier."
  value       = { for tier, group in aws_cloudwatch_log_group.app : tier => group.name }
}

output "dashboard_url" {
  description = "Link to the production CloudWatch dashboard (requires an AWS console login)."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.production.dashboard_name}"
}

output "alerts_topic_arn" {
  description = "SNS topic the alarms publish to."
  value       = aws_sns_topic.alerts.arn
}
