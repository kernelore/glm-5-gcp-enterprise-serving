terraform {
  required_version = ">= 1.5.0"

  backend "gcs" {
    prefix = "terraform/state/glm52-nvfp4"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "network" {
  source      = "./modules/network"
  project_id  = var.project_id
  region      = var.region
  zone        = var.zone
  owner_label = var.owner_label
  ttl_label   = var.ttl_label
  env_label   = var.env_label
}

module "cluster" {
  source                  = "./modules/cluster"
  project_id              = var.project_id
  region                  = var.region
  zone                    = var.zone
  cluster_name            = var.cluster_name
  network_name            = module.network.network_name
  subnet_name             = module.network.primary_subnet_name
  enable_private_endpoint = var.enable_private_endpoint
  master_authorized_cidrs = var.master_authorized_cidrs
  owner_label             = var.owner_label
  ttl_label               = var.ttl_label
  env_label               = var.env_label
}

module "storage" {
  source      = "./modules/storage"
  project_id  = var.project_id
  region      = var.region
  zone        = var.zone
  owner_label = var.owner_label
  ttl_label   = var.ttl_label
  env_label   = var.env_label
}

module "node_pool_spot" {
  source             = "./modules/node_pool_spot"
  project_id         = var.project_id
  region             = var.region
  zone               = var.zone
  cluster_name       = module.cluster.cluster_name
  gpu_machine_type   = var.gpu_machine_type
  gpu_pool_max_nodes = var.gpu_pool_max_nodes
  owner_label        = var.owner_label
  ttl_label          = var.ttl_label
  env_label          = var.env_label
  depends_on         = [module.cluster]
}

module "observability" {
  source       = "./modules/observability"
  project_id   = var.project_id
  region       = var.region
  cluster_name = module.cluster.cluster_name
  owner_label  = var.owner_label
  ttl_label    = var.ttl_label
  env_label    = var.env_label
}

module "database" {
  source      = "./modules/database"
  project_id  = var.project_id
  region      = var.region
  network_id  = module.network.network_id
  db_tier     = var.db_tier
  db_password = var.db_password
  owner_label = var.owner_label
  ttl_label   = var.ttl_label
  env_label   = var.env_label
  depends_on  = [module.network]
}

module "cache" {
  source      = "./modules/cache"
  project_id  = var.project_id
  region      = var.region
  network_id  = module.network.network_id
  owner_label = var.owner_label
  ttl_label   = var.ttl_label
  env_label   = var.env_label
  depends_on  = [module.network]
}

module "audit" {
  source      = "./modules/audit"
  project_id  = var.project_id
  region      = var.region
  owner_label = var.owner_label
  ttl_label   = var.ttl_label
  env_label   = var.env_label
}

module "gateway_iam" {
  source      = "./modules/gateway_iam"
  project_id  = var.project_id
  dataset_id  = module.audit.dataset_id
  owner_label = var.owner_label
  ttl_label   = var.ttl_label
  env_label   = var.env_label
}
