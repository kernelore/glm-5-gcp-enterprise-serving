# Standard Primary VPC Network for GKE Control Plane, Pod eth0, and Cloud NAT
resource "google_compute_network" "primary_net" {
  name                    = "${var.vpc_name}-primary"
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  mtu                     = 1500
}

# Primary Subnet for Kubernetes Pods & Services on Primary VPC
resource "google_compute_subnetwork" "primary_subnet" {
  name                     = var.subnet_name
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.primary_net.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true
}

# Cloud Router and NAT on Primary VPC for external egress (Hugging Face weight downloads)
resource "google_compute_router" "router" {
  name    = "glm52-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.primary_net.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "glm52-nat"
  project                            = var.project_id
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Firewall rule allowing internal VPC client connections across port 8000 (vLLM ILB / Pods)
resource "google_compute_firewall" "allow_internal_vllm" {
  name    = "allow-internal-vllm-8000"
  project = var.project_id
  network = google_compute_network.primary_net.id

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  source_ranges = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

# Firewall rule allowing SSH connections via IAP
resource "google_compute_firewall" "allow_ssh_glm52_primary" {
  name    = "allow-ssh-glm52-primary"
  project = var.project_id
  network = google_compute_network.primary_net.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
}

