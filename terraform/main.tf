###############################################################################
# StartupTech - MuchToDo backend infrastructure
#
# Creates:
#   * a VPC with two public and two private subnets across two AZs
#   * an Internet Gateway and a NAT Gateway
#   * four security groups wired for least-privilege access
#   * three EC2 instances (bastion, backend, MongoDB)
#   * an Application Load Balancer fronting the backend on port 8080
#
# Traffic path:
#   internet -> ALB (public subnets, :80) -> backend (private subnet, :8080)
#   backend  -> MongoDB (private subnet, :27017)
#   admin    -> bastion (public subnet, :22) -> backend / MongoDB (:22)
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Applied to every resource that supports tagging, so individual resources
  # only need to declare their own Name.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

###############################################################################
# Data sources
###############################################################################

# Availability zones currently usable by this account in this region. Using the
# first two keeps the configuration portable across regions instead of
# hard-coding zone names.
data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Amazon Linux 2 AMI, looked up at apply time rather than pinned to an
# ID that would only be valid in one region.
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name_prefix = var.project_name

  # Two AZs, reused by both the public and the private subnets so that each
  # tier is spread across the same pair of zones.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

###############################################################################
# Networking - VPC, subnets, gateways, routing
###############################################################################

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Required so instances receive internal DNS names, and so the MongoDB and
  # backend servers can resolve each other and reach the internet by hostname.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# --- Public subnets ----------------------------------------------------------
# Host the ALB, the bastion and the NAT Gateway. Instances here get a public IP.
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-subnet-${count.index + 1}"
    Tier = "public"
  }
}

# --- Private subnets ---------------------------------------------------------
# Host the backend and MongoDB servers. No public IPs; outbound internet access
# (for yum, Docker Hub and GitHub) goes through the NAT Gateway.
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.name_prefix}-private-subnet-${count.index + 1}"
    Tier = "private"
  }
}

# --- NAT Gateway -------------------------------------------------------------
# Billed hourly plus data processing, so destroy the stack when you are done.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  # The NAT Gateway cannot route anywhere until the IGW is attached, and
  # Terraform cannot infer that ordering on its own.
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${local.name_prefix}-nat"
  }
}

# --- Route tables ------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

###############################################################################
# Security groups
#
# Rules are declared as standalone aws_vpc_security_group_*_rule resources
# rather than inline blocks. Inline rules that reference each other (the ALB
# needing egress to the backend, the backend needing ingress from the ALB)
# create a dependency cycle that Terraform cannot resolve; separate rule
# resources break it.
###############################################################################

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB - public HTTP/HTTPS in, backend port out"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-bastion-sg"
  description = "Bastion - SSH from the operator IP only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-bastion-sg"
  }
}

resource "aws_security_group" "backend" {
  name        = "${local.name_prefix}-backend-sg"
  description = "Backend - app port from the ALB, SSH from the bastion"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-backend-sg"
  }
}

resource "aws_security_group" "mongodb" {
  name        = "${local.name_prefix}-mongodb-sg"
  description = "MongoDB - 27017 from the backend, SSH from the bastion"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-mongodb-sg"
  }
}

# --- ALB rules ---------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# The ALB only ever needs to reach the backend target port - nothing else.
resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward traffic and health checks to the backend"
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = var.backend_port
  to_port                      = var.backend_port
  ip_protocol                  = "tcp"
}

# --- Bastion rules -----------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  description       = "SSH from the operator IP only"
  cidr_ipv4         = var.my_ip_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  security_group_id = aws_security_group.bastion.id
  description       = "Outbound for yum updates and onward SSH"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Backend rules -----------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend.id
  description                  = "Application port from the ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.backend_port
  to_port                      = var.backend_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "backend_ssh_from_bastion" {
  security_group_id            = aws_security_group.backend.id
  description                  = "SSH from the bastion only"
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

# Outbound is open so the instance can reach Docker Hub, GitHub and yum
# through the NAT Gateway. It has no public IP, so nothing can reach it
# unsolicited from the internet.
resource "aws_vpc_security_group_egress_rule" "backend_all" {
  security_group_id = aws_security_group.backend.id
  description       = "Outbound via NAT for packages, images and git"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- MongoDB rules -----------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "mongodb_from_backend" {
  security_group_id            = aws_security_group.mongodb.id
  description                  = "MongoDB port from the backend only"
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 27017
  to_port                      = 27017
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "mongodb_ssh_from_bastion" {
  security_group_id            = aws_security_group.mongodb.id
  description                  = "SSH from the bastion only"
  referenced_security_group_id = aws_security_group.bastion.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "mongodb_all" {
  security_group_id = aws_security_group.mongodb.id
  description       = "Outbound via NAT for the MongoDB package repository"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

###############################################################################
# Key pair
###############################################################################

# Only the public key is uploaded. The private key stays on your machine and
# never enters Terraform state.
resource "aws_key_pair" "main" {
  key_name   = "${local.name_prefix}-key"
  public_key = var.ssh_public_key

  tags = {
    Name = "${local.name_prefix}-key"
  }
}

###############################################################################
# EC2 instances
###############################################################################

# --- Bastion -----------------------------------------------------------------
# The only instance reachable from the internet, and only on SSH from one IP.
resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.bastion_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = aws_key_pair.main.key_name

  tags = {
    Name = "${local.name_prefix}-bastion"
    Role = "bastion"
  }
}

# A static address, so the SSH command in the README stays valid across
# instance stop/start cycles.
resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${local.name_prefix}-bastion-eip"
  }
}

# --- Backend -----------------------------------------------------------------
resource "aws_instance" "backend" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.backend_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.backend.id]
  key_name               = aws_key_pair.main.key_name

  user_data = file("${path.module}/user_data/backend_setup.sh")

  # Re-run the bootstrap if the script changes, instead of leaving a stale
  # instance behind. Replaces the instance on apply.
  user_data_replace_on_change = true

  # The instance has no public IP, so its only path to the internet is the NAT
  # Gateway. cloud-init runs user_data within about a minute of boot, and the
  # script's first action is `yum update`. Without this dependency Terraform is
  # free to create the instance alongside the NAT Gateway and the private route
  # table association, and the bootstrap then fails with
  # "Connection timeout" before any package is installed.
  depends_on = [
    aws_nat_gateway.main,
    aws_route_table_association.private,
  ]

  tags = {
    Name = "${local.name_prefix}-backend"
    Role = "backend"
  }
}

# --- MongoDB -----------------------------------------------------------------
# Placed in the second private subnet, so the data tier sits in a different
# availability zone from the application tier.
resource "aws_instance" "mongodb" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = var.mongodb_instance_type
  subnet_id              = aws_subnet.private[1].id
  vpc_security_group_ids = [aws_security_group.mongodb.id]
  key_name               = aws_key_pair.main.key_name

  user_data                   = file("${path.module}/user_data/mongodb_setup.sh")
  user_data_replace_on_change = true

  # Same reason as the backend instance: the MongoDB bootstrap adds a yum
  # repository and installs packages, so it needs the NAT route in place
  # before cloud-init runs.
  depends_on = [
    aws_nat_gateway.main,
    aws_route_table_association.private,
  ]

  tags = {
    Name = "${local.name_prefix}-mongodb"
    Role = "database"
  }
}

###############################################################################
# Application Load Balancer
###############################################################################

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]

  # An ALB requires subnets in at least two availability zones.
  subnets = aws_subnet.public[*].id

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "backend" {
  name        = "${local.name_prefix}-backend-tg"
  port        = var.backend_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled = true
    path    = var.health_check_path
    port    = "traffic-port"
    matcher = "200"

    # The application's /health endpoint returns 503 when MongoDB is
    # unreachable, so a healthy target means the whole path works, not just
    # that something is listening on the port.
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-backend-tg"
  }
}

resource "aws_lb_target_group_attachment" "backend" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.backend.id
  port             = var.backend_port
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}
