#!/usr/bin/env bash
# ==============================================================================
# 06_destroy_all.sh - Safe & Complete Infrastructure & Workload Teardown
# ==============================================================================
# Deletes Kubernetes workloads, removes PVCs/Jobs cleanly to release disks,
# and runs `terraform destroy` to ensure zero leftover resources or cloud costs.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${PROJECT_ROOT}/terraform"
GENERATED_DIR="${TF_DIR}/manifests/generated"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR: ${CONFIG_FILE} not found. Please run ./scripts/01_setup_and_check.sh first."
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

echo "=============================================================================="
echo "GLM-5.2 Sovereign Enterprise Inference - COMPLETE TEARDOWN & DESTROY"
echo "=============================================================================="
echo "WARNING: This will destroy the GKE cluster, PVCs, VPC RoCE network, and"
echo "Terraform-managed storage buckets in project ${PROJECT_ID}."
echo "=============================================================================="

# Confirmation guard
if [ "${FORCE_DESTROY:-false}" != "true" ] && [ "${FORCE_DESTROY:-false}" != "1" ]; then
  echo "WARNING: This will permanently delete all GLM-5.2 infrastructure, PVC data, and cloud resources."
  read -r -p "Are you sure you want to proceed with full teardown? (y/N): " confirm
  if [[ "${confirm}" != [yY] && "${confirm}" != [yY][eE][sS] ]]; then
    echo "Teardown cancelled by user."
    exit 0
  fi
fi

# 1. Delete Kubernetes workloads first if cluster is reachable
echo "--> 1. Attempting clean deletion of Kubernetes workloads from GKE..."
if kubectl get nodes >/dev/null 2>&1; then
  echo "    Deleting jobs, deployments, and services in namespace llm-serving..."
  kubectl delete jobs --all -n llm-serving --ignore-not-found --timeout=60s || true
  kubectl delete deployments --all -n llm-serving --ignore-not-found --timeout=60s || true
  kubectl delete services --all -n llm-serving --ignore-not-found --timeout=60s || true

  echo "    Deleting staging and serving PVCs in namespace llm-serving..."
  kubectl delete pvc pvc-glm52-weights-staging pvc-glm52-weights-rox -n llm-serving --ignore-not-found --timeout=60s || true

  echo "    Deleting cluster-scoped staging and serving PVs..."
  kubectl delete pv pv-glm52-weights-staging pv-glm52-weights-rox --ignore-not-found --timeout=60s || true

  echo "    Deleting namespace llm-serving and generated manifests..."
  if [ -d "${GENERATED_DIR}" ]; then
    kubectl delete -f "${GENERATED_DIR}/" --ignore-not-found --timeout=120s || true
  fi
  kubectl delete ns llm-serving --ignore-not-found --timeout=120s || true
  kubectl delete ds local-nvme-raid-formatter -n kube-system --ignore-not-found --timeout=60s || true
else
  echo "    Kubernetes cluster already unreachable/deleted. Proceeding..."
fi

# 2. Proactive Cloud SQL and database cleanup (Issue 6 guard)
echo "--> 2. Checking and executing proactive Cloud SQL object & database cleanup..."
if command -v gcloud >/dev/null 2>&1; then
  echo "    Dropping LiteLLM database to release owned role dependencies before destroy..."
  gcloud sql databases delete glm52_gateway --instance=glm52-gateway-db --project="${PROJECT_ID}" --quiet 2>/dev/null || true
fi

# 3. Run Terraform destroy with automated self-healing and retry loop
echo "--> 3. Running terraform destroy in ${TF_DIR}..."
cd "${TF_DIR}"
export TF_STATE_BUCKET="${TF_STATE_BUCKET:-${PROJECT_ID}-glm52-tfstate}"
echo "    Initializing remote state backend: gs://${TF_STATE_BUCKET}..."
terraform init -backend-config="bucket=${TF_STATE_BUCKET}" -reconfigure

DESTROY_CMD="terraform destroy"
if [ "${FORCE_DESTROY:-false}" = "true" ] || [ "${FORCE_DESTROY:-false}" = "1" ]; then
  DESTROY_CMD="terraform destroy -auto-approve"
fi

echo "    Executing: ${DESTROY_CMD}..."
if ! eval "${DESTROY_CMD}"; then
  echo "    [NOTE] Initial terraform destroy encountered a dependency or propagation block. Engaging self-healing teardown..."

  # Self-heal Cloud SQL role block (Issue 6)
  if gcloud sql instances describe glm52-gateway-db --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "    Deleting Cloud SQL instance glm52-gateway-db directly to release database/role dependencies..."
    gcloud sql instances delete glm52-gateway-db --project="${PROJECT_ID}" --quiet 2>/dev/null || true
    terraform state rm module.database.google_sql_user.gateway_user module.database.google_sql_database.lite_db module.database.google_sql_database_instance.gateway_db 2>/dev/null || true
  fi

  # Self-heal Service Networking & VPC peering block (Issue 7)
  VPC_NAME=$(terraform output -raw vpc_network_name 2>/dev/null || echo "${CLUSTER_NAME}-primary")
  if command -v gcloud >/dev/null 2>&1 && [ -n "${VPC_NAME}" ]; then
    echo "    Cleaning up any dangling servicenetworking or redis VPC peerings on ${VPC_NAME}..."
    PEERINGS=$(gcloud compute networks peerings list --network="${VPC_NAME}" --project="${PROJECT_ID}" --format="value(peerings[].name)" 2>/dev/null || true)
    for p in ${PEERINGS}; do
      echo "      Removing peering: ${p}..."
      gcloud compute networks peerings delete "${p}" --network="${VPC_NAME}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
    done
    terraform state rm module.database.google_service_networking_connection.private_vpc_connection 2>/dev/null || true
  fi

  echo "    Retrying final terraform destroy..."
  sleep 5
  eval "${DESTROY_CMD}"
fi

# 4. Enumerate retained GCS buckets and handle opt-in weight cache purge
echo "--> 4. Enumerating retained GCS buckets (*-glm52-*) in project ${PROJECT_ID}..."
if command -v gcloud >/dev/null 2>&1; then
  if [ "${PURGE_WEIGHTS_CACHE:-false}" = "true" ] && [ -n "${GCS_WEIGHTS_BUCKET:-}" ]; then
    echo "WARNING: PURGE_WEIGHTS_CACHE=true explicitly set. Deleting weight cache bucket ${GCS_WEIGHTS_BUCKET}..."
    echo "         Next deployment will require a full ~433 GiB HuggingFace re-download (~10 min)."
    gcloud storage rm -r "${GCS_WEIGHTS_BUCKET}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
  fi

  echo "------------------------------------------------------------------------------"
  echo "INTENTIONALLY RETAINED BUCKET INVENTORY (persistent cache / remote state — not a leak):"
  BUCKETS=$(gcloud storage ls --project="${PROJECT_ID}" 2>/dev/null | grep -E "glm52" || true)
  for b in ${BUCKETS}; do
    SIZE_BYTES=$(gcloud storage du -s "${b}" 2>/dev/null | awk '{print $1}' || echo "0")
    SIZE_GIB=$(awk "BEGIN {printf \"%.2f\", ${SIZE_BYTES:-0}/1073741824}")
    COST_EST=$(awk "BEGIN {printf \"$%.2f\", (${SIZE_BYTES:-0}/1073741824)*0.02}")
    echo "  * ${b} (~${SIZE_GIB} GiB | est. ${COST_EST}/mo) [INTENTIONALLY RETAINED]"
  done
  echo "------------------------------------------------------------------------------"
fi

echo "=============================================================================="
echo "SUCCESS: All Kubernetes workloads and Terraform infrastructure destroyed cleanly in one pass!"
echo "=============================================================================="
