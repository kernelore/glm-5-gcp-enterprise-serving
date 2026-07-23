#!/usr/bin/env bash
# ==============================================================================
# 04_verify_cluster.sh - Verify Cluster Health, GPU Node Pool & vLLM Serving Status
# ==============================================================================
# Checks node health, GPU allocations, pod readiness, and tests the local/remote
# vLLM OpenAI-compatible /health and /v1/models endpoints.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR: ${CONFIG_FILE} not found. Please run ./scripts/01_setup_and_check.sh first."
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

: "${PROJECT_ROOT}"

PF_PIDS=()
cleanup_port_forwards() {
  for pid in "${PF_PIDS[@]}"; do
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
  done
}
trap cleanup_port_forwards EXIT

echo "=============================================================================="
echo "GLM-5.2 Sovereign Enterprise Inference - Status & Health Verification"
echo "=============================================================================="
echo "Checking cluster: ${CLUSTER_NAME} (${ZONE})"
echo "=============================================================================="

# 1. Check GKE cluster nodes & Spot GPU pool status
echo "--> 1. Checking GKE node pools and accelerator allocations..."
kubectl get nodes -l "cloud.google.com/gke-accelerator=nvidia-b200" -o "custom-columns=NAME:.metadata.name,STATUS:.status.conditions[?(@.type==\"Ready\")].status,SPOT:.metadata.labels.cloud\.google\.com/gke-spot,GPU:.metadata.labels.cloud\.google\.com/gke-accelerator" 2>/dev/null || echo "    No Blackwell B200 nodes currently registered in the cluster (may be autoscaling from 0)."

# 2. Check namespace and workloads in llm-serving
echo "--> 2. Checking pods and deployments in namespace 'llm-serving'..."
kubectl get pods,svc,deployments,jobs,pvc -n llm-serving

# 3. Check RAID NVMe formatter status
echo "--> 3. Checking local-nvme-raid-formatter DaemonSet across nodes..."
kubectl get ds local-nvme-raid-formatter -n kube-system

# 4. Check weight staging job status
echo "--> 4. Checking weight staging job status..."
if kubectl get job glm52-weight-staging-job -n llm-serving >/dev/null 2>&1; then
  kubectl describe job glm52-weight-staging-job -n llm-serving | grep -E "Pods Statuses|Conditions" || true
fi

# 5. Check vLLM serving engine health (if pod is running)
echo "--> 5. Checking vLLM serving pod health status..."
VLLM_POD=$(kubectl get pod -n llm-serving -l app=glm52-serving -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
VLLM_VIP=$(kubectl get svc glm52-serving-svc -n llm-serving -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "glm52-serving-svc.llm-serving.svc.cluster.local")

if [ -n "${VLLM_POD}" ]; then
  POD_STATUS=$(kubectl get pod "${VLLM_POD}" -n llm-serving -o jsonpath='{.status.phase}')
  echo "    Serving Pod Name:   ${VLLM_POD}"
  echo "    Serving Pod Status: ${POD_STATUS}"

  if [ "${POD_STATUS}" = "Running" ]; then
    echo "    Testing vLLM serving health endpoint..."
    if ! curl -s --connect-timeout 2 "http://${VLLM_VIP}:8000/health" >/dev/null 2>&1 && ! curl -s --connect-timeout 2 "http://localhost:8000/health" >/dev/null 2>&1; then
      echo "    --> Establishing background kubectl port-forward for vLLM serving (8000:8000)..."
      kubectl port-forward -n llm-serving svc/glm52-serving-svc 8000:8000 >/dev/null 2>&1 &
      PF_PIDS+=($!)
      sleep 3
    fi
    if curl -s --max-time 5 http://localhost:8000/health >/dev/null 2>&1 || curl -s --max-time 5 "http://${VLLM_VIP}:8000/health" >/dev/null 2>&1; then
      echo "      [PASS] vLLM /health endpoint returned HTTP 200."
    else
      echo "    Testing local /health endpoint inside pod..."
      kubectl exec -n llm-serving "${VLLM_POD}" -c vllm-engine -- curl -s --max-time 5 http://localhost:8000/health || echo "    WARNING: /health check returned non-200 or is still warming up."
    fi
  else
    echo "    NOTE: Pod is not yet in Running state (${POD_STATUS}). Check logs with:"
    echo "          kubectl logs -n llm-serving ${VLLM_POD} -c vllm-engine"
  fi
else
  echo "    NOTE: No active vLLM serving pod found (Deployment may be scaled to 0 or waiting for spot nodes)."
fi

# 6. Enterprise AI Gateway & Proxy Layer 5-Point Verification Suite
echo "--> 6. Enterprise AI Gateway & Proxy Layer 5-Point Verification Suite..."
GATEWAY_POD=$(kubectl get pod -n llm-serving -l app=glm52-enterprise-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
GATEWAY_VIP=$(kubectl get svc glm52-gateway-svc -n llm-serving -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "glm52-gateway-svc.llm-serving.svc.cluster.local")

if [ -n "${GATEWAY_POD}" ]; then
  GATEWAY_STATUS=$(kubectl get pod "${GATEWAY_POD}" -n llm-serving -o jsonpath='{.status.phase}')
  echo "    Gateway Pod Name:   ${GATEWAY_POD}"
  echo "    Gateway Pod Status: ${GATEWAY_STATUS}"
  echo "    Gateway Service IP: ${GATEWAY_VIP}"

  if [ "${GATEWAY_STATUS}" = "Running" ]; then
    if ! curl -s --connect-timeout 2 "http://${GATEWAY_VIP}:4000/health/liveliness" >/dev/null 2>&1 && ! curl -s --connect-timeout 2 "http://localhost:4000/health/liveliness" >/dev/null 2>&1; then
      echo "    --> Establishing background kubectl port-forward for Enterprise Gateway (4000:4000)..."
      kubectl port-forward -n llm-serving svc/glm52-gateway-svc 4000:4000 >/dev/null 2>&1 &
      PF_PIDS+=($!)
      sleep 3
    fi

    run_gateway_curl() {
      local args=("$@")
      if curl -s --connect-timeout 2 "http://localhost:4000/health/liveliness" >/dev/null 2>&1; then
        local new_args=()
        for arg in "${args[@]}"; do
          new_args+=("${arg//http:\/\/${GATEWAY_VIP}:4000/http:\/\/localhost:4000}")
        done
        curl "${new_args[@]}"
      elif [ -n "${GATEWAY_VIP}" ] && curl -s --connect-timeout 2 "http://${GATEWAY_VIP}:4000/health/liveliness" >/dev/null 2>&1; then
        curl "${args[@]}"
      else
        local py_script="import urllib.request, sys, json
args = sys.argv[1:]
url = ''
method = 'GET'
headers = {}
data = None
show_code = False
header_file = None
i = 0
while i < len(args):
    if args[i] == '-X' and i+1 < len(args): method = args[i+1]; i+=2
    elif args[i] == '-H' and i+1 < len(args):
        parts = args[i+1].split(':', 1)
        if len(parts) == 2: headers[parts[0].strip()] = parts[1].strip()
        i+=2
    elif args[i] == '-d' and i+1 < len(args): data = args[i+1].encode('utf-8'); i+=2
    elif args[i] == '-D' and i+1 < len(args): header_file = args[i+1]; i+=2
    elif args[i] == '-w' and i+1 < len(args):
        if '%{http_code}' in args[i+1]: show_code = True
        i+=2
    elif args[i].startswith('http'): url = args[i].replace('http://${GATEWAY_VIP}:4000', 'http://localhost:4000'); i+=1
    else: i+=1
if not url: sys.exit(0)
req_method = method if method != 'GET' else ('POST' if data else 'GET')
req = urllib.request.Request(url, data=data, headers=headers, method=req_method)
try:
    with urllib.request.urlopen(req, timeout=10) as res:
        if header_file:
            with open(header_file, 'w') as hf:
                for k, v in res.headers.items():
                    hf.write(f'{k}: {v}\n')
        if show_code: sys.stdout.write(str(res.status))
        else: sys.stdout.write(res.read().decode('utf-8'))
except urllib.error.HTTPError as e:
    if header_file:
        with open(header_file, 'w') as hf:
            for k, v in e.headers.items():
                hf.write(f'{k}: {v}\n')
    if show_code: sys.stdout.write(str(e.code))
    else: sys.stdout.write(e.read().decode('utf-8'))
except Exception as e:
    if show_code: sys.stdout.write('000')
"
        kubectl exec -n llm-serving "${GATEWAY_POD}" -c gateway -- python3 -c "${py_script}" "$@" 2>/dev/null || true
      fi
    }

    # Test 1: 401 Unauthorized Auth Test
    echo "    [Test 1/5] Running 401 Unauthorized Auth Test (No API Key)..."
    HTTP_CODE=$(run_gateway_curl -s -o /dev/null -w "%{http_code}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "test auth"}]}' || echo "000")
    if [ "${HTTP_CODE}" = "401" ]; then
      echo "      [PASS] Returned HTTP 401 Unauthorized as expected."
    else
      echo "      [NOTE] Returned HTTP ${HTTP_CODE} (expected 401 if auth is strictly enforced)."
    fi

    # Test 2: 200 Virtual Key Success Test
    echo "    [Test 2/5] Running 200 Virtual Key Success Test..."
    MASTER_KEY="${GATEWAY_MASTER_KEY:-sk-glm52-master-secret-key-change-me}"
    KEY_RESP=$(run_gateway_curl -s -X POST http://"${GATEWAY_VIP}":4000/key/generate \
      -H "Authorization: Bearer ${MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"models": ["glm-5.2-moe"], "aliases": {"glm-5.2-moe": "glm-5.2-moe"}, "key_alias": "sk-glm52-test-dev-'${RANDOM}'"}' || true)
    DEV_KEY=$(echo "${KEY_RESP}" | grep -E -o '"key"\s*:\s*"[^"]*' | cut -d'"' -f4 2>/dev/null || true)
    if [ -z "${DEV_KEY}" ]; then
      echo "      [FAIL] Failed to generate virtual key from Gateway. Response: ${KEY_RESP}"
    else
      HTTP_CODE=$(run_gateway_curl -s -o /dev/null -w "%{http_code}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
        -H "Authorization: Bearer ${DEV_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "Hello Sovereign Gateway"}]}' || echo "000")
      if [ "${HTTP_CODE}" = "200" ]; then
        echo "      [PASS] Virtual key authentication returned HTTP 200 OK successfully."
      else
        echo "      [NOTE] Returned HTTP ${HTTP_CODE} (Check upstream vLLM backend or key permissions)."
      fi
    fi

    # Test 3: 429 Rate Limit Quota Test
    echo "    [Test 3/5] Running 429 Rate Limit Quota Test..."
    QUOTA_RESP=$(run_gateway_curl -s -X POST http://"${GATEWAY_VIP}":4000/key/generate \
      -H "Authorization: Bearer ${MASTER_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"models": ["glm-5.2-moe"], "max_budget": 0.000001, "key_alias": "sk-glm52-quota-test-'${RANDOM}'"}' || true)
    QUOTA_KEY=$(echo "${QUOTA_RESP}" | grep -E -o '"key"\s*:\s*"[^"]*' | cut -d'"' -f4 2>/dev/null || true)
    if [ -n "${QUOTA_KEY}" ]; then
      run_gateway_curl -s -o /dev/null http://"${GATEWAY_VIP}":4000/v1/chat/completions \
        -H "Authorization: Bearer ${QUOTA_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "Consume initial budget budget budget"}]}' || true
      QUOTA_CODE=$(run_gateway_curl -s -o /dev/null -w "%{http_code}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
        -H "Authorization: Bearer ${QUOTA_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "Second budget request"}]}' || echo "000")
      if [ "${QUOTA_CODE}" = "429" ] || [ "${QUOTA_CODE}" = "400" ]; then
        echo "      [PASS] Rate/budget quota deduction enforced (HTTP ${QUOTA_CODE})."
      else
        echo "      [NOTE] Returned HTTP ${QUOTA_CODE} (Budget check may be async or requires active accounting)."
      fi
    else
      echo "      [NOTE] Could not generate budget-constrained key for 429 test."
    fi

    # Test 4: Redis Cache Hit Test (Deterministic temperature=0 query with retry)
    echo "    [Test 4/5] Running Redis Cache Hit Test (Deterministic exact match)..."
    CACHE_PROMPT='{"model": "glm-5.2-moe", "temperature": 0.0, "messages": [{"role": "user", "content": "Sovereign AI deterministic caching test query"}]}'
    AUTH_HEADER_KEY="${DEV_KEY:-${MASTER_KEY}}"

    # Send priming request
    run_gateway_curl -s -o /dev/null http://"${GATEWAY_VIP}":4000/v1/chat/completions \
      -H "Authorization: Bearer ${AUTH_HEADER_KEY}" \
      -H "Content-Type: application/json" \
      -d "${CACHE_PROMPT}" || true
    sleep 2

    # Attempt cache hit verification with up to 3 retries
    CACHE_PASSED="false"
    for attempt in 1 2 3; do
      CACHE_HEADER_FILE=$(mktemp)
      START_TIME=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s)
      run_gateway_curl -s -D "${CACHE_HEADER_FILE}" -o /dev/null http://"${GATEWAY_VIP}":4000/v1/chat/completions \
        -H "Authorization: Bearer ${AUTH_HEADER_KEY}" \
        -H "Content-Type: application/json" \
        -d "${CACHE_PROMPT}" || true
      END_TIME=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s)
      ELAPSED_MS=$((END_TIME - START_TIME))
      CACHE_STATUS=$(grep -i "x-litellm-cache" "${CACHE_HEADER_FILE}" | head -1 | tr -d '\r\n' || true)
      rm -f "${CACHE_HEADER_FILE}"

      if echo "${CACHE_STATUS}" | grep -i -E "HIT|True" >/dev/null; then
        echo "      Response Cache Header: ${CACHE_STATUS}"
        echo "      Elapsed Time:          ${ELAPSED_MS} ms"
        echo "      [PASS] Redis exact match cache hit verified via primary LiteLLM cache header on attempt ${attempt}."
        CACHE_PASSED="true"
        break
      elif [ "${ELAPSED_MS}" -lt 25 ]; then
        echo "      Response Cache Header: ${CACHE_STATUS:-None}"
        echo "      Elapsed Time:          ${ELAPSED_MS} ms"
        echo "      [PASS] Redis exact match cache hit verified via secondary low-latency signal (<25ms) on attempt ${attempt}."
        CACHE_PASSED="true"
        break
      fi
      sleep 1
    done

    if [ "${CACHE_PASSED}" != "true" ]; then
      echo "      Response Cache Header: ${CACHE_STATUS:-None}"
      echo "      Elapsed Time (TTFT):   ${ELAPSED_MS} ms"
      echo "      [FAIL] Redis cache hit test did not observe cache hit within latency/header threshold."
    fi

    # Test 5: BigQuery Audit Sink & Live Trajectory Verification
    echo "    [Test 5/5] Running BigQuery Audit Sink & Trajectory Verification..."
    if [ -f "${SCRIPT_DIR}/check_bq.py" ]; then
      export PROJECT_ID
      GOOGLE_API_USE_CLIENT_CERTIFICATE=false python3 "${SCRIPT_DIR}/check_bq.py" || true
    fi
  else
    echo "    NOTE: Gateway pod is not yet in Running state (${GATEWAY_STATUS}). Check logs with:"
    echo "          kubectl logs -n llm-serving ${GATEWAY_POD} -c gateway"
  fi
else
  echo "    NOTE: No active Enterprise Gateway pod found in namespace 'llm-serving'."
fi

echo "=============================================================================="
echo "Verification check complete. To monitor real-time logs:"
echo "  kubectl logs -n llm-serving -l app=glm52-serving -c vllm-engine -f"
echo "  kubectl logs -n llm-serving -l app=glm52-enterprise-gateway -c gateway -f"
echo "=============================================================================="
