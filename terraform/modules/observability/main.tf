# Enable Google Cloud Managed Service for Prometheus on Cluster
# Observability module for GKE Prometheus and BigQuery Audit Log streaming
# Note: GMP Managed collectors scrape and write metrics using node-level service accounts.


# Automatically deploy and manage the GLM-5.2 Observability Dashboard
resource "google_monitoring_dashboard" "glm52_production_dashboard" {
  project        = var.project_id
  dashboard_json = jsonencode(yamldecode(file("${path.module}/dashboards/glm52_monitoring_dashboard.yaml")))
}
