variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }
variable "cluster_name" { type = string }
variable "network_name" { type = string }
variable "subnet_name" { type = string }
variable "owner_label" { type = string }
variable "ttl_label" { type = string }
variable "env_label" { type = string }

variable "enable_private_endpoint" {
  description = "Whether to enable private endpoint on the GKE cluster control plane"
  type        = bool
  default     = false
}

variable "master_authorized_cidrs" {
  description = "List of master authorized CIDR blocks"
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}
