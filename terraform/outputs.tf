output "project_id" {
  description = "GCP Project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP Region"
  value       = var.region
}

output "zone" {
  description = "GCP Zone"
  value       = var.zone
}

output "vpc_network_name" {
  description = "Primary VPC network name"
  value       = module.network.network_name
}

output "gke_cluster_endpoint" {
  description = "GKE Control Plane Endpoint"
  value       = module.cluster.endpoint
}

output "workload_identity_sa" {
  description = "Workload Identity Service Account Email"
  value       = module.cluster.vllm_service_account_email
}

output "hyperdisk_ml_rox_volume" {
  description = "1,000 GB Hyperdisk ML ROX volume ID"
  value       = module.storage.hyperdisk_ml_rox_id
}

output "trajectory_bucket_name" {
  description = "Trajectory and logging GCS bucket name"
  value       = module.storage.trajectory_bucket_name
}

output "artifact_registry_repo" {
  description = "Artifact Registry Docker repository ID"
  value       = module.storage.artifact_registry_repo
}

output "db_instance_connection_name" {
  description = "Cloud SQL database instance connection name for Cloud SQL Auth Proxy"
  value       = module.database.db_instance_connection_name
}

output "db_host" {
  description = "Cloud SQL database private IP host address"
  value       = module.database.db_host
}

output "db_user" {
  description = "Cloud SQL database username"
  value       = module.database.db_user
}

output "redis_host" {
  description = "Cloud Memorystore Redis host IP address"
  value       = module.cache.redis_host
}

output "redis_port" {
  description = "Cloud Memorystore Redis port number"
  value       = module.cache.redis_port
}

output "redis_auth_string" {
  description = "Cloud Memorystore Redis auth string"
  value       = module.cache.redis_auth_string
  sensitive   = true
}

output "audit_dataset_id" {
  description = "BigQuery dataset ID for enterprise audit trajectories"
  value       = module.audit.dataset_id
}

output "audit_table_id" {
  description = "BigQuery table ID for enterprise audit trajectories"
  value       = module.audit.table_id
}

output "gateway_service_account_email" {
  description = "Workload Identity Service Account Email for the Enterprise AI Gateway"
  value       = module.gateway_iam.gateway_service_account_email
}
