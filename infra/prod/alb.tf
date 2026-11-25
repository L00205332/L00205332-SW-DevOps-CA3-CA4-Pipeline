# The public entry point: an Application Load Balancer.
#
# It is the only thing in the project reachable from the internet. It
# forwards to the frontend containers, and only to the ones that report
# healthy - so a deploy that breaks the app never receives traffic.
#
# HTTP only (port 80): HTTPS needs a domain name and a certificate, which is
# outside this assignment. With a domain, the next step is an ACM certificate
# plus an HTTPS (443) listener that redirects port 80.

resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "frontend" {
  name        = "${var.name_prefix}-frontend"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # Fargate tasks register by IP address

  # How quickly a stopping task is drained. The default (5 minutes) makes
  # every deploy feel stuck; 30s is plenty for short web requests.
  deregistration_delay = 30

  # /healthz on the frontend returns 503 whenever the BACKEND is unreachable,
  # so the load balancer only sends visitors to a frontend that can really
  # serve them. (The container's own health check, in ecs.tf, deliberately
  # uses `/` instead - otherwise a slow backend would make ECS kill the
  # frontend in a loop.)
  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}
