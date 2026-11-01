###############################################################################
# Outputs
#
# Printed after `terraform apply`, and available any time with
#   terraform output
#   terraform output -raw alb_dns_name
###############################################################################

output "vpc_id" {
  description = "ID of the VPC hosting all resources."
  value       = aws_vpc.main.id
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer. Open http://<this value>/health to reach the backend."
  value       = aws_lb.main.dns_name
}

output "bastion_public_ip" {
  description = "Elastic IP of the bastion host. SSH target for all administrative access."
  value       = aws_eip.bastion.public_ip
}

output "backend_private_ip" {
  description = "Private IP of the backend server. Reachable only through the bastion."
  value       = aws_instance.backend.private_ip
}

# --- Convenience outputs -----------------------------------------------------
# Not required by the brief, but they remove the guesswork from the deployment
# steps in the README.

output "mongodb_private_ip" {
  description = "Private IP of the MongoDB server."
  value       = aws_instance.mongodb.private_ip
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the two private subnets."
  value       = aws_subnet.private[*].id
}

output "ssh_to_backend_command" {
  description = "Ready-to-run command that SSHes to the backend server by jumping through the bastion."
  value       = "ssh -J ec2-user@${aws_eip.bastion.public_ip} ec2-user@${aws_instance.backend.private_ip}"
}

output "health_check_url" {
  description = "Full URL to verify the deployment through the load balancer."
  value       = "http://${aws_lb.main.dns_name}/health"
}
