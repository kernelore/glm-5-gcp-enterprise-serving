#!/usr/bin/env bash
# ==============================================================================
# 03_deploy_workloads.sh - Render & Apply Kubernetes Workload Manifests
# ==============================================================================
# Renders templates from manifests/templates/ using active environment variables,
# applies local NVMe RAID daemonsets, RBAC/WIF, weights download jobs, and the
# high-throughput vLLM serving engine (Blackwell B200 Spot pool).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${PROJECT_ROOT}/terraform"
TEMPLATE_DIR="${TF_DIR}/manifests/templates"
GENERATED_DIR="${TF_DIR}/manifests/generated"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR: ${CONFIG_FILE} not found. Please run ./scripts/01_setup_and_check.sh first."
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

export MODEL_REPO_ID="${MODEL_REPO_ID:-nvidia/GLM-5.2-NVFP4}"
if [ -n "${GCS_WEIGHTS_BUCKET:-}" ] && [[ "${GCS_WEIGHTS_BUCKET}" != gs://* ]]; then
  export GCS_WEIGHTS_BUCKET="gs://${GCS_WEIGHTS_BUCKET}"
fi

# shellcheck disable=SC2016
safe_envsubst() {
  python3 -c '
import os, sys, re
allowed = set()
for arg in sys.argv[1:]:
    for var in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", arg):
        allowed.add(var)

content = sys.stdin.read()
def replace_var(match):
    var_name = match.group(1) or match.group(2)
    if not allowed or var_name in allowed:
        return os.environ.get(var_name, "")
    return match.group(0)

output = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", replace_var, content)
sys.stdout.write(output)
' "$@"
}

echo "=============================================================================="
echo "GLM-5.2 Sovereign Enterprise Inference - Phase 3: Workload Deployment"
echo "=============================================================================="
echo "Target Cluster: ${CLUSTER_NAME} (${ZONE})"
echo "=============================================================================="

# Ensure generated directory exists and is clean
mkdir -p "${GENERATED_DIR}"
rm -f "${GENERATED_DIR}"/*.yaml

# Prepare base64 encoded token for Kubernetes secret template
HF_TOKEN_BASE64=$(echo -n "${HF_TOKEN:-placeholder_token}" | base64 -w 0 2>/dev/null || echo -n "${HF_TOKEN:-placeholder_token}" | base64)
export HF_TOKEN_BASE64
export GATEWAY_MASTER_KEY="${GATEWAY_MASTER_KEY:-sk-glm52-master-secret-key-change-me}"
export DB_PASSWORD="${DB_PASSWORD:-glm52-gateway-admin-secret}"
export GPU_MAX_NODES="${GPU_MAX_NODES:-2}"

get_tf_output() {
  local val
  val=$( (cd "${TF_DIR}" && terraform output -raw "$1" 2>/dev/null) || true)
  if [ -n "${val}" ] && [[ "${val}" != *"╷"* ]] && [[ "${val}" != *"Warning:"* ]] && [[ "${val}" != *"Error:"* ]]; then
    echo "${val}"
  fi
}

get_gcloud_val() {
  if command -v gcloud >/dev/null 2>&1; then
    local val
    val=$(gcloud "$@" 2>/dev/null || true)
    if [ -n "${val}" ] && [[ "${val}" != *"ERROR:"* ]] && [[ "${val}" != *"WARNING:"* ]]; then
      echo "${val}" | head -n 1
    fi
  fi
}

REDIS_PASSWORD=$(get_tf_output redis_auth_string)
if [ -z "${REDIS_PASSWORD}" ]; then
  REDIS_PASSWORD=$(get_gcloud_val redis instances get-auth-string glm52-gateway-cache --region="${REGION}" --format="value(authString)" --quiet)
fi
REDIS_PASSWORD="${REDIS_PASSWORD:-redis-secret-password-change-me}"
export REDIS_PASSWORD

REDIS_PASSWORD_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote_plus(sys.argv[1]))" "${REDIS_PASSWORD}")
export REDIS_PASSWORD_ENCODED

# Extract Redis and Cloud SQL details from Terraform (or gcloud fallback)
REDIS_HOST=$(get_tf_output redis_host)
if [ -z "${REDIS_HOST}" ]; then
  REDIS_HOST=$(get_gcloud_val redis instances describe glm52-gateway-cache --region="${REGION}" --format="value(host)" --quiet)
fi
REDIS_HOST="${REDIS_HOST:-redis-cache.local}"
export REDIS_HOST

DB_CONNECTION_NAME=$(get_tf_output db_instance_connection_name)
if [ -z "${DB_CONNECTION_NAME}" ]; then
  DB_CONNECTION_NAME=$(get_gcloud_val sql instances describe glm52-gateway-db --format="value(connectionName)" --quiet)
fi
DB_CONNECTION_NAME="${DB_CONNECTION_NAME:-${PROJECT_ID}:${REGION}:glm52-gateway-db}"
export DB_CONNECTION_NAME

export VLLM_VIP="glm52-serving-svc.llm-serving.svc.cluster.local"

# 1. Render manifest templates (excluding HF_TOKEN from substitution to prevent plaintext baking)
echo "--> 1. Rendering manifest templates from ${TEMPLATE_DIR} to ${GENERATED_DIR}..."
for template_file in "${TEMPLATE_DIR}"/*.yaml.template; do
  if [ -f "${template_file}" ]; then
    basename=$(basename "${template_file}" .template)
    target_file="${GENERATED_DIR}/${basename}"
    echo "    Rendering ${basename}..."
    # shellcheck disable=SC2016
    safe_envsubst '${PROJECT_ID} ${REGION} ${ZONE} ${CLUSTER_NAME} ${OWNER_LABEL} ${TTL_LABEL} ${ENV_LABEL} ${HF_TOKEN_BASE64} ${MODEL_REPO_ID} ${GCS_WEIGHTS_BUCKET} ${GATEWAY_MASTER_KEY} ${DB_CONNECTION_NAME} ${DB_PASSWORD} ${REDIS_HOST} ${REDIS_PASSWORD} ${REDIS_PASSWORD_ENCODED} ${VLLM_VIP} ${GPU_MAX_NODES}' < "${template_file}" > "${target_file}"
  fi
done
echo "    [OK] All manifest templates rendered cleanly."

if [ "${1:-}" = "--render-only" ]; then
  echo "    Render-only mode complete."
  exit 0
fi

# 2. Check and self-heal container image in Artifact Registry (seeding via Cloud Build from docker/Dockerfile if missing)
echo "--> 2. Verifying vLLM container image (${REGION}-docker.pkg.dev/${PROJECT_ID}/glm-prod/vllm-blackwell:v0.25.1) in Artifact Registry..."
if command -v gcloud >/dev/null 2>&1; then
  if ! gcloud artifacts docker tags list "${REGION}-docker.pkg.dev/${PROJECT_ID}/glm-prod/vllm-blackwell" --format="value(tag)" --quiet 2>/dev/null | grep -E -q "^v0\.25\.1$"; then
    echo "    [INFO] Container image vllm-blackwell:v0.25.1 not found in ${REGION}-docker.pkg.dev/${PROJECT_ID}/glm-prod."
    echo "    --> Triggering container build via Google Cloud Build from docker/Dockerfile..."
    gcloud services enable cloudbuild.googleapis.com --project="${PROJECT_ID}" --quiet 2>/dev/null || true
    gcloud builds submit "${PROJECT_ROOT}/docker" --tag "${REGION}-docker.pkg.dev/${PROJECT_ID}/glm-prod/vllm-blackwell:v0.25.1" --project="${PROJECT_ID}" --quiet || true
    echo "    [OK] Container build step finished."
  else
    echo "    [OK] Container image vllm-blackwell:v0.25.1 verified in Artifact Registry."
  fi
fi

# 3. Apply base cluster resources (NVMe RAID formatter & RBAC/WIF/Secret)
echo "--> 3. Applying Base Infrastructure DaemonSet & Workload Identity RBAC..."
kubectl apply -f "${GENERATED_DIR}/00-local-nvme-raid.yaml"
kubectl apply -f "${GENERATED_DIR}/01-rbac-wif.yaml"

echo "--> 4. Waiting for local-nvme-raid-formatter DaemonSet rollout..."
kubectl rollout status daemonset/local-nvme-raid-formatter -n kube-system --timeout=180s || echo "WARNING: DaemonSet rollout timeout (may be waiting for spot nodes to register)."

# 4. Apply weights download/hydration job (if staging disk is empty or initial setup)
SERVING_ACTIVE=$(kubectl get deployment glm52-nvfp4-serving -n llm-serving -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${SKIP_WEIGHT_JOB:-false}" != "true" ] && [ "${SKIP_WEIGHT_JOB:-false}" != "1" ] && [ "${SERVING_ACTIVE}" != "1" ]; then
  CURRENT_ACCESS_MODE=""
  if command -v gcloud >/dev/null 2>&1; then
    CURRENT_ACCESS_MODE=$(gcloud compute disks describe glm-52-weights-rox --zone="${ZONE}" --project="${PROJECT_ID}" --format='value(accessMode)' --quiet 2>/dev/null | head -n 1 || true)
  fi

  if [ "${CURRENT_ACCESS_MODE}" = "READ_ONLY_MANY" ]; then
    if [ "${FORCE_WEIGHT_JOB:-false}" = "true" ] || [ "${FORCE_WEIGHT_JOB:-false}" = "1" ]; then
      echo "--> Disk glm-52-weights-rox is in READ_ONLY_MANY mode and staging is forced."
      echo "--> Tearing down serving deployment and volume claims before disk deletion..."
      kubectl delete deployment glm52-nvfp4-serving -n llm-serving --ignore-not-found=true
      kubectl delete pvc pvc-glm52-weights-rox -n llm-serving --ignore-not-found=true
      kubectl delete pv pv-glm52-weights-rox --ignore-not-found=true
      kubectl delete job glm52-weight-staging-job -n llm-serving --ignore-not-found=true
      kubectl delete pvc pvc-glm52-weights-staging -n llm-serving --ignore-not-found=true
      kubectl delete pv pv-glm52-weights-staging --ignore-not-found=true

      echo "--> Deleting and recreating disk in READ_WRITE mode..."
      if ! gcloud compute disks delete glm-52-weights-rox --zone="${ZONE}" --project="${PROJECT_ID}" --quiet; then
        echo "ERROR: Failed to delete disk glm-52-weights-rox. Ensure no workloads or PVs are holding an attachment."
        exit 1
      fi
      (cd "${TF_DIR}" && terraform apply -target=module.storage -auto-approve)
    else
      echo "--> Disk glm-52-weights-rox is already in READ_ONLY_MANY mode with staged weights. Skipping staging job."
      SKIP_STAGING_EXEC="true"
    fi
  fi

  if [ "${SKIP_STAGING_EXEC:-false}" != "true" ]; then
    echo "--> 5. Preparing clean weight staging environment (removing any existing staging/serving claims)..."
    kubectl delete deployment glm52-nvfp4-serving -n llm-serving --ignore-not-found=true
    kubectl delete pvc pvc-glm52-weights-rox -n llm-serving --ignore-not-found=true
    kubectl delete pv pv-glm52-weights-rox --ignore-not-found=true
    kubectl delete job glm52-weight-staging-job -n llm-serving --ignore-not-found=true
    kubectl delete pvc pvc-glm52-weights-staging -n llm-serving --ignore-not-found=true
    kubectl delete pv pv-glm52-weights-staging --ignore-not-found=true

    echo "--> Applying staging PV and PVC (ReadWriteOnce)..."
    kubectl apply -f "${GENERATED_DIR}/02-staging-pvc.yaml"

    if [ -n "${GCS_WEIGHTS_BUCKET:-}" ] && [ "${GCS_WEIGHTS_BUCKET}" != "" ] && [ "${POPULATE_WEIGHTS_CACHE:-false}" != "true" ] && [ -f "${GENERATED_DIR}/02-hydrate-weights-gcs.yaml" ]; then
      echo "--> 5b. Hydrating GLM-5.2 NVFP4 weights directly from GCS (${GCS_WEIGHTS_BUCKET})..."
      echo "    NOTE: High-throughput transfer from GCS runs at multi-GiB/s (~2 minutes total)."
      kubectl apply -f "${GENERATED_DIR}/02-hydrate-weights-gcs.yaml"
      echo "    You can check job logs using: kubectl logs -n llm-serving -l app=glm52-weight-staging -f"
    else
      echo "--> 5b. Applying GLM-5.2 weight staging job from Hugging Face (${GENERATED_DIR}/02-download-weights.yaml)..."
      kubectl apply -f "${GENERATED_DIR}/02-download-weights.yaml"
      echo "    NOTE: Hugging Face download takes ~10 min via HF Xet (~1 GB/s)."
      echo "    You can check job logs using: kubectl logs -n llm-serving -l app=glm52-weight-staging -f"
    fi
    echo "--> Waiting for weight staging job to complete (timeout: 7200s)..."
    STAGING_START=$(date +%s)
    STAGING_TIMEOUT=7200
    while true; do
      COMPLETE=$(kubectl get job glm52-weight-staging-job -n llm-serving -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
      FAILED=$(kubectl get job glm52-weight-staging-job -n llm-serving -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)
      NOW=$(date +%s)
      ELAPSED=$((NOW - STAGING_START))
      if [ "${COMPLETE}" = "True" ]; then
        echo "    [OK] Weight staging job completed successfully in ${ELAPSED}s."
        if [ "${POPULATE_WEIGHTS_CACHE:-false}" = "true" ] && [ -n "${GCS_WEIGHTS_BUCKET:-}" ]; then
          echo "--> POPULATE_WEIGHTS_CACHE=true: Seeding persistent GCS cache bucket (${GCS_WEIGHTS_BUCKET})..."
          BUCKET_ROOT="$(printf '%s' "${GCS_WEIGHTS_BUCKET}" | sed -E 's#(gs://[^/]+).*#\1#')"
          gcloud storage buckets create "${BUCKET_ROOT}" --project="${PROJECT_ID}" --location="${REGION}" --quiet 2>/dev/null || true
          kubectl run glm52-cache-seeder --namespace=llm-serving --restart=Never --image=google/cloud-sdk:slim --overrides='{"spec":{"serviceAccountName":"glm52-workload-sa","containers":[{"name":"seeder","image":"google/cloud-sdk:slim","command":["gcloud","storage","rsync","-r","/weights","'"${GCS_WEIGHTS_BUCKET}"'"],"volumeMounts":[{"name":"w","mountPath":"/weights"}]}],"volumes":[{"name":"w","persistentVolumeClaim":{"claimName":"pvc-glm52-weights-staging"}}]}}' || true
          kubectl wait --for=condition=Ready pod/glm52-cache-seeder -n llm-serving --timeout=300s || true
          kubectl logs pod/glm52-cache-seeder -n llm-serving -f || true
          kubectl delete pod glm52-cache-seeder -n llm-serving --ignore-not-found=true
        fi
        echo "--> Releasing READ_WRITE volume lock by removing completed staging job, PVC, and PV..."
        kubectl delete job glm52-weight-staging-job -n llm-serving --ignore-not-found=true
        kubectl delete pvc pvc-glm52-weights-staging -n llm-serving --ignore-not-found=true
        kubectl delete pv pv-glm52-weights-staging --ignore-not-found=true
        break
      elif [ "${FAILED}" = "True" ]; then
        echo "ERROR: Weight staging job failed! Fetching recent job logs:"
        kubectl logs -n llm-serving -l app=glm52-weight-staging --tail=50 || true
        exit 1
      elif [ "${ELAPSED}" -gt "${STAGING_TIMEOUT}" ]; then
        echo "ERROR: Weight staging job timed out after ${STAGING_TIMEOUT}s."
        kubectl logs -n llm-serving -l app=glm52-weight-staging --tail=50 || true
        exit 1
      fi
      sleep 10
    done

    # Note: Setting Hyperdisk ML access mode to READ_ONLY_MANY is required for multi-node ReadOnlyMany PV attachment.
    # IMPORTANT: Hyperdisk ML becomes PERMANENTLY read-only after this flip. Updating weights in the future requires
    # recreating the disk (e.g., terraform taint module.storage.google_compute_disk.staging_disk or delete/re-apply, then re-running staging).
    if command -v gcloud >/dev/null 2>&1; then
      CURRENT_ACCESS_MODE=$(gcloud compute disks describe glm-52-weights-rox --zone="${ZONE}" --project="${PROJECT_ID}" --format='value(accessMode)' --quiet 2>/dev/null | head -n 1 || true)
      if [ "${CURRENT_ACCESS_MODE}" != "READ_ONLY_MANY" ]; then
        echo "--> Setting weights disk access mode to READ_ONLY_MANY for multi-attach..."
        gcloud compute disks update glm-52-weights-rox \
          --access-mode=READ_ONLY_MANY --zone="${ZONE}" --project="${PROJECT_ID}" --quiet || true
        CURRENT_ACCESS_MODE=$(gcloud compute disks describe glm-52-weights-rox --zone="${ZONE}" --project="${PROJECT_ID}" --format='value(accessMode)' --quiet 2>/dev/null | head -n 1 || true)
        if [ "${CURRENT_ACCESS_MODE}" != "READ_ONLY_MANY" ]; then
          echo "WARNING: Hyperdisk ML glm-52-weights-rox access mode is '${CURRENT_ACCESS_MODE}', not READ_ONLY_MANY. Multi-node attach (replicas > 1) will fail until flipped manually via gcloud."
        fi
      fi
    fi
  fi
else
  echo "--> 5. Skipping weight staging job as SKIP_WEIGHT_JOB=${SKIP_WEIGHT_JOB} or serving is already active."
fi

# 5. Apply vLLM Blackwell serving engine deployment
echo "--> 6. Applying vLLM Blackwell serving engine deployment (${GENERATED_DIR}/03-vllm-spot-serving.yaml)..."
kubectl apply -f "${GENERATED_DIR}/03-vllm-spot-serving.yaml"

# 6. Deploy Enterprise AI Gateway & Proxy Layer
echo "--> 7. Applying Enterprise AI Gateway ConfigMap, Secret, and Deployment..."
kubectl apply -f "${GENERATED_DIR}/04-enterprise-gateway-config.yaml"
kubectl apply -f "${GENERATED_DIR}/05-enterprise-gateway-deployment.yaml"
if [ -f "${GENERATED_DIR}/06-model-observability-podmonitoring.yaml" ]; then
  echo "    Applying GKE AI/ML Model Observability PodMonitoring resource..."
  kubectl apply -f "${GENERATED_DIR}/06-model-observability-podmonitoring.yaml" 2>/dev/null || true
fi

# 7. Optional HPA & Custom Metrics Stackdriver Adapter
if [ "${ENABLE_HPA:-false}" = "true" ] || [ "${ENABLE_HPA:-false}" = "1" ]; then
  echo "--> 8. Enabling Horizontal Pod Autoscaler (HPA) and Custom Metrics Stackdriver Adapter..."
  kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/v0.14.3/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml
  if command -v gcloud >/dev/null 2>&1; then
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${PROJECT_ID}.svc.id.goog[custom-metrics/custom-metrics-stackdriver-adapter]" \
      --role="roles/monitoring.viewer" --quiet 2>/dev/null || true
  fi
  if [ -f "${GENERATED_DIR}/07-hpa.yaml" ]; then
    echo "    Applying HPA resource (${GENERATED_DIR}/07-hpa.yaml)..."
    kubectl apply -f "${GENERATED_DIR}/07-hpa.yaml"
  fi
else
  echo "--> 8. HPA disabled (ENABLE_HPA=${ENABLE_HPA:-false}). Relying on manual scaling and scheduled CronJobs."
fi

echo "=============================================================================="
echo "SUCCESS: Workload manifests rendered and applied successfully to GKE!"
echo "To verify cluster status and serving health, run: ./scripts/04_verify_cluster.sh"
echo "=============================================================================="
