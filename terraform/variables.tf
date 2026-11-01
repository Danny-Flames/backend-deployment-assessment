###############################################################################
# Input variables
#
# Real values go in terraform.tfvars, which is gitignored.
# terraform.tfvars.example shows the expected shape.
###############################################################################

variable "aws_region" {
  description = "AWS region in which all resources are created."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix applied to every resource and used in Name tags."
  type        = string
  default     = "startuptech"
}

variable "environment" {
  description = "Deployment environment, used in tags (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets. Must contain exactly two, placed in different availability zones."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly two public subnet CIDRs are required, one per availability zone."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets. Must contain exactly two, placed in different availability zones."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly two private subnet CIDRs are required, one per availability zone."
  }
}

# -----------------------------------------------------------------------------
# Compute
# -----------------------------------------------------------------------------

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host."
  type        = string
  default     = "t3.micro"
}

variable "backend_instance_type" {
  description = "EC2 instance type for the backend application server."
  type        = string
  default     = "t3.micro"
}

variable "mongodb_instance_type" {
  description = "EC2 instance type for the MongoDB server."
  type        = string
  default     = "t3.micro"
}

# -----------------------------------------------------------------------------
# Access
# -----------------------------------------------------------------------------

variable "my_ip_cidr" {
  description = <<-EOT
    Your current public IP in CIDR notation, used as the only source allowed to
    SSH into the bastion host. Find it with:  curl -s https://checkip.amazonaws.com
    then append /32, e.g. "102.88.115.10/32".

    Note: most home and mobile connections get a new IP periodically. If SSH
    starts timing out, re-run that command and `terraform apply` again.
  EOT
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "my_ip_cidr must be valid CIDR notation, for example \"203.0.113.25/32\"."
  }

  validation {
    condition     = var.my_ip_cidr != "0.0.0.0/0"
    error_message = "my_ip_cidr must not be 0.0.0.0/0 - that would expose SSH to the entire internet."
  }
}

variable "ssh_public_key" {
  description = <<-EOT
    Contents of the SSH public key to install on all three instances, e.g. the
    contents of ~/.ssh/id_rsa.pub or ~/.ssh/id_ed25519.pub.

    Only the PUBLIC key goes here. The private key never leaves your machine
    and must never be committed or placed in Terraform state.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) ", var.ssh_public_key))
    error_message = "ssh_public_key must be an OpenSSH public key, starting with ssh-rsa, ssh-ed25519 or ecdsa-sha2-."
  }
}

# -----------------------------------------------------------------------------
# Application
# -----------------------------------------------------------------------------

variable "backend_port" {
  description = "Port the backend API listens on inside the container and on the instance."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Path the ALB target group polls to decide whether the backend is healthy."
  type        = string
  default     = "/health"
}
