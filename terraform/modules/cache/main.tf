resource "google_redis_instance" "gateway_cache" {
  name               = "glm52-gateway-cache"
  tier               = "BASIC"
  memory_size_gb     = 2
  region             = var.region
  project            = var.project_id
  redis_version      = "REDIS_6_X"
  authorized_network = var.network_id
  auth_enabled       = true

  labels = {
    env   = var.env_label
    owner = var.owner_label
    ttl   = var.ttl_label
  }
}
