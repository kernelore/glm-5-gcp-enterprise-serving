output "network_name" {
  value = google_compute_network.primary_net.name
}

output "network_id" {
  description = "Self link / ID of the primary VPC network"
  value       = google_compute_network.primary_net.id
}

output "primary_subnet_name" {
  value = google_compute_subnetwork.primary_subnet.name
}
