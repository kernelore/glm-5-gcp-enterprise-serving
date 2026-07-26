output "node_pool_name" {
  description = "Name of the Blackwell Spot GPU node pool"
  value       = google_container_node_pool.blackwell_spot_pool.name
}
