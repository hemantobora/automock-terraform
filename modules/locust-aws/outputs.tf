output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_https_listener_arn" { value = aws_lb_listener.https.arn }
output "cluster_name" { value = aws_ecs_cluster.this.name }
output "namespace_name" { value = aws_service_discovery_private_dns_namespace.this.name }
output "master_service_name" { value = aws_ecs_service.master.name }
output "worker_service_name" { value = aws_ecs_service.worker.name }
output "worker_desired_count" { value = var.worker_desired_count }
output "security_group_ecs_id" { value = local.ecs_sg_id_resolved }
output "security_group_alb_id" { value = local.alb_sg_id_resolved }
output "vpc_id" { value = local.vpc_id_resolved }
output "subnet_ids" { value = local.public_subnet_ids_resolved }
output "cloud_map_master_fqdn" {
	value = "master.${aws_service_discovery_private_dns_namespace.this.name}"
}
