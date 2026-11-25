# AWS-side alerting (CloudWatch alarms + SNS notifications).
#
# This is the "is production healthy right now?" layer. It complements the
# Prometheus/Grafana stack (monitoring/ in the repo), which shows the
# application's own metrics in detail. The Jenkinsfile's last stage also
# queries these alarms after every deploy, so a deploy that trips an alarm is
# reported by the pipeline itself (the "pipeline feedback loop").

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
}

# An email subscription needs a recipient, and the recipient must click the
# confirmation link AWS emails them. Skipped when no address is given.
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Visitors are getting server errors (HTTP 5xx from our containers).
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-5xx"
  alarm_description   = "5 or more server errors in 2 consecutive minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # no traffic is not an error

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# The load balancer has no frontend it considers healthy.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name_prefix}-unhealthy-hosts"
  alarm_description   = "At least one frontend target has failed its health check for 2 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.frontend.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# A service is running hot (a possible sign of a loop or a traffic spike).
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  for_each = toset(local.tiers)

  alarm_name          = "${var.name_prefix}-${each.key}-cpu-high"
  alarm_description   = "${each.key} CPU above 80% for 10 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = "${var.name_prefix}-${each.key}"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  depends_on = [
    aws_ecs_service.db,
    aws_ecs_service.backend,
    aws_ecs_service.frontend,
  ]
}
