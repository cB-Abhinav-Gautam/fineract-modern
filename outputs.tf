output "service_url" {
  description = "Public HTTPS base URL for the accounting API."
  value       = "https://${module.alb.dns_name}${var.service_context_path}"
}

output "alb_dns_name" {
  description = "DNS name of the application load balancer; point your CNAME here."
  value       = module.alb.dns_name
}

output "ecr_repository_url" {
  description = "Push the accounting image built from the repository Dockerfile here."
  value       = module.ecr.repository_url
}

output "postgres_endpoint" {
  description = "PostgreSQL endpoint backing the Fineract CN seshat database."
  value       = module.postgresql.db_instance_endpoint
}

output "postgres_master_secret_arn" {
  description = "Secrets Manager secret holding the RDS master credential."
  value       = module.postgresql.db_instance_master_user_secret_arn
}

output "keyspace_name" {
  description = "Amazon Keyspaces keyspace used as the Cassandra backend."
  value       = aws_keyspaces_keyspace.main.name
}

output "mq_broker_endpoints" {
  description = "ActiveMQ broker wire-level endpoints."
  value       = aws_mq_broker.fineract.instances[*].endpoints
}

output "mq_credential_secret_arn" {
  description = "Secrets Manager secret holding the ActiveMQ application credential."
  value       = aws_secretsmanager_secret.mq.arn
}

output "mq_rotation_function_name" {
  description = "Lambda function that rotates the ActiveMQ credential."
  value       = aws_lambda_function.mq_rotation.function_name
}

output "ecs_cluster_name" {
  description = "ECS cluster running the accounting service."
  value       = aws_ecs_cluster.main.name
}

output "kms_key_arn" {
  description = "Customer-managed key encrypting the stack's data at rest."
  value       = aws_kms_key.main.arn
}
