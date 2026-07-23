variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for Cloud Memorystore Redis instance"
  type        = string
}

variable "network_id" {
  description = "VPC network self link / ID for Cloud Memorystore Redis connection"
  type        = string
}

variable "owner_label" {
  description = "Owner resource label"
  type        = string
}

variable "ttl_label" {
  description = "TTL resource label"
  type        = string
}

variable "env_label" {
  description = "Environment resource label"
  type        = string
}
