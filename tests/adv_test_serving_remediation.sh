#!/usr/bin/env bash
# ==============================================================================
# adv_test_serving_remediation.sh - Automated Remediation Verification Suite
# ==============================================================================
# Verifies zero legacy networking matches (RoCE/multi-nic), pinned container
# images and adapter manifests, schema-validated Kubernetes manifests, clean
# benchmark comparison generation, and adversarial provenance gate rejection.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

echo "=============================================================================="
echo "GLM-5 GCP Enterprise Serving - Automated Remediation Verification Suite"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# Check 1: Zero matches for roce, multinic, multi-nic (case-insensitive)
# ------------------------------------------------------------------------------
echo "--> Check 1: Verifying zero matches for roce, multinic, multi-nic across repository..."
# Use word boundary and exclude non-source/metadata directories to prevent false positives
if grep -rnwiE 'roce|multinic|multi-nic' --exclude-dir={.agents,.git,.venv,.terraform,__pycache__,tests} . ; then
  echo "ERROR: Check 1 failed: Found forbidden networking terms (roce, multinic, multi-nic) in repository!" >&2
  exit 1
fi
echo "    [OK] Check 1 passed: Zero legacy networking matches found."

# ------------------------------------------------------------------------------
# Check 2: Pinned kubectl tag in 01-rbac-wif.yaml.template (no :slim)
# ------------------------------------------------------------------------------
echo "--> Check 2: Verifying terraform/manifests/templates/01-rbac-wif.yaml.template uses pinned kubectl tag..."
RBAC_TEMPLATE="terraform/manifests/templates/01-rbac-wif.yaml.template"
if [ ! -f "${RBAC_TEMPLATE}" ]; then
  echo "ERROR: Check 2 failed: ${RBAC_TEMPLATE} not found!" >&2
  exit 1
fi
if grep -q ":slim" "${RBAC_TEMPLATE}"; then
  echo "ERROR: Check 2 failed: Found unpinned ':slim' tag in ${RBAC_TEMPLATE}!" >&2
  exit 1
fi
echo "    [OK] Check 2 passed: No unpinned ':slim' tag found in RBAC template."

# ------------------------------------------------------------------------------
# Check 3: Pinned custom-metrics-stackdriver-adapter and engine versions
# ------------------------------------------------------------------------------
echo "--> Check 3: Verifying pinned adapter manifest and engine versions in scripts/03_deploy_workloads.sh..."
DEPLOY_SCRIPT="scripts/03_deploy_workloads.sh"
if [ ! -f "${DEPLOY_SCRIPT}" ]; then
  echo "ERROR: Check 3 failed: ${DEPLOY_SCRIPT} not found!" >&2
  exit 1
fi
if ! grep -q "cm-sd-adapter-v" "${DEPLOY_SCRIPT}"; then
  echo "ERROR: Check 3 failed: custom-metrics-stackdriver-adapter is not pinned to a specific release tag!" >&2
  exit 1
fi
if ! grep -q "v0.25.1" "${DEPLOY_SCRIPT}"; then
  echo "ERROR: Check 3 failed: vLLM engine is not pinned to v0.25.1 in ${DEPLOY_SCRIPT}!" >&2
  exit 1
fi
if ! grep -q "v0.5.12-cu130" "${DEPLOY_SCRIPT}"; then
  echo "ERROR: Check 3 failed: SGLang engine is not pinned to v0.5.12-cu130 in ${DEPLOY_SCRIPT}!" >&2
  exit 1
fi
echo "    [OK] Check 3 passed: Adapter manifest and engine versions are properly pinned."

# ------------------------------------------------------------------------------
# Check 4: Kubeconform validation of rendered YAML manifests
# ------------------------------------------------------------------------------
echo "--> Check 4: Verifying rendered YAML manifests with kubeconform..."
if [ ! -f "scripts/config.env" ] && [ -f "scripts/config.env.example" ]; then
  cp scripts/config.env.example scripts/config.env
  CLEANUP_CONFIG_ENV=true
else
  CLEANUP_CONFIG_ENV=false
fi
./scripts/03_deploy_workloads.sh --render-only >/dev/null
kubeconform -summary -schema-location default -schema-location 'terraform/manifests/schemas/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json' terraform/manifests/generated/*.yaml
if [ "${CLEANUP_CONFIG_ENV}" = "true" ]; then
  rm -f scripts/config.env
fi
echo "    [OK] Check 4 passed: All rendered manifests passed kubeconform schema validation."

# ------------------------------------------------------------------------------
# Check 5: Clean execution of benchmarks/generate_comparison.py & zero diff
# ------------------------------------------------------------------------------
echo "--> Check 5: Verifying benchmarks/generate_comparison.py cleanly executes with zero README.md diff..."
python3 benchmarks/generate_comparison.py >/dev/null
if ! git diff --exit-code README.md >/dev/null; then
  echo "ERROR: Check 5 failed: benchmarks/generate_comparison.py modified README.md!" >&2
  git diff README.md >&2
  exit 1
fi
echo "    [OK] Check 5 passed: Benchmark comparison generated cleanly with zero diff against README.md."

# ------------------------------------------------------------------------------
# Check 6: Adversarial Proof of Provenance Gate
# ------------------------------------------------------------------------------
echo "--> Check 6: Adversarial Proof of Provenance Gate (testing invalid inputs)..."
python3 -c '
import sys
from pathlib import Path

sys.path.insert(0, "benchmarks")
from generate_comparison import validate_provenance, load_json

root = Path("benchmarks/results")
vllm_data = {s: load_json(root / "vllm" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}
sglang_data = {s: load_json(root / "sglang" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}

# Test 1: Mismatched engine version
vllm_bad_ver = dict(vllm_data)
vllm_bad_ver["standard"] = dict(vllm_data["standard"])
vllm_bad_ver["standard"]["metadata"] = dict(vllm_data["standard"]["metadata"])
vllm_bad_ver["standard"]["metadata"]["engine_version"] = "v0.99.9-bogus"

try:
    validate_provenance(vllm_bad_ver, sglang_data)
    print("ERROR: validate_provenance() failed to catch mismatched engine version!", file=sys.stderr)
    sys.exit(1)
except ValueError as e:
    print(f"    [OK] Caught expected version mismatch error: {e}")

# Test 2: Overlapping / out-of-order timestamp
vllm_bad_ts = dict(vllm_data)
vllm_bad_ts["soak"] = dict(vllm_data["soak"])
vllm_bad_ts["soak"]["metadata"] = dict(vllm_data["soak"]["metadata"])
vllm_bad_ts["soak"]["metadata"]["run_timestamp"] = "2026-07-24T10:41:59Z"

try:
    validate_provenance(vllm_bad_ts, sglang_data)
    print("ERROR: validate_provenance() failed to catch overlapping timestamp!", file=sys.stderr)
    sys.exit(1)
except ValueError as e:
    print(f"    [OK] Caught expected timestamp overlap error: {e}")
'
echo "    [OK] Check 6 passed: Provenance Gate successfully rejected adversarial version and timestamp inputs."

echo "=============================================================================="
echo "SUCCESS: All 6 automated remediation checks passed cleanly!"
echo "=============================================================================="
