output "dataset_id" {
  description = "BigQuery dataset ID"
  value       = google_bigquery_dataset.enterprise_audit.dataset_id
}

output "table_id" {
  description = "BigQuery table ID"
  value       = google_bigquery_table.trajectories.table_id
}
