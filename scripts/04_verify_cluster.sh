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

INFERENCE_ENGINE="${INFERENCE_ENGINE:-vllm}"
ENGINE_CONTAINER="${INFERENCE_ENGINE}-engine"

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

# 5. Check serving engine health (if pod is running)
echo "--> 5. Checking ${INFERENCE_ENGINE} serving pod health status..."
SERVING_POD=$(kubectl get pod -n llm-serving -l app=glm52-serving -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
SERVING_VIP=$(kubectl get svc glm52-serving-svc -n llm-serving -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "glm52-serving-svc.llm-serving.svc.cluster.local")

if [ -z "${SERVING_POD}" ]; then
  echo "    [FAIL] No active serving pod found (Deployment may be scaled to 0 or waiting for spot nodes)." >&2
  exit 1
fi

POD_STATUS=$(kubectl get pod "${SERVING_POD}" -n llm-serving -o jsonpath='{.status.phase}')
echo "    Serving Pod Name:   ${SERVING_POD}"
echo "    Serving Pod Status: ${POD_STATUS}"

if [ "${POD_STATUS}" != "Running" ]; then
  echo "    [FAIL] Serving pod is not in Running state (${POD_STATUS})!" >&2
  echo "          kubectl logs -n llm-serving ${SERVING_POD} -c ${ENGINE_CONTAINER}" >&2
  exit 1
fi

echo "    Testing ${INFERENCE_ENGINE} serving health endpoint..."
if ! curl -s --connect-timeout 2 "http://${SERVING_VIP}:8000/health" >/dev/null 2>&1 && ! curl -s --connect-timeout 2 "http://localhost:8000/health" >/dev/null 2>&1; then
  echo "    --> Establishing background kubectl port-forward for serving (8000:8000)..."
  kubectl port-forward -n llm-serving svc/glm52-serving-svc 8000:8000 >/dev/null 2>&1 &
  PF_PIDS+=($!)
  sleep 3
fi
if curl -s --max-time 5 http://localhost:8000/health >/dev/null 2>&1 || curl -s --max-time 5 "http://${SERVING_VIP}:8000/health" >/dev/null 2>&1; then
  echo "      [PASS] ${INFERENCE_ENGINE} /health endpoint returned HTTP 200."
else
  echo "    Testing local /health endpoint inside pod..."
  if ! kubectl exec -n llm-serving "${SERVING_POD}" -c "${ENGINE_CONTAINER}" -- curl -s --max-time 5 http://localhost:8000/health >/dev/null 2>&1; then
    echo "      [FAIL] ${INFERENCE_ENGINE} /health endpoint returned non-200 or failed to respond!" >&2
    exit 1
  fi
  echo "      [PASS] ${INFERENCE_ENGINE} local /health endpoint inside pod returned HTTP 200."
fi

# 6. Enterprise AI Gateway & Proxy Layer 5-Point Verification Suite
echo "--> 6. Enterprise AI Gateway & Proxy Layer 5-Point Verification Suite..."
GATEWAY_POD=$(kubectl get pod -n llm-serving -l app=glm52-enterprise-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
GATEWAY_VIP=$(kubectl get svc glm52-gateway-svc -n llm-serving -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "glm52-gateway-svc.llm-serving.svc.cluster.local")

if [ -z "${GATEWAY_POD}" ]; then
  echo "    [FAIL] No active Enterprise Gateway pod found in namespace 'llm-serving'." >&2
  exit 1
fi

GATEWAY_STATUS=$(kubectl get pod "${GATEWAY_POD}" -n llm-serving -o jsonpath='{.status.phase}')
echo "    Gateway Pod Name:   ${GATEWAY_POD}"
echo "    Gateway Pod Status: ${GATEWAY_STATUS}"
echo "    Gateway Service IP: ${GATEWAY_VIP}"

if [ "${GATEWAY_STATUS}" != "Running" ]; then
  echo "    [FAIL] Gateway pod is not in Running state (${GATEWAY_STATUS})!" >&2
  echo "          kubectl logs -n llm-serving ${GATEWAY_POD} -c gateway" >&2
  exit 1
fi

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
        sys.exit(0)
except urllib.error.HTTPError as e:
    if header_file:
        with open(header_file, 'w') as hf:
            for k, v in e.headers.items():
                hf.write(f'{k}: {v}\n')
    if show_code: sys.stdout.write(str(e.code))
    else: sys.stdout.write(e.read().decode('utf-8'))
    sys.exit(0)
except Exception as e:
    sys.stderr.write(f'Transport error: {e}\n')
    sys.exit(1)
"
    kubectl exec -n llm-serving "${GATEWAY_POD}" -c gateway -- python3 -c "${py_script}" "$@"
  fi
}

# Test 1: 401 Unauthorized Auth Test
echo "    [Test 1/5] Running 401 Unauthorized Auth Test (No API Key)..."
if ! HTTP_CODE=$(run_gateway_curl -s -o /dev/null -w "%{http_code}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "test auth"}]}'); then
  echo "      [FAIL] Transport failure communicating with Gateway during Test 1!" >&2
  exit 1
fi
if [ "${HTTP_CODE}" = "401" ]; then
  echo "      [PASS] Returned HTTP 401 Unauthorized as expected."
else
  echo "      [FAIL] Returned HTTP ${HTTP_CODE} (expected HTTP 401 Unauthorized)!" >&2
  exit 1
fi

# Test 2: 200 Virtual Key Success Test
echo "    [Test 2/5] Running 200 Virtual Key Success Test..."
MASTER_KEY="${GATEWAY_MASTER_KEY:-sk-glm52-master-secret-key-change-me}"
if ! KEY_RESP=$(run_gateway_curl -s -X POST http://"${GATEWAY_VIP}":4000/key/generate \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"models": ["glm-5.2-moe"], "aliases": {"glm-5.2-moe": "glm-5.2-moe"}, "key_alias": "sk-glm52-test-dev-'${RANDOM}'"}'); then
  echo "      [FAIL] Transport failure calling /key/generate during Test 2!" >&2
  exit 1
fi
DEV_KEY=$(echo "${KEY_RESP}" | grep -E -o '"key"\s*:\s*"[^"]*' | cut -d'"' -f4 2>/dev/null || true)
if [ -z "${DEV_KEY}" ]; then
  echo "      [FAIL] Failed to generate virtual key from Gateway. Response: ${KEY_RESP}" >&2
  exit 1
fi
if ! HTTP_CODE=$(run_gateway_curl -s -o /dev/null -w "%{http_code}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
  -H "Authorization: Bearer ${DEV_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "Hello Sovereign Gateway"}]}'); then
  echo "      [FAIL] Transport failure calling /v1/chat/completions during Test 2!" >&2
  exit 1
fi
if [ "${HTTP_CODE}" = "200" ]; then
  echo "      [PASS] Virtual key authentication returned HTTP 200 OK successfully."
else
  echo "      [FAIL] Virtual key authentication failed with HTTP ${HTTP_CODE} (expected 200)!" >&2
  exit 1
fi

# Test 2b: Live Gateway Master Key Chat Completion Test (via test_live_gateway.py)
echo "    [Test 2b/5] Running Live Gateway Master Key Chat Completion Test (via test_live_gateway.py)..."
if [ ! -f "${SCRIPT_DIR}/test_live_gateway.py" ]; then
  echo "      [FAIL] test_live_gateway.py missing!" >&2; exit 1
fi
if ! GATEWAY_PORT=4000 GATEWAY_HOST="${GATEWAY_VIP}" GATEWAY_MASTER_KEY="${MASTER_KEY}" python3 "${SCRIPT_DIR}/test_live_gateway.py"; then
  echo "      [FAIL] test_live_gateway.py execution returned non-zero!" >&2; exit 1
fi
echo "      [PASS] test_live_gateway.py verified authenticated Master Key chat completion."

# Test 3: 429 Rate Limit Quota Test
echo "    [Test 3/5] Running 429 Rate Limit Quota Test..."
if ! QUOTA_RESP=$(run_gateway_curl -s -X POST http://"${GATEWAY_VIP}":4000/key/generate \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"models": ["glm-5.2-moe"], "max_budget": 0.000001, "key_alias": "sk-glm52-quota-test-'${RANDOM}'"}'); then
  echo "      [FAIL] Transport failure generating quota key during Test 3!" >&2
  exit 1
fi
QUOTA_KEY=$(echo "${QUOTA_RESP}" | grep -E -o '"key"\s*:\s*"[^"]*' | cut -d'"' -f4 2>/dev/null || true)
if [ -z "${QUOTA_KEY}" ]; then
  echo "      [FAIL] Failed to generate budget-constrained key for Test 3!" >&2
  exit 1
fi
run_gateway_curl -s -o /dev/null http://"${GATEWAY_VIP}":4000/v1/chat/completions \
  -H "Authorization: Bearer ${QUOTA_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "Consume initial budget budget budget"}]}' || true
if ! QUOTA_CODE=$(run_gateway_curl -s -o /dev/null -w "%{http_code}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
  -H "Authorization: Bearer ${QUOTA_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "Second budget request"}]}'); then
  echo "      [FAIL] Transport failure calling second budget request during Test 3!" >&2
  exit 1
fi
if [ "${QUOTA_CODE}" = "429" ] || [ "${QUOTA_CODE}" = "400" ]; then
  echo "      [PASS] Rate/budget quota deduction enforced (HTTP ${QUOTA_CODE})."
else
  echo "      [FAIL] Rate/budget quota test returned HTTP ${QUOTA_CODE} (expected 429 or 400)!" >&2
  exit 1
fi

# Test 4: Redis Cache Hit Test (Deterministic exact match discriminator)
echo "    [Test 4/5] Running Redis Cache Hit Test (Deterministic exact match discriminator)..."
UNIQUE_PROMPT_ID="cache-test-${RANDOM}-$(date +%s)"
CACHE_PROMPT='{"model": "glm-5.2-moe", "temperature": 0.0, "messages": [{"role": "user", "content": "Sovereign AI deterministic caching test query: '${UNIQUE_PROMPT_ID}'"}]}'
AUTH_HEADER_KEY="${DEV_KEY:-${MASTER_KEY}}"

HEADER_FILE_1=$(mktemp); BODY_FILE_1=$(mktemp)
if ! run_gateway_curl -s -D "${HEADER_FILE_1}" -o "${BODY_FILE_1}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
  -H "Authorization: Bearer ${AUTH_HEADER_KEY}" \
  -H "Content-Type: application/json" \
  -d "${CACHE_PROMPT}"; then
  echo "      [FAIL] Transport failure on priming request in Test 4!" >&2; exit 1
fi
COST_1=$(grep -i "^x-litellm-response-cost:" "${HEADER_FILE_1}" | awk -F: '{print $2}' | tr -d ' \r\n' || echo "999")
ID_1=$(python3 -c "import json, sys; print(json.load(open('${BODY_FILE_1}')).get('id',''))" 2>/dev/null || true)
rm -f "${HEADER_FILE_1}" "${BODY_FILE_1}"

if python3 -c "import sys; sys.exit(0 if float('${COST_1}') > 0.0 else 1)" 2>/dev/null; then
  echo "      [PASS] Request 1 confirmed as Cache MISS (x-litellm-response-cost: ${COST_1} > 0.0 | ID: ${ID_1})."
else
  echo "      [FAIL] Request 1 did not register a positive response cost on cache miss (cost: ${COST_1})!" >&2; exit 1
fi
sleep 1

CACHE_PASSED="false"
for attempt in 1 2 3; do
  HEADER_FILE_2=$(mktemp); BODY_FILE_2=$(mktemp)
  if ! run_gateway_curl -s -D "${HEADER_FILE_2}" -o "${BODY_FILE_2}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
    -H "Authorization: Bearer ${AUTH_HEADER_KEY}" \
    -H "Content-Type: application/json" \
    -d "${CACHE_PROMPT}"; then
    echo "      [FAIL] Transport failure on attempt ${attempt} in Test 4!" >&2; exit 1
  fi
  COST_2=$(grep -i "^x-litellm-response-cost:" "${HEADER_FILE_2}" | awk -F: '{print $2}' | tr -d ' \r\n' || echo "999")
  ID_2=$(python3 -c "import json, sys; print(json.load(open('${BODY_FILE_2}')).get('id',''))" 2>/dev/null || true)
  rm -f "${HEADER_FILE_2}" "${BODY_FILE_2}"

  if python3 -c "import sys; sys.exit(0 if float('${COST_2}') == 0.0 and '${ID_2}' == '${ID_1}' and len('${ID_1}') > 0 else 1)" 2>/dev/null; then
    echo "      [PASS] Request 2 confirmed as Cache HIT on attempt ${attempt} (x-litellm-response-cost: ${COST_2} == 0.0 | Preserved ID: ${ID_2})."
    CACHE_PASSED="true"
    break
  fi
  sleep 1
done

if [ "${CACHE_PASSED}" != "true" ]; then
  echo "      [FAIL] Redis cache hit test failed: did not observe cost==0.0 and identical completion ID across requests!" >&2
  exit 1
fi

# Test 5: BigQuery Audit Sink & Live Trajectory Verification
echo "    [Test 5/5] Running BigQuery Audit Sink & Trajectory Verification..."
if [ ! -f "${SCRIPT_DIR}/check_bq.py" ]; then
  echo "      [FAIL] check_bq.py not found in ${SCRIPT_DIR}!" >&2
  exit 1
fi

export PROJECT_ID
COUNT_BEFORE=$(GOOGLE_API_USE_CLIENT_CERTIFICATE=false python3 "${SCRIPT_DIR}/check_bq.py" --count-only)

BQ_TEST_ID="bq-audit-${RANDOM}-$(date +%s)"
echo "      Sending test completion request with known identifier: ${BQ_TEST_ID}..."
if ! run_gateway_curl -s -o /dev/null http://"${GATEWAY_VIP}":4000/v1/chat/completions \
  -H "Authorization: Bearer ${AUTH_HEADER_KEY}" \
  -H "x-litellm-call-id: ${BQ_TEST_ID}" \
  -H "Content-Type: application/json" \
  -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "BigQuery audit verification test."}]}'; then
  echo "      [FAIL] Transport failure sending request for BigQuery verification!" >&2
  exit 1
fi

if ! GOOGLE_API_USE_CLIENT_CERTIFICATE=false python3 "${SCRIPT_DIR}/check_bq.py" \
  --verify-id "${BQ_TEST_ID}" \
  --count-before "${COUNT_BEFORE}" \
  --timeout 180; then
  echo "      [FAIL] BigQuery audit trajectory verification failed!" >&2
  exit 1
fi

if [ "${RUN_DISRUPTIVE_TESTS:-false}" = "true" ]; then
  echo "=============================================================================="
  echo "--> 7. Running A6b Enterprise Disruptive & Post-Benchmark Verification Suite..."
  echo "=============================================================================="

  echo "    [Disruptive Check 1/6] Verifying HPA reported metrics (not <unknown>)..."
  HPA_VAL=$(kubectl get hpa glm52-serving-hpa -n llm-serving -o jsonpath='{.status.currentMetrics[0].external.current.value}' 2>/dev/null || kubectl get hpa glm52-serving-hpa -n llm-serving -o jsonpath='{.status.currentMetrics[0].pods.current.value}' 2>/dev/null || echo "<unknown>")
  if [ "${HPA_VAL}" = "<unknown>" ] || [ -z "${HPA_VAL}" ]; then
    echo "      [FAIL] HPA metric target reported as <unknown> or unavailable!" >&2; exit 1
  fi
  echo "      [PASS] HPA reported valid current metric value: ${HPA_VAL}."

  echo "    [Disruptive Check 2/6] Verifying PodMonitoring target scraping and data points..."
  if ! kubectl get podmonitoring -n llm-serving >/dev/null 2>&1; then
    echo "      [FAIL] PodMonitoring custom resources not found in llm-serving!" >&2; exit 1
  fi
  METRICS_OUT=$(kubectl exec -n llm-serving "${SERVING_POD}" -c "${ENGINE_CONTAINER}" -- curl -s http://localhost:8000/metrics || true)
  if ! echo "${METRICS_OUT}" | grep -iE "DCGM_FI_" >/dev/null; then
    echo "      [FAIL] No DCGM GPU metric data points (DCGM_FI_*) returned from serving target!" >&2; exit 1
  fi
  if ! echo "${METRICS_OUT}" | grep -iE "vllm:num_requests|sglang:num_queue|sglang:num_running" >/dev/null; then
    echo "      [FAIL] No engine queue metric data points returned from serving target!" >&2; exit 1
  fi
  echo "      [PASS] Verified PodMonitoring target scraping and DCGM/queue data points."

  echo "    [Disruptive Check 3/6] Verifying Token-Bucket Rate Limit (429 on low RPM key)..."
  RPM_KEY_RESP=$(run_gateway_curl -s -X POST http://"${GATEWAY_VIP}":4000/key/generate \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"models": ["glm-5.2-moe"], "rpm_limit": 2, "key_alias": "sk-glm52-low-rpm-'${RANDOM}'"}')
  RPM_KEY=$(echo "${RPM_KEY_RESP}" | grep -E -o '"key"\s*:\s*"[^"]*' | cut -d'"' -f4 2>/dev/null || true)
  if [ -z "${RPM_KEY}" ]; then echo "      [FAIL] Failed to generate low-RPM key!" >&2; exit 1; fi
  for _ in 1 2; do
    run_gateway_curl -s -o /dev/null http://"${GATEWAY_VIP}":4000/v1/chat/completions \
      -H "Authorization: Bearer ${RPM_KEY}" -H "Content-Type: application/json" \
      -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "rate limit test"}]}' || true
  done
  RPM_CODE=$(run_gateway_curl -s -o /dev/null -w "%{http_code}" http://"${GATEWAY_VIP}":4000/v1/chat/completions \
    -H "Authorization: Bearer ${RPM_KEY}" -H "Content-Type: application/json" \
    -d '{"model": "glm-5.2-moe", "messages": [{"role": "user", "content": "trip limit"}]}')
  if [ "${RPM_CODE}" = "429" ]; then
    echo "      [PASS] Token-bucket rate limiter enforced HTTP 429 on low-RPM key."
  else
    echo "      [FAIL] Rate limiter returned HTTP ${RPM_CODE} (expected 429) on low-RPM key!" >&2; exit 1
  fi

  echo "    [Disruptive Check 4/6] Verifying WIF pod identity vs node default..."
  POD_SA=$(kubectl exec -n llm-serving "${GATEWAY_POD}" -c gateway -- python3 -c 'import urllib.request; req=urllib.request.Request("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email", headers={"Metadata-Flavor":"Google"}); print(urllib.request.urlopen(req, timeout=3).read().decode())' 2>/dev/null || true)
  if [[ "${POD_SA}" == *"-compute@developer.gserviceaccount.com"* ]] || [[ "${POD_SA}" == *"@appspot.gserviceaccount.com"* ]] || [ -z "${POD_SA}" ]; then
    echo "      [FAIL] Pod identity fell back to node default or failed: ${POD_SA:-None}!" >&2; exit 1
  fi
  echo "      [PASS] Verified WIF active pod identity: ${POD_SA}."

  echo "    [Disruptive Check 5/6] Verifying Cloud SQL Private IP (no public IP)..."
  PUBLIC_IP=$(gcloud sql instances describe glm52-gateway --project="${PROJECT_ID}" --format='value(ipAddresses[?(@.type=="PRIMARY")].ipAddress)' 2>/dev/null || true)
  if [ -n "${PUBLIC_IP}" ]; then
    echo "      [FAIL] Cloud SQL instance has a public IP address configured: ${PUBLIC_IP}!" >&2; exit 1
  fi
  echo "      [PASS] Verified Cloud SQL instance has no public IP address."

  echo "    [Disruptive Check 6/6] Verifying Turndown CronJob manual trigger & replica movement..."
  INITIAL_REPLICAS=$(kubectl get deployment glm52-nvfp4-serving -n llm-serving -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  TEST_JOB_NAME="test-turndown-job-$(date +%s)"
  if ! kubectl create job --from=cronjob/glm52-scale-down-night "${TEST_JOB_NAME}" -n llm-serving >/dev/null; then
    echo "      [FAIL] Failed to create manual test job from turndown CronJob!" >&2; exit 1
  fi
  kubectl wait --for=condition=Complete job/"${TEST_JOB_NAME}" -n llm-serving --timeout=60s || true
  NEW_REPLICAS=$(kubectl get deployment glm52-nvfp4-serving -n llm-serving -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  kubectl delete job "${TEST_JOB_NAME}" -n llm-serving --ignore-not-found=true >/dev/null 2>&1
  if [ "${NEW_REPLICAS}" != "0" ]; then
    echo "      [FAIL] Turndown CronJob failed to move replica count to 0 (current: ${NEW_REPLICAS})!" >&2; exit 1
  fi
  echo "      [PASS] Turndown CronJob manually triggered and verified replica count moved from ${INITIAL_REPLICAS} to 0."
fi

echo "=============================================================================="
echo "Verification check complete. To monitor real-time logs:"
echo "  kubectl logs -n llm-serving -l app=glm52-serving -c ${ENGINE_CONTAINER} -f"
echo "  kubectl logs -n llm-serving -l app=glm52-enterprise-gateway -c gateway -f"
echo "=============================================================================="
