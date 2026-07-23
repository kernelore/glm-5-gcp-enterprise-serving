output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "endpoint" {
  value = google_container_cluster.primary.endpoint
}

output "vllm_service_account_email" {
  value = google_service_account.vllm_sa.email
}
