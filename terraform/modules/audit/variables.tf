variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region for BigQuery dataset location"
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
