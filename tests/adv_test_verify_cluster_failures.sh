#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
MOCK_DIR=$(mktemp -d)
export MOCK_DIR
cleanup_mocks() {
  rm -rf "${MOCK_DIR}"
  if [ "${CREATED_MOCK_CONFIG:-false}" = "true" ]; then
    rm -f "${SCRIPT_DIR}/config.env"
  fi
}
trap cleanup_mocks EXIT

export PATH="${MOCK_DIR}:${PATH}"
export PROJECT_ID="mock-test-project"
export RUN_DISRUPTIVE_TESTS="false"

echo "=============================================================================="
echo "=== ADVANCED TEST 15: OFFLINE VERIFIER FAILURE HARNESS ==="
echo "=============================================================================="

  setup_healthy_mocks() {
  rm -f "${MOCK_DIR}"/*
  if [ ! -f "${SCRIPT_DIR}/config.env" ]; then
    sed 's/YOUR_PROJECT_ID/mock-test-project/g' "${SCRIPT_DIR}/config.env.example" > "${SCRIPT_DIR}/config.env"
    export CREATED_MOCK_CONFIG="true"
  fi
  export MOCK_AUTH_FAIL="false"
  export MOCK_NO_GATEWAY="false"
  export MOCK_BQ_EMPTY="false"

  # Mock kubectl
  cat << 'EOF' > "${MOCK_DIR}/kubectl"
#!/usr/bin/env bash
if [[ "$*" == *"get job glm52-weight-staging-job"* ]]; then exit 1; fi
if [[ "$*" == *"get pod"* ]] && [[ "$*" == *"app=glm52-serving"* ]]; then echo "glm52-serving-0"; exit 0; fi
if [[ "$*" == *"get svc glm52-serving-svc"* ]]; then echo "10.0.0.1"; exit 0; fi
if [[ "$*" == *"get pod glm52-serving-0"* ]] && [[ "$*" == *"status.phase"* ]]; then echo "Running"; exit 0; fi

if [[ "$*" == *"get pod"* ]] && [[ "$*" == *"app=glm52-enterprise-gateway"* ]]; then
  if [ "${MOCK_NO_GATEWAY:-false}" = "true" ]; then
    echo ""
  else
    echo "glm52-gateway-0"
  fi
  exit 0
fi
if [[ "$*" == *"get svc glm52-gateway-svc"* ]]; then echo "10.0.0.2"; exit 0; fi
if [[ "$*" == *"get pod glm52-gateway-0"* ]] && [[ "$*" == *"status.phase"* ]]; then echo "Running"; exit 0; fi

if [[ "$*" == *"port-forward"* ]]; then exit 0; fi

if [[ "$*" == *"exec -n llm-serving glm52-serving-0"* ]]; then exit 0; fi

if [[ "$*" == *"exec -n llm-serving glm52-gateway-0 -c gateway -- python3"* ]]; then
  args="$*"
  if [[ "${args}" == *"test auth"* ]]; then
    if [ "${MOCK_AUTH_FAIL:-false}" = "true" ]; then echo "200"; else echo "401"; fi
    exit 0
  elif [[ "${args}" == *"/key/generate"* ]]; then
    echo '{"key": "sk-mock-key-12345"}'
    exit 0
  elif [[ "${args}" == *"Hello Sovereign Gateway"* ]]; then
    echo "200"; exit 0
  elif [[ "${args}" == *"Consume initial budget"* ]]; then
    echo "200"; exit 0
  elif [[ "${args}" == *"Second budget request"* ]]; then
    echo "429"; exit 0
  elif [[ "${args}" == *"deterministic caching test query"* ]]; then
    header_file=""
    body_file=""
    prev=""
    for arg in "$@"; do
      if [ "${prev}" = "-D" ]; then header_file="${arg}"; fi
      if [ "${prev}" = "-o" ]; then body_file="${arg}"; fi
      prev="${arg}"
    done
    if [ -n "${header_file}" ]; then
      if [ -f "${MOCK_DIR}/cache_primed" ]; then
        printf "HTTP/1.1 200 OK\r\nx-litellm-cache-key: HIT\r\nx-litellm-response-cost: 0.0\r\n\r\n" > "${header_file}"
      else
        printf "HTTP/1.1 200 OK\r\nx-litellm-response-cost: 0.0001\r\n\r\n" > "${header_file}"
        touch "${MOCK_DIR}/cache_primed" 2>/dev/null || true
      fi
    fi
    if [ -n "${body_file}" ] && [ "${body_file}" != "/dev/null" ]; then
      echo '{"id": "chatcmpl-deterministic-mock-id"}' > "${body_file}"
    fi
    exit 0
  elif [[ "${args}" == *"BigQuery audit verification test"* ]]; then
    touch "${MOCK_DIR}/bq_incremented" 2>/dev/null || true
    exit 0
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "${MOCK_DIR}/kubectl"

  # Mock curl
  cat << 'EOF' > "${MOCK_DIR}/curl"
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "${arg}" == *"8000/health"* ]]; then exit 0; fi
  if [[ "${arg}" == *"4000/health/liveliness"* ]]; then exit 1; fi
done
exit 0
EOF
  chmod +x "${MOCK_DIR}/curl"

  # Mock bq
  cat << 'EOF' > "${MOCK_DIR}/bq"
#!/usr/bin/env bash
if [[ "$*" == *"count(*)"* ]]; then
  if [ "${MOCK_BQ_EMPTY:-false}" = "true" ]; then
    echo '[{"total_trajectories": "0"}]'
  elif [ -f "${MOCK_DIR}/bq_incremented" ]; then
    echo '[{"total_trajectories": "6"}]'
  else
    echo '[{"total_trajectories": "5"}]'
  fi
  exit 0
fi
if [[ "$*" == *"SELECT request_id"* ]] || [[ "$*" == *"WHERE request_id"* ]]; then
  echo '[{"request_id": "test-id", "request_timestamp": "12345", "virtual_key": "vk", "team_id": "t", "model": "glm", "prompt_tokens": "10", "completion_tokens": "10", "total_cost_usd": "0.0", "ttft_ms": "10", "tpot_ms": "10"}]'
  exit 0
fi
echo '[]'
exit 0
EOF
  chmod +x "${MOCK_DIR}/bq"

  # Mock python3 wrapper to intercept test_live_gateway.py in offline harness
  cat << 'EOF' > "${MOCK_DIR}/python3"
#!/usr/bin/env bash
if [[ "$*" == *"test_live_gateway.py"* ]]; then
  echo "      [PASS] Mocked test_live_gateway.py success for offline harness."
  exit 0
fi
exec /usr/bin/python3 "$@"
EOF
  chmod +x "${MOCK_DIR}/python3"
}

setup_healthy_mocks

echo "--> Baseline Check: Verifying that 04_verify_cluster.sh passes cleanly against healthy mock baseline..."
if ! bash "${SCRIPT_DIR}/04_verify_cluster.sh" >/dev/null; then
  echo "ERROR: 04_verify_cluster.sh failed against healthy mock baseline!" >&2
  exit 1
fi
echo "    [OK] Baseline check passed."

echo "--> Failure State 1: Proving auth probe returning 200 exits non-zero..."
setup_healthy_mocks
export MOCK_AUTH_FAIL="true"
if bash "${SCRIPT_DIR}/04_verify_cluster.sh" >/dev/null 2>&1; then
  echo "ERROR: 04_verify_cluster.sh failed to exit non-zero when auth probe returned 200!" >&2
  exit 1
fi
echo "    [OK] Failure State 1 verified: Auth probe returning 200 caused script to exit 1."

echo "--> Failure State 2: Proving missing check_bq.py exits non-zero..."
setup_healthy_mocks
mv "${SCRIPT_DIR}/check_bq.py" "${SCRIPT_DIR}/check_bq.py.tmp"
if bash "${SCRIPT_DIR}/04_verify_cluster.sh" >/dev/null 2>&1; then
  mv "${SCRIPT_DIR}/check_bq.py.tmp" "${SCRIPT_DIR}/check_bq.py"
  echo "ERROR: 04_verify_cluster.sh failed to exit non-zero when check_bq.py was missing!" >&2
  exit 1
fi
mv "${SCRIPT_DIR}/check_bq.py.tmp" "${SCRIPT_DIR}/check_bq.py"
echo "    [OK] Failure State 2 verified: Missing check_bq.py caused script to exit 1."

echo "--> Failure State 3: Proving missing gateway pod exits non-zero..."
setup_healthy_mocks
export MOCK_NO_GATEWAY="true"
if bash "${SCRIPT_DIR}/04_verify_cluster.sh" >/dev/null 2>&1; then
  echo "ERROR: 04_verify_cluster.sh failed to exit non-zero when gateway pod was missing!" >&2
  exit 1
fi
echo "    [OK] Failure State 3 verified: Missing gateway pod caused script to exit 1."

echo "--> Failure State 4: Proving empty BigQuery table (total_rows == 0) exits non-zero in check_bq.py and verify script..."
setup_healthy_mocks
export MOCK_BQ_EMPTY="true"
if python3 "${SCRIPT_DIR}/check_bq.py" >/dev/null 2>&1; then
  echo "ERROR: check_bq.py failed to exit non-zero when BigQuery table was empty (total_rows == 0)!" >&2
  exit 1
fi
if bash "${SCRIPT_DIR}/04_verify_cluster.sh" >/dev/null 2>&1; then
  echo "ERROR: 04_verify_cluster.sh failed to exit non-zero when BigQuery audit table was empty!" >&2
  exit 1
fi
echo "    [OK] Failure State 4 verified: Empty BigQuery table caused both check_bq.py and 04_verify_cluster.sh to exit 1."

echo "=============================================================================="
echo "=== ALL 4 OFFLINE VERIFIER FAILURE STATES PROVED SUCCESSFULLY ==="
echo "=============================================================================="
