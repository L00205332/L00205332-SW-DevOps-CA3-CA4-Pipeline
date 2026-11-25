data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Two availability zones: if one data centre has a problem, the load
  # balancer and services keep working from the other.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Where the pipeline pushed the images (infra/bootstrap created the repos).
  registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

  # Private DNS domain the services use to find each other, e.g.
  # backend.tasktracker.local (see ecs.tf).
  namespace = "${var.name_prefix}.local"
}

# ---------------------------------------------------------------------------
# The network
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both are required for the private DNS names in ecs.tf to resolve.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-igw" }
}

# Public subnets, one per availability zone. Cost note: a more locked-down
# design puts the containers in PRIVATE subnets behind a NAT gateway, but NAT
# costs roughly $32/month on its own. Here the containers get public IPs only
# so they can pull images and send logs; the security groups below still
# allow NO inbound traffic except from the tier in front of them.
resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security groups: each tier only accepts traffic from the tier in front of it
#
#   internet --80--> ALB --5000--> frontend --8000--> backend --5432--> db
#                                                                        |
#                                                          EFS <--2049---+
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public entry point: HTTP from the internet"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "frontend" {
  name        = "${var.name_prefix}-frontend"
  description = "Presentation tier: only the load balancer may connect"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "backend" {
  name        = "${var.name_prefix}-backend"
  description = "Application tier: only the frontend may connect"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "Data tier: only the backend may connect"
  vpc_id      = aws_vpc.main.id
}

resource "aws_security_group" "efs" {
  name        = "${var.name_prefix}-efs"
  description = "Database storage: only the database may mount it"
  vpc_id      = aws_vpc.main.id
}

# --- inbound rules ---

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id            = aws_security_group.frontend.id
  description                  = "Flask UI from the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = 5000
  to_port                      = 5000
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_frontend" {
  security_group_id            = aws_security_group.backend.id
  description                  = "API from the frontend"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.frontend.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_backend" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from the backend"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.backend.id
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_db" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the database"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = aws_security_group.db.id
}

# --- outbound rules ---
# The load balancer and the three containers need to reach out (pull images
# from ECR, ship logs, resolve DNS). EFS never initiates connections.

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "frontend_all" {
  security_group_id = aws_security_group.frontend.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "backend_all" {
  security_group_id = aws_security_group.backend.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "db_all" {
  security_group_id = aws_security_group.db.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
