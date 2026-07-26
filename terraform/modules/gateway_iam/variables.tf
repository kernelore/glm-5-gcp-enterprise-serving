variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "dataset_id" {
  description = "BigQuery dataset ID for enterprise audit trajectories"
  type        = string
}

variable "owner_label" {
  description = "Owner resource label (optional for module consistency)"
  type        = string
  default     = ""
}

variable "ttl_label" {
  description = "TTL resource label (optional for module consistency)"
  type        = string
  default     = ""
}

variable "env_label" {
  description = "Environment resource label (optional for module consistency)"
  type        = string
  default     = ""
}
