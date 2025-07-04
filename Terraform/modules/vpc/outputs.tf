output "vpc_id" {
  description = "The ID of the created VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "A list of public subnet IDs."
  value       = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
}

output "alb_sg_id" {
  description = "The ID of the Security Group for the ALB."
  value       = aws_security_group.alb_sg.id
}