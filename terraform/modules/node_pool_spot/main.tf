resource "google_compute_resource_policy" "compact_placement" {
  name    = "pp-blackwell-nvlink-fi"
  region  = var.region
  project = var.project_id
  group_placement_policy {
    collocation = "COLLOCATED"
  }
}

resource "google_container_node_pool" "blackwell_spot_pool" {
  provider   = google-beta
  name       = "np-blackwell-spot-a4"
  location   = var.zone
  cluster    = var.cluster_name
  project    = var.project_id
  node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = var.gpu_pool_max_nodes
  }

  placement_policy {
    type        = "COMPACT"
    policy_name = google_compute_resource_policy.compact_placement.name
  }

  lifecycle {
    ignore_changes = [node_count, initial_node_count]
  }

  node_config {
    machine_type = var.gpu_machine_type
    spot         = true
    disk_size_gb = 200

    gvnic {
      enabled = true
    }

    gcfs_config {
      enabled = true
    }

    local_nvme_ssd_block_config {
      local_ssd_count = 32
    }

    guest_accelerator {
      type  = "nvidia-b200"
      count = 8
      gpu_driver_installation_config {
        gpu_driver_version = "DEFAULT"
      }
    }

    labels = {
      env   = var.env_label
      owner = var.owner_label
      ttl   = var.ttl_label
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # ==========================================================================
    # OPTIONAL: 8x Secondary Titanium RoCE Network Interfaces (Multi-NIC)
    # ==========================================================================
    # Uncomment if enable_roce_multinic is true and secondary subnets are created:
    #
    # dynamic "additional_node_network_configs" {
    #   for_each = var.enable_roce_multinic ? range(8) : []
    #   content {
    #     network    = "${var.vpc_name}-roce-net-${additional_node_network_configs.value}"
    #     subnetwork = "${var.subnet_name}-roce-sub-${additional_node_network_configs.value}"
    #   }
    # }
  }
}
