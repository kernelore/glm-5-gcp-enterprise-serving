# 1,000 GB Persistent Hyperdisk ML Staging Volume for NVFP4 Weights
resource "google_compute_disk" "staging_disk" {
  name    = "glm-52-weights-rox"
  type    = "hyperdisk-ml"
  size    = 1000
  zone    = var.zone
  project = var.project_id

  labels = {
    env   = var.env_label
    owner = var.owner_label
    ttl   = var.ttl_label
    model = "glm52"
  }

  lifecycle {
    ignore_changes = [access_mode]
  }
}

# Trajectory and Logging Bucket (7-day lifecycle)
resource "google_storage_bucket" "trajectory_bucket" {
  name                        = "${var.project_id}-glm52-trajectories"
  location                    = var.region
  project                     = var.project_id
  force_destroy               = true
  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    env   = var.env_label
    owner = var.owner_label
    ttl   = var.ttl_label
  }
}

# Sovereign Artifact Registry Repository for vLLM Container Images
resource "google_artifact_registry_repository" "glm_repo" {
  location      = var.region
  repository_id = "glm-prod"
  description   = "Docker container repository for GLM-5.2 inference & staging engines"
  format        = "DOCKER"
  project       = var.project_id

  labels = {
    env   = var.env_label
    owner = var.owner_label
    ttl   = var.ttl_label
  }
}
