variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }
variable "cluster_name" { type = string }
variable "gpu_machine_type" { type = string }
variable "gpu_pool_max_nodes" {
  type    = number
  default = 2
}
variable "owner_label" { type = string }
variable "ttl_label" { type = string }
variable "env_label" { type = string }
