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
variable "vpc_name" {
  type    = string
  default = "roce-net"
}
variable "subnet_name" {
  type    = string
  default = "k8s-pod-net"
}
variable "enable_roce_multinic" {
  type        = bool
  default     = false
  description = "Optional flag to attach 8 secondary Multi-NIC RoCE network interfaces to node pool"
}
