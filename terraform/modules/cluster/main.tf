resource "google_container_cluster" "primary" {
  provider   = google-beta
  name       = var.cluster_name
  location   = var.zone
  project    = var.project_id
  network    = var.network_name
  subnetwork = var.subnet_name

  # Allow clean teardown via terraform destroy
  deletion_protection = false

  # Enable Dataplane V2 (eBPF)
  datapath_provider = "ADVANCED_DATAPATH"

  # Remove default node pool immediately after cluster creation
  remove_default_node_pool = true
  initial_node_count       = 1

  # Workload Identity Configuration for zero-key GCS/Artifact Registry access
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Enable CSI driver
  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = true
    }
  }

  # Enforce private node allocation across all system and GPU nodes
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = var.enable_private_endpoint
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_cidrs) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_cidrs
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  # Automated GKE AI/ML Observability & Google Cloud Managed Service for Prometheus
  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "STORAGE",
      "APISERVER",
      "SCHEDULER",
      "CONTROLLER_MANAGER",
      "POD",
      "DEPLOYMENT",
      "DAEMONSET",
      "STATEFULSET",
      "HPA",
      "CADVISOR",
      "KUBELET",
      "DCGM"
    ]
    managed_prometheus {
      enabled = true
    }
    advanced_datapath_observability_config {
      enable_metrics = true
      enable_relay   = false
    }
  }

  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
      "APISERVER",
      "SCHEDULER",
      "CONTROLLER_MANAGER"
    ]
  }

  # Mandatory Resource Compliance Labels
  resource_labels = {
    env   = var.env_label
    owner = var.owner_label
    ttl   = var.ttl_label
  }
}

# Workload Identity IAM Service Account
resource "google_service_account" "vllm_sa" {
  account_id   = "glm52-vllm-sa"
  display_name = "GLM-5.2 vLLM Serving Workload Identity SA"
  project      = var.project_id
}

resource "google_project_iam_member" "storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.vllm_sa.email}"
}

resource "google_project_iam_member" "artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.vllm_sa.email}"
}

resource "google_service_account_iam_member" "workload_identity_user" {
  service_account_id = google_service_account.vllm_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[llm-serving/glm52-vllm-sa]"
}

# Lightweight Spot System Node Pool for kube-dns, metrics-server, and operators
resource "google_container_node_pool" "system_pool" {
  name       = "np-system-spot"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-standard-8"
    spot         = true
    disk_size_gb = 100

    labels = {
      env   = var.env_label
      owner = var.owner_label
      ttl   = var.ttl_label
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    ignore_changes = [node_count]
  }
}
