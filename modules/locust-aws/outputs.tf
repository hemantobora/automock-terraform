output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_https_listener_arn" { value = aws_lb_listener.https.arn }
output "cluster_name" { value = aws_ecs_cluster.this.name }
output "namespace_name" { value = aws_service_discovery_private_dns_namespace.this.name }
output "master_service_name" { value = aws_ecs_service.master.name }
output "worker_service_name" { value = aws_ecs_service.worker.name }
output "security_group_ecs_id" { value = aws_security_group.ecs.id }
output "vpc_id" { value = aws_vpc.lt.id }
output "subnet_ids" { value = [aws_subnet.public_a.id, aws_subnet.public_b.id] }
output "cloud_map_master_fqdn" {
	value = "master.${aws_service_discovery_private_dns_namespace.this.name}"
}
