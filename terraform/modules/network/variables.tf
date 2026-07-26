variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }
variable "owner_label" { type = string }
variable "ttl_label" { type = string }
variable "env_label" { type = string }
variable "vpc_name" {
  type    = string
  default = "glm52-net"
}

variable "subnet_name" {
  type    = string
  default = "k8s-pod-net"
}

variable "subnet_cidr" {
  type    = string
  default = "10.10.0.0/16"
}



