# The orchestration layer: Amazon ECS on Fargate.
#
# ECS is the platform that keeps the three containers running (restarting
# crashed ones, replacing old versions with new ones during a deploy);
# Fargate means AWS provides the servers, so there are no machines to manage.
# In Kubernetes terms: the task definitions below are the "manifests", the
# services are the "deployments", and Cloud Map is the in-cluster DNS.

locals {
  tiers = ["frontend", "backend", "db"]

  # Smallest Fargate size. Valid CPU/memory pairs are fixed by AWS:
  # 256 CPU units (0.25 vCPU) supports 512, 1024 or 2048 MB.
  task_cpu    = 256
  task_memory = 512

  images = {
    for tier in local.tiers :
    tier => "${local.registry}/${var.name_prefix}-${tier}:${var.image_tag}"
  }

  # Where each container sends its logs (CloudWatch Logs).
  log_config = {
    for tier in local.tiers : tier => {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app[tier].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = tier
      }
    }
  }
}

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"
}

resource "aws_cloudwatch_log_group" "app" {
  for_each = toset(local.tiers)

  name              = "/ecs/${var.name_prefix}/${each.key}"
  retention_in_days = 7 # keeps CloudWatch storage costs near zero
}

# ---------------------------------------------------------------------------
# Service discovery (Cloud Map): how the tiers find each other
# ---------------------------------------------------------------------------
# Container IP addresses change every time a task is replaced, so nothing can
# hardcode them. Each service registers itself in a private DNS zone, and the
# others use the name: the frontend calls http://backend.tasktracker.local:8000
# and the backend connects to db.tasktracker.local:5432. The names resolve
# only inside the VPC.

resource "aws_service_discovery_private_dns_namespace" "main" {
  name = local.namespace
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "app" {
  for_each = toset(local.tiers)

  name = each.key

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10 # short, so a replaced task is found again within seconds
      type = "A"
    }
  }

  # ECS reports each task's health to Cloud Map, so a failed task drops out
  # of DNS. (Its old `failure_threshold` setting is deprecated: AWS now
  # always uses 1.)
  health_check_custom_config {}
}

# ---------------------------------------------------------------------------
# Permissions for the containers
# ---------------------------------------------------------------------------
# The "task execution role" is what ECS itself uses to START a task: pull the
# image, write logs, and fetch the secrets. The containers' own code gets no
# AWS permissions at all (no "task role"), because it never calls AWS.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name_prefix}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# AWS's standard policy: pull from ECR and write to CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Read exactly these two secrets - nothing else in Secrets Manager.
data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.db_password.arn,
      aws_secretsmanager_secret.database_url.arn,
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "read-database-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

# ---------------------------------------------------------------------------
# Task definitions: what to run (the "manifests")
# ---------------------------------------------------------------------------

# --- data tier ---
resource "aws_ecs_task_definition" "db" {
  family                   = "${var.name_prefix}-db"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.task_cpu
  memory                   = local.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  volume {
    name = "pgdata"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.db.id
      transit_encryption = "ENABLED" # data encrypted on the wire too

      authorization_config {
        access_point_id = aws_efs_access_point.db.id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "db"
    image     = local.images["db"]
    essential = true

    portMappings = [{ containerPort = 5432, protocol = "tcp" }]

    environment = [
      { name = "POSTGRES_DB", value = var.db_name },
      { name = "POSTGRES_USER", value = var.db_user },
      # Postgres refuses to initialise in a directory that already has
      # entries; using a sub-folder of the mount avoids tripping on the
      # mount point itself (the image's documented advice for volumes).
      { name = "PGDATA", value = "/var/lib/postgresql/data/pgdata" },
    ]

    # The password is injected from Secrets Manager at start-up; only the
    # secret's ARN appears here, never the value.
    secrets = [
      { name = "POSTGRES_PASSWORD", valueFrom = aws_secretsmanager_secret.db_password.arn },
    ]

    mountPoints = [{
      sourceVolume  = "pgdata"
      containerPath = "/var/lib/postgresql/data"
    }]

    healthCheck = {
      command     = ["CMD-SHELL", "pg_isready -U ${var.db_user} -d ${var.db_name}"]
      interval    = 10
      timeout     = 5
      retries     = 5
      startPeriod = 30
    }

    logConfiguration = local.log_config["db"]
  }])
}

# --- application tier ---
resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.name_prefix}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.task_cpu
  memory                   = local.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "backend"
    image     = local.images["backend"]
    essential = true

    portMappings = [{ containerPort = 8000, protocol = "tcp" }]

    # The complete connection URL (with the password) comes from Secrets
    # Manager as the DATABASE_URL variable that database.py reads.
    secrets = [
      { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.database_url.arn },
    ]

    # ECS ignores the Dockerfile's HEALTHCHECK, so it is restated here.
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')\""]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    logConfiguration = local.log_config["backend"]
  }])
}

# --- presentation tier ---
resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.name_prefix}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.task_cpu
  memory                   = local.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "frontend"
    image     = local.images["frontend"]
    essential = true

    portMappings = [{ containerPort = 5000, protocol = "tcp" }]

    # Found through Cloud Map's private DNS, not a fixed IP.
    environment = [
      { name = "BACKEND_URL", value = "http://backend.${local.namespace}:8000" },
    ]

    # Checks "/" (always 200), NOT "/healthz": that one returns 503 while the
    # backend is unreachable, which would make ECS kill and restart the
    # frontend in a loop whenever the backend is briefly down.
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:5000/')\""]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }

    logConfiguration = local.log_config["frontend"]
  }])
}

# ---------------------------------------------------------------------------
# Services: keep the task definitions running
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "db" {
  name            = "${var.name_prefix}-db"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.db.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Postgres must never have two copies running against the same EFS data
  # directory (that corrupts it). So during a deploy the old task is stopped
  # BEFORE the new one starts: 0% must stay healthy, never more than 100%.
  # The cost is a short database blip on each deploy; the backend reconnects.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  # Wait until the deploy has actually settled, so the pipeline's next stage
  # doesn't run against a half-finished rollout.
  wait_for_steady_state = true

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.db.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.app["db"].arn
  }

  depends_on = [aws_efs_mount_target.db]
}

resource "aws_ecs_service" "backend" {
  name            = "${var.name_prefix}-backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Rolling deploy with no downtime: start the new task, and only stop the
  # old one once the new one is healthy.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  wait_for_steady_state              = true

  # If the new version never becomes healthy, stop trying and go back to
  # the previous one automatically.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.backend.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.app["backend"].arn
  }

  depends_on = [aws_ecs_service.db]
}

resource "aws_ecs_service" "frontend" {
  name            = "${var.name_prefix}-frontend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  wait_for_steady_state              = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Don't judge the load balancer's health checks during start-up.
  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.frontend.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 5000
  }

  service_registries {
    registry_arn = aws_service_discovery_service.app["frontend"].arn
  }

  depends_on = [aws_lb_listener.http, aws_ecs_service.backend]
}
