variable "project_id" {
  description = "GCP Project ID where the GLM-5.2 infrastructure will be deployed"
  type        = string
}

variable "region" {
  description = "GCP Region for Sovereign Deployment (e.g., europe-north1)"
  type        = string
  default     = "europe-north1"
}

variable "zone" {
  description = "GCP Zone for Compact Placement and GPU Nodes (e.g., europe-north1-b for B200)"
  type        = string
  default     = "europe-north1-b"
}

variable "cluster_name" {
  description = "GKE Cluster Name"
  type        = string
  default     = "glm-enterprise-fi"
}

variable "gpu_machine_type" {
  description = "GPU Machine Type for Serving Pool (e.g., a4-highgpu-8g with 8x NVIDIA B200)"
  type        = string
  default     = "a4-highgpu-8g"
}

variable "owner_label" {
  description = "Mandatory Owner Label (must match ^[a-z0-9-_]+$)"
  type        = string
  default     = "opensource-user"
}

variable "ttl_label" {
  description = "Mandatory TTL Label (e.g., 7d, 24h)"
  type        = string
  default     = "7d"
}

variable "env_label" {
  description = "Mandatory Environment Label"
  type        = string
  default     = "glm52-test"
}

variable "db_tier" {
  description = "Cloud SQL machine tier for the gateway PostgreSQL instance"
  type        = string
  default     = "db-custom-2-8192"
}

variable "db_password" {
  description = "Password for the Cloud SQL gateway_admin user"
  type        = string
  sensitive   = true
}

variable "enable_private_endpoint" {
  description = "Whether to enable private endpoint on the GKE cluster control plane"
  type        = bool
  default     = false
}

variable "master_authorized_cidrs" {
  description = "List of CIDR blocks authorized to access the GKE master endpoint"
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "gpu_pool_max_nodes" {
  description = "Maximum number of GPU nodes for spot node pool autoscaling"
  type        = number
  default     = 2
}
