output "bastion_host_security_group" {
  description = "The security group ID of the Bastion Host"
  value       = aws_security_group.bastion_host_security_group[*].id
}

output "bucket_name" {
  description = "The name of the bucket where logs are sent"
  value       = aws_s3_bucket.bucket.bucket
}

output "elb_ip" {
  description = "The ELB DNS Name for the Bastion Host instances"
  value       = aws_lb.bastion_lb.dns_name
}

output "private_instances_security_group" {
  description = "The security group ID of the the private instances that allow Bastion SSH ingress"
  value       = aws_security_group.private_instances_security_group.id
}

