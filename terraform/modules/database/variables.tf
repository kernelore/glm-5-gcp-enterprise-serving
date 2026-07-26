variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for Cloud SQL instance"
  type        = string
}

variable "network_id" {
  description = "VPC network self link / ID for Private Services Access"
  type        = string
}

variable "db_tier" {
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-custom-2-8192"
}

variable "db_password" {
  description = "Password for the gateway_admin user"
  type        = string
  sensitive   = true
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
