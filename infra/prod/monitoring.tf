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

# ---------------------------------------------------------------------------
# Production dashboard (CloudWatch), defined as code
# ---------------------------------------------------------------------------
# One page showing whether production is healthy: traffic, errors, latency,
# load-balancer target health, container CPU/memory, the state of every
# alarm, and recent error lines from the logs. AWS collects all of these
# metrics automatically, so there is nothing extra to run or pay for beyond
# the dashboard itself (the first 3 dashboards per account are free).

locals {
  alb_dim = ["LoadBalancer", aws_lb.main.arn_suffix]
  tg_dims = ["TargetGroup", aws_lb_target_group.frontend.arn_suffix, "LoadBalancer", aws_lb.main.arn_suffix]
}

resource "aws_cloudwatch_dashboard" "production" {
  dashboard_name = "${var.name_prefix}-production"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "alarm", x = 0, y = 0, width = 24, height = 3
        properties = {
          title = "Alarm status (same alarms the pipeline checks after every deploy)"
          alarms = concat(
            [aws_cloudwatch_metric_alarm.alb_5xx.arn, aws_cloudwatch_metric_alarm.unhealthy_hosts.arn],
            [for alarm in aws_cloudwatch_metric_alarm.cpu_high : alarm.arn],
          )
        }
      },
      {
        type = "metric", x = 0, y = 3, width = 8, height = 6
        properties = {
          title   = "Requests per minute"
          region  = var.aws_region
          view    = "timeSeries"
          stat    = "Sum"
          period  = 60
          metrics = [concat(["AWS/ApplicationELB", "RequestCount"], local.alb_dim)]
        }
      },
      {
        type = "metric", x = 8, y = 3, width = 8, height = 6
        properties = {
          title  = "Server errors (5xx) per minute"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.alb_dim, [{ label = "from containers" }]),
            concat(["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count"], local.alb_dim, [{ label = "from load balancer" }]),
          ]
        }
      },
      {
        type = "metric", x = 16, y = 3, width = 8, height = 6
        properties = {
          title  = "Response time (p50 / p95)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p50", label = "p50" }]),
            concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim, [{ stat = "p95", label = "p95" }]),
          ]
        }
      },
      {
        type = "metric", x = 0, y = 9, width = 8, height = 6
        properties = {
          title  = "Load balancer targets (frontend tasks)"
          region = var.aws_region
          view   = "timeSeries"
          period = 60
          metrics = [
            concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg_dims, [{ stat = "Minimum", label = "healthy" }]),
            concat(["AWS/ApplicationELB", "UnHealthyHostCount"], local.tg_dims, [{ stat = "Maximum", label = "unhealthy" }]),
          ]
        }
      },
      {
        type = "metric", x = 8, y = 9, width = 8, height = 6
        properties = {
          title  = "Container CPU % by tier"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            for tier in local.tiers :
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", "${var.name_prefix}-${tier}", { label = tier }]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 9, width = 8, height = 6
        properties = {
          title  = "Container memory % by tier"
          region = var.aws_region
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            for tier in local.tiers :
            ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.main.name, "ServiceName", "${var.name_prefix}-${tier}", { label = tier }]
          ]
        }
      },
      {
        type = "log", x = 0, y = 15, width = 24, height = 6
        properties = {
          title  = "Recent errors in the application logs (all three tiers)"
          region = var.aws_region
          view   = "table"
          query = join(" | ", concat(
            [for tier in local.tiers : "SOURCE '${aws_cloudwatch_log_group.app[tier].name}'"],
            [
              "fields @timestamp, @logStream, @message",
              "filter @message like /(?i)(error|exception|traceback|fatal)/",
              "sort @timestamp desc",
              "limit 20",
            ],
          ))
        }
      },
    ]
  })
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
