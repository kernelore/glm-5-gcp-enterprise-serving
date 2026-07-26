output "gateway_service_account_email" {
  description = "Enterprise Gateway Workload Identity Service Account Email"
  value       = google_service_account.gateway_sa.email
}
