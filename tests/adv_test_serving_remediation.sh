#!/usr/bin/env bash
# ==============================================================================
# adv_test_serving_remediation.sh - Adversarial Test Suite for Serving Remediation
# ==============================================================================
# Verifies commit 31bae0c84f184d3eb11a35774734ec4144067e23:
# 1. Environment Override Precedence in config.env (${INFERENCE_ENGINE:-vllm})
# 2. Engine Image Separation (SGLANG_SERVING_IMAGE vs VLLM_SERVING_IMAGE)
# 3. Custom SERVING_IMAGE Override Isolation
# 4. SGLang HPA Metric Naming (sglang:num_queue_reqs|gauge)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

PASS_COUNT=0
FAIL_COUNT=0

log_pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
  echo "[FAIL] $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "=============================================================================="
echo "Starting Adversarial Verification Suite: Serving Remediation (Commit 31bae0c)"
echo "=============================================================================="

# Ensure config.env exists from example without sed clobbering
cp -f scripts/config.env.example scripts/config.env
sed -i 's/export PROJECT_ID="YOUR_PROJECT_ID"/export PROJECT_ID="adv-test-proj"/' scripts/config.env

# ------------------------------------------------------------------------------
# Test 1: Environment Override Precedence in config.env
# ------------------------------------------------------------------------------
echo "--> Test 1: Testing Environment Override Precedence (INFERENCE_ENGINE=sglang before source)..."
# shellcheck source=/dev/null
TEST1_VAL=$( (export INFERENCE_ENGINE="sglang" && source scripts/config.env && echo "${INFERENCE_ENGINE}") )
if [ "${TEST1_VAL}" = "sglang" ]; then
  log_pass "config.env respected pre-existing INFERENCE_ENGINE=sglang override"
else
  log_fail "config.env overwrote INFERENCE_ENGINE to '${TEST1_VAL}' (expected 'sglang')"
fi

# ------------------------------------------------------------------------------
# Test 2: Engine Image Separation in Rendered Manifests (sglang mode)
# ------------------------------------------------------------------------------
echo "--> Test 2: Testing Engine Image Separation when INFERENCE_ENGINE=sglang..."
INFERENCE_ENGINE=sglang ./scripts/03_deploy_workloads.sh --render-only >/dev/null

SGLANG_IMG=$(grep -E "image: .*sglang-blackwell" terraform/manifests/generated/03-sglang-spot-serving.yaml || true)
VLLM_IMG=$(grep -E "image: .*vllm-blackwell" terraform/manifests/generated/03-vllm-spot-serving.yaml || true)
LEAKED_IMG=$(grep -E "image: .*sglang-blackwell" terraform/manifests/generated/03-vllm-spot-serving.yaml || true)

if [ -n "${SGLANG_IMG}" ] && [ -n "${VLLM_IMG}" ] && [ -z "${LEAKED_IMG}" ]; then
  log_pass "Manifests rendered with isolated engine images (sglang->sglang, vllm->vllm without cross-contamination)"
else
  log_fail "Image contamination detected! SGLANG_IMG='${SGLANG_IMG}', VLLM_IMG='${VLLM_IMG}', LEAKED='${LEAKED_IMG}'"
fi

# ------------------------------------------------------------------------------
# Test 3: Custom SERVING_IMAGE Override Isolation
# ------------------------------------------------------------------------------
echo "--> Test 3: Testing Custom SERVING_IMAGE Override Isolation in sglang mode..."
INFERENCE_ENGINE=sglang SERVING_IMAGE="custom-repo/adv-sglang:v999" ./scripts/03_deploy_workloads.sh --render-only >/dev/null

CUSTOM_SGLANG=$(grep -E "image: custom-repo/adv-sglang:v999" terraform/manifests/generated/03-sglang-spot-serving.yaml || true)
DEFAULT_VLLM=$(grep -E "image: .*vllm-blackwell:v0.26.0" terraform/manifests/generated/03-vllm-spot-serving.yaml || true)
LEAKED_CUSTOM=$(grep -E "image: custom-repo/adv-sglang:v999" terraform/manifests/generated/03-vllm-spot-serving.yaml || true)

if [ -n "${CUSTOM_SGLANG}" ] && [ -n "${DEFAULT_VLLM}" ] && [ -z "${LEAKED_CUSTOM}" ]; then
  log_pass "Custom SERVING_IMAGE override applied strictly to active engine (sglang) while vllm retained default image"
else
  log_fail "Override isolation failed! CUSTOM_SGLANG='${CUSTOM_SGLANG}', DEFAULT_VLLM='${DEFAULT_VLLM}', LEAKED='${LEAKED_CUSTOM}'"
fi

# ------------------------------------------------------------------------------
# Test 4: SGLang HPA Metric Naming and Stackdriver Custom Metric Syntax
# ------------------------------------------------------------------------------
echo "--> Test 4: Testing SGLang HPA Metric Naming in 07-hpa.yaml..."
INFERENCE_ENGINE=sglang ./scripts/03_deploy_workloads.sh --render-only >/dev/null

QUEUE_METRIC=$(grep -E "prometheus\.googleapis\.com\|sglang:num_queue_reqs\|gauge" terraform/manifests/generated/07-hpa.yaml || true)
RUNNING_METRIC=$(grep -E "prometheus\.googleapis\.com\|sglang:num_running_reqs\|gauge" terraform/manifests/generated/07-hpa.yaml || true)
BAD_UNKNOWN=$(grep -E "\|unknown" terraform/manifests/generated/07-hpa.yaml || true)
BAD_UNDERSCORE=$(grep -E "sglang_num_queue_reqs" terraform/manifests/generated/07-hpa.yaml || true)

if [ -n "${QUEUE_METRIC}" ] && [ -n "${RUNNING_METRIC}" ] && [ -z "${BAD_UNKNOWN}" ] && [ -z "${BAD_UNDERSCORE}" ]; then
  log_pass "SGLang HPA metrics correctly rendered with Stackdriver custom metric syntax (gauge)"
else
  log_fail "HPA metric naming verification failed! QUEUE='${QUEUE_METRIC}', RUNNING='${RUNNING_METRIC}', UNKNOWN='${BAD_UNKNOWN}', UNDERSCORE='${BAD_UNDERSCORE}'"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "Verification Summary: ${PASS_COUNT} PASSED, ${FAIL_COUNT} FAILED"
echo "=============================================================================="

if [ "${FAIL_COUNT}" -ne 0 ]; then
  exit 1
fi
exit 0
