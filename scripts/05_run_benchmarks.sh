#!/usr/bin/env bash
# ==============================================================================
# 05_run_benchmarks.sh - Execute GLM-5.2 Sovereign Enterprise Inference Benchmarks
# ==============================================================================
# Executes standard and/or massive concurrency performance benchmarks against the
# Enterprise AI Gateway (port 4000) or directly against the vLLM serving engine (port 8000).
# Automatically establishes a secure kubectl port-forward if running externally outside
# the private RoCE VPC network.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
TF_DIR="${PROJECT_ROOT}/terraform"
TEMPLATE_DIR="${TF_DIR}/manifests/templates"
GENERATED_DIR="${TF_DIR}/manifests/generated"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR: ${CONFIG_FILE} not found. Please run ./scripts/01_setup_and_check.sh first."
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

MODE="all"
TARGET="gateway"
CONCURRENCY=""
REQUESTS=""
IN_CLUSTER="false"

show_usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Execute GLM-5.2 performance benchmarks against the GKE serving stack.

Options:
  --mode <standard|massive|soak|all>  Benchmark suite to run (default: all)
                                   - standard: 8 concurrent requests, 128 tokens
                                   - massive:  20 concurrent requests, 256 tokens (stress test)
                                   - soak:     30-minute continuous stability endurance test
                                   - all:      Run standard, massive, and soak suites sequentially
  --target <gateway|serving>     Target endpoint for benchmarking (default: gateway)
                                   - gateway: LiteLLM Enterprise Proxy (port 4000) with virtual keys & Redis auth
                                   - serving: Direct vLLM Engine backend (port 8000) bypassing gateway
  --in-cluster                   Run benchmark as an in-cluster Kubernetes Job (Recommended for sustained/soak loads)
  --concurrency <N>              Override concurrency level (optional)
  --requests <N>                 Override total requests count (optional)
  -h, --help                     Show this usage guide and exit

Examples:
  ./scripts/05_run_benchmarks.sh --mode standard --target gateway
  ./scripts/05_run_benchmarks.sh --mode soak --in-cluster
  ./scripts/05_run_benchmarks.sh --mode massive --target serving --concurrency 16 --requests 64
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    --in-cluster)
      IN_CLUSTER="true"
      shift 1
      ;;
    --concurrency)
      CONCURRENCY="$2"
      shift 2
      ;;
    --requests)
      REQUESTS="$2"
      shift 2
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      show_usage
      exit 1
      ;;
  esac
done

echo "=============================================================================="
echo "GLM-5.2 Sovereign Enterprise Inference - Benchmark Execution Suite"
echo "=============================================================================="
echo "Cluster:        ${CLUSTER_NAME} (${ZONE})"
echo "Mode:           ${MODE}"
echo "Target Layer:   ${TARGET}"
echo "=============================================================================="

# 1. Verify prerequisites
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to run the benchmark scripts."
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl is required to verify cluster endpoints."
  exit 1
fi

# 2. Determine target service details
if [ "${TARGET}" = "gateway" ]; then
  SERVICE_NAME="glm52-gateway-svc"
  REMOTE_PORT="4000"
  LOCAL_PORT="4000"
  ENDPOINT_PATH="/v1/chat/completions"
  DEV_KEY="${GATEWAY_MASTER_KEY:-sk-glm52-master-secret-key-change-me}"
else
  SERVICE_NAME="glm52-serving-svc"
  REMOTE_PORT="8000"
  LOCAL_PORT="8000"
  ENDPOINT_PATH="/v1/completions"
  DEV_KEY="EMPTY"
fi

echo "--> 1. Resolving service VIP and connectivity for ${SERVICE_NAME} (port ${REMOTE_PORT})..."
VIP=$(kubectl get svc "${SERVICE_NAME}" -n llm-serving -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

PF_PID=""
cleanup_port_forward() {
  if [ -n "${PF_PID}" ] && kill -0 "${PF_PID}" 2>/dev/null; then
    echo "    Cleaning up background kubectl port-forward (PID: ${PF_PID})..."
    kill "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup_port_forward EXIT

if [ -n "${VIP}" ] && curl --connect-timeout 2 -s "http://${VIP}:${REMOTE_PORT}/health/liveliness" >/dev/null 2>&1; then
  echo "    [OK] Direct private VPC connection established to ${SERVICE_NAME} (${VIP}:${REMOTE_PORT})."
  BASE_URL="http://${VIP}:${REMOTE_PORT}"
elif [ -n "${VIP}" ] && curl --connect-timeout 2 -s "http://${VIP}:${REMOTE_PORT}/health" >/dev/null 2>&1; then
  echo "    [OK] Direct private VPC connection established to ${SERVICE_NAME} (${VIP}:${REMOTE_PORT})."
  BASE_URL="http://${VIP}:${REMOTE_PORT}"
else
  echo "    NOTE: Direct connection to private VIP (${VIP:-Unassigned}) not reachable from local workstation."
  echo "    --> Establishing automated kubectl port-forward (${LOCAL_PORT}:${REMOTE_PORT}) across private fabric..."
  kubectl port-forward -n llm-serving "svc/${SERVICE_NAME}" "${LOCAL_PORT}:${REMOTE_PORT}" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  if ! kill -0 "${PF_PID}" 2>/dev/null; then
    echo "ERROR: Failed to establish kubectl port-forward to svc/${SERVICE_NAME}. Please verify pod health."
    exit 1
  fi
  BASE_URL="http://localhost:${LOCAL_PORT}"
  echo "    [OK] Port-forward active on ${BASE_URL} (bypassing external network restrictions)."
fi

TARGET_URL="${BASE_URL}${ENDPOINT_PATH}"
echo "    Target Benchmark Endpoint: ${TARGET_URL}"

# Check for In-Cluster execution mode
if [ "${IN_CLUSTER}" = "true" ]; then
  echo ""
  echo "------------------------------------------------------------------------------"
  echo "--> Executing In-Cluster Benchmark via Kubernetes Job & ConfigMap..."
  echo "------------------------------------------------------------------------------"
  echo "    Creating/Updating benchmark ConfigMap with local test scripts..."
  kubectl create configmap glm52-benchmark-scripts \
    --from-file="${PROJECT_ROOT}/benchmarks/benchmark_glm52.py" \
    --from-file="${PROJECT_ROOT}/benchmarks/massive_benchmark_glm52.py" \
    --from-file="${PROJECT_ROOT}/benchmarks/soak_benchmark_glm52.py" \
    -n llm-serving --dry-run=client -o yaml | kubectl apply -f -

  echo "    Rendering in-cluster benchmark Job manifest..."
  mkdir -p "${GENERATED_DIR}"
  export ENV_LABEL="${ENV_LABEL:-glm52-test}"
  export OWNER_LABEL="${OWNER_LABEL:-opensource-user}"
  export GATEWAY_MASTER_KEY="${GATEWAY_MASTER_KEY:-sk-glm52-master-secret-key-change-me}"
  envsubst < "${TEMPLATE_DIR}/08-in-cluster-benchmark-job.yaml.template" > "${GENERATED_DIR}/08-in-cluster-benchmark-job.yaml"

  echo "    Applying in-cluster benchmark Job (${GENERATED_DIR}/08-in-cluster-benchmark-job.yaml)..."
  kubectl delete job glm52-incluster-benchmark -n llm-serving --ignore-not-found=true
  kubectl apply -f "${GENERATED_DIR}/08-in-cluster-benchmark-job.yaml"

  echo "    Streaming in-cluster benchmark logs (Job: glm52-incluster-benchmark)..."
  sleep 5
  kubectl logs -n llm-serving -l app=glm52-benchmark -f --tail=100 || true
  echo "    [OK] In-cluster benchmark job execution finished."
  exit 0
fi

# 3. Execute Standard Benchmark Suite
if [ "${MODE}" = "standard" ] || [ "${MODE}" = "all" ]; then
  echo ""
  echo "------------------------------------------------------------------------------"
  echo "--> 2. Executing Standard Enterprise Benchmark Suite (concurrency=8, requests=16)..."
  echo "------------------------------------------------------------------------------"
  
  STD_ARGS=(
    "--endpoint=${TARGET_URL}"
    "--output=${PROJECT_ROOT}/benchmarks/standard_results.json"
    "--api-key=${DEV_KEY}"
  )
  if [ -n "${CONCURRENCY}" ]; then STD_ARGS+=("--concurrency=${CONCURRENCY}"); fi
  if [ -n "${REQUESTS}" ]; then STD_ARGS+=("--requests=${REQUESTS}"); fi
  
  python3 "${PROJECT_ROOT}/benchmarks/benchmark_glm52.py" "${STD_ARGS[@]}" || echo "WARNING: Standard benchmark reported errors or timeouts."
fi

# 4. Execute Massive Stress Benchmark Suite
if [ "${MODE}" = "massive" ] || [ "${MODE}" = "all" ]; then
  echo ""
  echo "------------------------------------------------------------------------------"
  echo "--> 3. Executing Massive Stress Benchmark Suite (concurrency=20, requests=100)..."
  echo "------------------------------------------------------------------------------"
  
  MAS_ARGS=(
    "--endpoint=${TARGET_URL}"
    "--output=${PROJECT_ROOT}/benchmarks/massive_results.json"
    "--api-key=${DEV_KEY}"
  )
  if [ -n "${CONCURRENCY}" ]; then MAS_ARGS+=("--concurrency=${CONCURRENCY}"); fi
  if [ -n "${REQUESTS}" ]; then MAS_ARGS+=("--requests=${REQUESTS}"); fi
  
  python3 "${PROJECT_ROOT}/benchmarks/massive_benchmark_glm52.py" "${MAS_ARGS[@]}" || echo "WARNING: Massive benchmark reported errors or timeouts."
fi

# 5. Execute Continuous Soak Benchmark Suite
if [ "${MODE}" = "soak" ] || [ "${MODE}" = "all" ]; then
  echo ""
  echo "------------------------------------------------------------------------------"
  echo "--> 4. Executing Continuous Soak Suite (concurrency=18, duration=1800s)..."
  echo "------------------------------------------------------------------------------"
  
  SOAK_ARGS=(
    "--endpoint=${TARGET_URL}"
    "--output=${PROJECT_ROOT}/benchmarks/soak_results.json"
    "--api-key=${DEV_KEY}"
  )
  if [ -n "${CONCURRENCY}" ]; then SOAK_ARGS+=("--concurrency=${CONCURRENCY}"); fi
  
  python3 "${PROJECT_ROOT}/benchmarks/soak_benchmark_glm52.py" "${SOAK_ARGS[@]}" || echo "WARNING: Soak benchmark reported errors or timeouts."
fi

# 6. Display Benchmark Summary
echo ""
echo "=============================================================================="
echo "Benchmark Execution Summary"
echo "=============================================================================="
if [ -f "${PROJECT_ROOT}/benchmarks/standard_results.json" ]; then
  echo "Standard Suite Results (${PROJECT_ROOT}/benchmarks/standard_results.json):"
  python3 -c "
import json
with open('${PROJECT_ROOT}/benchmarks/standard_results.json') as f:
    d = json.load(f)
succ = d.get('successful_requests') if d.get('successful_requests') is not None else d.get('execution_summary', {}).get('successful_requests', 0)
tot = d.get('total_requests') if d.get('total_requests') is not None else d.get('execution_summary', {}).get('total_requests', 0)
ttft = d.get('ttft_mean_ms') if d.get('ttft_mean_ms') is not None else d.get('metrics', {}).get('ttft_ms', {}).get('mean', 0.0)
tpot = d.get('tpot_mean_ms') if d.get('tpot_mean_ms') is not None else d.get('metrics', {}).get('tpot_ms', {}).get('mean', 0.0)
tps = d.get('throughput_tokens_sec') if d.get('throughput_tokens_sec') is not None else d.get('metrics', {}).get('cluster_throughput_tokens_per_sec', 0.0)
print(f'  - Successful Requests: {succ} / {tot}')
print(f'  - Mean TTFT:           {float(ttft):.2f} ms')
print(f'  - Mean TPOT:           {float(tpot):.2f} ms')
print(f'  - Cluster Throughput:  {float(tps):.2f} tokens/sec')
" 2>/dev/null || true
fi

if [ -f "${PROJECT_ROOT}/benchmarks/massive_results.json" ]; then
  echo "Massive Suite Results (${PROJECT_ROOT}/benchmarks/massive_results.json):"
  python3 -c "
import json
with open('${PROJECT_ROOT}/benchmarks/massive_results.json') as f:
    d = json.load(f)
succ = d.get('successful_requests') if d.get('successful_requests') is not None else d.get('execution_summary', {}).get('successful_requests', 0)
tot = d.get('total_requests') if d.get('total_requests') is not None else d.get('execution_summary', {}).get('total_requests', 0)
ttft = d.get('ttft_mean_ms') if d.get('ttft_mean_ms') is not None else d.get('metrics', {}).get('ttft_ms', {}).get('mean', 0.0)
tpot = d.get('tpot_mean_ms') if d.get('tpot_mean_ms') is not None else d.get('metrics', {}).get('tpot_ms', {}).get('mean', 0.0)
tps = d.get('throughput_tokens_sec') if d.get('throughput_tokens_sec') is not None else d.get('metrics', {}).get('cluster_throughput_tokens_per_sec', 0.0)
print(f'  - Successful Requests: {succ} / {tot}')
print(f'  - Mean TTFT:           {float(ttft):.2f} ms')
print(f'  - Mean TPOT:           {float(tpot):.2f} ms')
print(f'  - Cluster Throughput:  {float(tps):.2f} tokens/sec')
" 2>/dev/null || true
fi

if [ -f "${PROJECT_ROOT}/benchmarks/soak_results.json" ]; then
  echo "Soak Suite Results (${PROJECT_ROOT}/benchmarks/soak_results.json):"
  python3 -c "
import json
with open('${PROJECT_ROOT}/benchmarks/soak_results.json') as f:
    d = json.load(f)
completed = d.get('total_completed') if d.get('total_completed') is not None else d.get('successful_requests', d.get('execution_summary', {}).get('total_requests_completed', 0))
ttft = d.get('ttft_mean_ms') if d.get('ttft_mean_ms') is not None else d.get('metrics', {}).get('ttft_ms', {}).get('mean', 0.0)
tpot = d.get('tpot_mean_ms') if d.get('tpot_mean_ms') is not None else d.get('metrics', {}).get('tpot_ms', {}).get('mean', 0.0)
tps = d.get('throughput_tokens_sec') if d.get('throughput_tokens_sec') is not None else d.get('metrics', {}).get('sustained_cluster_tps', 0.0)
print(f'  - Total Completed Cycles: {completed}')
print(f'  - Mean TTFT:              {float(ttft):.2f} ms')
print(f'  - Mean TPOT:              {float(tpot):.2f} ms')
print(f'  - Sustained Throughput:   {float(tps):.2f} tokens/sec')
" 2>/dev/null || true
fi

echo "=============================================================================="
echo "To clean up all resources when finished, run:"
echo "  ./scripts/06_destroy_all.sh"
echo "=============================================================================="
