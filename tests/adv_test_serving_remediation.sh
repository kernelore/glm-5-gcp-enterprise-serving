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
if ! grep -E -q '^\s*(export\s+)?VLLM_IMAGE_TAG="(v[0-9]+\.[0-9]+\.[0-9]+.*)"' "${DEPLOY_SCRIPT}"; then
  echo "ERROR: Check 3 failed: VLLM_IMAGE_TAG is not pinned to an explicit semver release tag in ${DEPLOY_SCRIPT}!" >&2
  exit 1
fi
if ! grep -E -q '^\s*(export\s+)?SGLANG_IMAGE_TAG="(v[0-9]+\.[0-9]+\.[0-9]+.*)"' "${DEPLOY_SCRIPT}"; then
  echo "ERROR: Check 3 failed: SGLANG_IMAGE_TAG is not pinned to an explicit semver release tag in ${DEPLOY_SCRIPT}!" >&2
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
if [ -f "terraform/manifests/generated/03-sglang-spot-serving.yaml" ]; then
  echo "ERROR: Check 4 failed: Non-selected engine manifest 03-sglang-spot-serving.yaml is present in generated/ when INFERENCE_ENGINE is vllm!" >&2
  exit 1
fi
INFERENCE_ENGINE=sglang ./scripts/03_deploy_workloads.sh --render-only >/dev/null
if [ -f "terraform/manifests/generated/03-vllm-spot-serving.yaml" ]; then
  echo "ERROR: Check 4 failed: Non-selected engine manifest 03-vllm-spot-serving.yaml is present in generated/ when INFERENCE_ENGINE is sglang!" >&2
  exit 1
fi
INFERENCE_ENGINE=vllm ./scripts/03_deploy_workloads.sh --render-only >/dev/null
kubeconform -summary -schema-location default -schema-location 'terraform/manifests/schemas/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json' terraform/manifests/generated/*.yaml
if [ "${CLEANUP_CONFIG_ENV}" = "true" ]; then
  rm -f scripts/config.env
fi
echo "    [OK] Check 4 passed: All rendered manifests passed kubeconform schema validation and non-selected engine templates were excluded."

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

# Test 2: Invalid / malformed timestamp
vllm_bad_ts = dict(vllm_data)
vllm_bad_ts["soak"] = dict(vllm_data["soak"])
vllm_bad_ts["soak"]["metadata"] = dict(vllm_data["soak"]["metadata"])
vllm_bad_ts["soak"]["metadata"]["run_timestamp"] = "invalid-date-format"

try:
    validate_provenance(vllm_bad_ts, sglang_data)
    print("ERROR: validate_provenance() failed to catch malformed timestamp!", file=sys.stderr)
    sys.exit(1)
except ValueError as e:
    print(f"    [OK] Caught expected timestamp format error: {e}")
'
echo "    [OK] Check 6 passed: Provenance Gate successfully rejected adversarial version and timestamp inputs."

echo "--> Check 7: Verifying unit test suite for telemetry sanitizer..."
python3 -m unittest discover -s tests -p "test_*.py" >/dev/null
echo "    [OK] Check 7 passed: Telemetry sanitizer unit tests passed cleanly."

echo "--> Check 8: Verifying dependency floor constraints..."
python3 tests/check_dependency_floors.py >/dev/null
echo "    [OK] Check 8 passed: All dependencies satisfy or exceed floor constraints."

echo "--> Check 9: Verifying self-contained secret scan..."
bash tests/check_secret_scan.sh >/dev/null
echo "    [OK] Check 9 passed: Secret scan passed cleanly."

# ------------------------------------------------------------------------------
# Check 10: Adversarial Proof of Suite Timestamp Gate
# ------------------------------------------------------------------------------
echo "--> Check 10: Adversarial Proof of Suite Timestamp Gate (testing skip and overlap rejection)..."
python3 -c '
import sys
import io
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, "benchmarks")
from generate_comparison import validate_provenance, load_json

root = Path("benchmarks/results")
vllm_data = {s: load_json(root / "vllm" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}
sglang_data = {s: load_json(root / "sglang" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}

# Skip path: ensure baseline JSONs (lacking suite_start_ts) print informational notice and do not fail
buf = io.StringIO()
with redirect_stdout(buf):
    validate_provenance(vllm_data, sglang_data)
out = buf.getvalue()
if "NOTE: Skipping interval overlap checks for vllm standard" not in out:
    print("ERROR: validate_provenance() failed to print skip notice for baseline without suite_start_ts!", file=sys.stderr)
    sys.exit(1)
print("    [OK] Skip path verified: Informational notice printed without error when suite_start_ts is absent.")

# Rejection path: inject overlapping suite_start_ts and suite_end_ts
vllm_overlap = {s: dict(vllm_data[s]) for s in ["standard", "massive", "soak", "saturation", "prefill"]}
vllm_overlap["standard"] = dict(vllm_data["standard"])
vllm_overlap["standard"]["benchmark_config"] = dict(vllm_data["standard"].get("benchmark_config", {}))
vllm_overlap["standard"]["benchmark_config"]["suite_start_ts"] = "2026-07-26T10:00:00Z"
vllm_overlap["standard"]["benchmark_config"]["suite_end_ts"] = "2026-07-26T10:10:00Z"
vllm_overlap["massive"] = dict(vllm_data["massive"])
vllm_overlap["massive"]["benchmark_config"] = dict(vllm_data["massive"].get("benchmark_config", {}))
vllm_overlap["massive"]["benchmark_config"]["suite_start_ts"] = "2026-07-26T10:05:00Z"
vllm_overlap["massive"]["benchmark_config"]["suite_end_ts"] = "2026-07-26T10:20:00Z"

try:
    validate_provenance(vllm_overlap, sglang_data)
    print("ERROR: validate_provenance() failed to catch overlapping suite timestamps!", file=sys.stderr)
    sys.exit(1)
except ValueError as e:
    print(f"    [OK] Caught expected interval overlap error: {e}")
'
echo "    [OK] Check 10 passed: Suite timestamp gate correctly handles skip and overlap rejection paths."

echo "--> Check 11: Verifying non-canonical execution order tolerance and overlap rejection..."
python3 -c '
import sys, json
from pathlib import Path
sys.path.insert(0, "benchmarks")
from generate_comparison import validate_provenance, load_json

root = Path("benchmarks/results")
vllm_data = {s: load_json(root / "vllm" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}
sglang_data = {s: load_json(root / "sglang" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}

# Deep copy for mutation
v_noncanon = {s: json.loads(json.dumps(vllm_data[s])) for s in ["standard", "massive", "soak", "saturation", "prefill"]}
if "soak_config" not in v_noncanon["soak"]: v_noncanon["soak"]["soak_config"] = {}
if "benchmark_config" not in v_noncanon["massive"]: v_noncanon["massive"]["benchmark_config"] = {}

# Case 1: Non-overlapping intervals in non-canonical order (soak 10:00-10:10 runs before massive 10:15-10:25) -> must pass
v_noncanon["soak"]["soak_config"]["suite_start_ts"] = "2026-07-26T10:00:00Z"
v_noncanon["soak"]["soak_config"]["suite_end_ts"] = "2026-07-26T10:10:00Z"
v_noncanon["massive"]["benchmark_config"]["suite_start_ts"] = "2026-07-26T10:15:00Z"
v_noncanon["massive"]["benchmark_config"]["suite_end_ts"] = "2026-07-26T10:25:00Z"

try:
    validate_provenance(v_noncanon, sglang_data)
    print("    [OK] Case 1 passed: Non-overlapping suites in non-canonical order (soak before massive) accepted without error.")
except Exception as e:
    print(f"ERROR: validate_provenance() rejected valid non-overlapping timestamps in non-canonical order: {e}", file=sys.stderr)
    sys.exit(1)

# Case 2: Genuinely overlapping intervals in non-canonical order (soak 10:00-10:10 overlaps massive 10:05-10:25) -> must fail
v_noncanon["massive"]["benchmark_config"]["suite_start_ts"] = "2026-07-26T10:05:00Z"
try:
    validate_provenance(v_noncanon, sglang_data)
    print("ERROR: validate_provenance() failed to catch genuinely overlapping timestamps in non-canonical order!", file=sys.stderr)
    sys.exit(1)
except ValueError as e:
    if "PROVENANCE GATE FAILURE" not in str(e):
        print(f"ERROR: Expected PROVENANCE GATE FAILURE but got: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"    [OK] Case 2 passed: Caught expected interval overlap error in non-canonical order: {e}")
'
echo "    [OK] Check 11 passed: Interval gate correctly tolerates execution order while enforcing non-overlap."

echo "--> Check 12: Verifying engine pin parsing and coupling against deploy script..."
python3 -c '
import sys, tempfile, shutil
from pathlib import Path
sys.path.insert(0, "benchmarks")
import generate_comparison
from generate_comparison import parse_engine_pins, validate_provenance, load_json

# Case 1: Prove normalisation of the -cu130 suffix and exact pin parsing on real committed script
pins = parse_engine_pins("scripts/03_deploy_workloads.sh")
if pins != {"vllm": "0.25.1", "sglang": "0.5.12"}:
    print(f"ERROR: Expected pins {{\"vllm\": \"0.25.1\", \"sglang\": \"0.5.12\"}} on real script, got {pins}", file=sys.stderr)
    sys.exit(1)
print(f"    [OK] Case 1 (Real Script) passed: parse_engine_pins() returned {pins}, proving suffix normalization.")

# Setup synthetic copy in temp dir
with tempfile.TemporaryDirectory() as tmpdir:
    real_content = Path("scripts/03_deploy_workloads.sh").read_text(encoding="utf-8")
    tmp_script = Path(tmpdir) / "03_deploy_workloads.sh"

    # Case 2: Pins bumped to v0.26.0 / v0.5.16-cu130 against committed result files -> gate must fail naming both versions
    bumped_content = real_content.replace("VLLM_IMAGE_TAG=\"v0.25.1\"", "VLLM_IMAGE_TAG=\"v0.26.0\"").replace("SGLANG_IMAGE_TAG=\"v0.5.12-cu130\"", "SGLANG_IMAGE_TAG=\"v0.5.16-cu130\"")
    tmp_script.write_text(bumped_content, encoding="utf-8")
    
    root = Path("benchmarks/results")
    vllm_data = {s: load_json(root / "vllm" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}
    sglang_data = {s: load_json(root / "sglang" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}
    
    try:
        validate_provenance(vllm_data, sglang_data, deploy_script_path=str(tmp_script))
        print("ERROR: validate_provenance() failed to catch bumped engine pins against baseline JSONs!", file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        msg = str(e)
        if "PROVENANCE GATE FAILURE" not in msg or "0.26.0" not in msg or "0.25.1" not in msg:
            print(f"ERROR: Expected PROVENANCE GATE FAILURE naming both 0.26.0 and 0.25.1, got: {msg}", file=sys.stderr)
            sys.exit(1)
        print(f"    [OK] Case 2 (Bumped Pins) passed: Caught expected mismatch naming both versions: {msg}")

    # Case 3: VLLM_IMAGE_TAG line deleted entirely -> parse_engine_pins() must raise, not return a default
    deleted_content = "\n".join(l for l in real_content.splitlines() if "VLLM_IMAGE_TAG" not in l)
    tmp_script.write_text(deleted_content, encoding="utf-8")
    try:
        parse_engine_pins(str(tmp_script))
        print("ERROR: parse_engine_pins() failed to raise when VLLM_IMAGE_TAG was deleted!", file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        if "PROVENANCE GATE FAILURE" not in str(e):
            print(f"ERROR: Expected PROVENANCE GATE FAILURE when pin deleted, got: {e}", file=sys.stderr)
            sys.exit(1)
        print(f"    [OK] Case 3 (Deleted Pin) passed: parse_engine_pins() raised fail-closed error: {e}")
'
echo "    [OK] Check 12 passed: Engine version coupling and fail-closed parsing verified against synthetic deploy scripts."

echo "--> Check 13: Verifying rendered manifest tags against deploy script pins..."
# shellcheck disable=SC2016
python3 -c '
import sys, tempfile, shutil, os
from pathlib import Path
sys.path.insert(0, "benchmarks")
from generate_comparison import validate_rendered_manifests

# Case 1: Honest case passes on committed script
try:
    validate_rendered_manifests("scripts/03_deploy_workloads.sh")
    print("    [OK] Case 1 (Honest Script) passed: validate_rendered_manifests() verified rendered tags match pins.")
except Exception as e:
    print(f"ERROR: validate_rendered_manifests() failed on honest script: {e}", file=sys.stderr)
    sys.exit(1)

# Setup synthetic copy in temp dir
with tempfile.TemporaryDirectory() as tmpdir:
    repo_dir = Path(tmpdir) / "test_repo"
    scripts_dir = repo_dir / "scripts"
    os.makedirs(scripts_dir, exist_ok=True)
    real_content = Path("scripts/03_deploy_workloads.sh").read_text(encoding="utf-8")
    tmp_script = scripts_dir / "03_deploy_workloads.sh"

    # Case 2: Synthetic injection of IMAGE_TAG="v9.9.9" in vLLM branch while VLLM_IMAGE_TAG stays at v0.25.1 -> must fail
    injected_content = real_content.replace("IMAGE_TAG=\"${VLLM_IMAGE_TAG}\"", "IMAGE_TAG=\"v9.9.9\"")
    if injected_content == real_content:
        print("ERROR: Failed to inject v9.9.9 into temporary script!", file=sys.stderr)
        sys.exit(1)
    tmp_script.write_text(injected_content, encoding="utf-8")
    tmp_script.chmod(0o755)
    
    try:
        validate_rendered_manifests(str(tmp_script))
        print("ERROR: validate_rendered_manifests() failed to catch injected IMAGE_TAG=\"v9.9.9\"!", file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        msg = str(e)
        if "PROVENANCE GATE FAILURE" not in msg or "9.9.9" not in msg or "0.25.1" not in msg:
            print(f"ERROR: Expected PROVENANCE GATE FAILURE naming both 9.9.9 and 0.25.1, got: {msg}", file=sys.stderr)
            sys.exit(1)
        print(f"    [OK] Case 2 (Injected Tag) passed: Caught expected mismatch naming both versions: {msg}")

    # Case 3: Fail closed when rendered manifest has no image line at all
    templates_dir = repo_dir / "terraform" / "manifests" / "templates"
    os.makedirs(templates_dir, exist_ok=True)
    for tf in Path("terraform/manifests/templates").glob("*.template"):
        if "vllm-spot-serving" in tf.name:
            txt = tf.read_text(encoding="utf-8")
            txt_no_img = "\n".join(l for l in txt.splitlines() if "image:" not in l)
            (templates_dir / tf.name).write_text(txt_no_img, encoding="utf-8")
        else:
            shutil.copy(tf, templates_dir / tf.name)
    
    tmp_script.write_text(real_content, encoding="utf-8")
    try:
        validate_rendered_manifests(str(tmp_script))
        print("ERROR: validate_rendered_manifests() failed to catch missing image line in rendered manifest!", file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        if "PROVENANCE GATE FAILURE" not in str(e) or "No serving image line found" not in str(e):
            print(f"ERROR: Expected PROVENANCE GATE FAILURE for missing image line, got: {e}", file=sys.stderr)
            sys.exit(1)
        print(f"    [OK] Case 3 (Missing Image Line) passed: Caught expected fail-closed error: {e}")

    # Case 4: Swap IMAGE_NAME to sglang-blackwell inside vLLM branch -> must fail repo check
    for tf in Path("terraform/manifests/templates").glob("*.template"):
        shutil.copy(tf, templates_dir / tf.name)
    repo_swap_content = real_content.replace("IMAGE_NAME=\"vllm-blackwell\"", "IMAGE_NAME=\"sglang-blackwell\"")
    if repo_swap_content == real_content:
        print("ERROR: Failed to swap IMAGE_NAME in temporary script!", file=sys.stderr)
        sys.exit(1)
    tmp_script.write_text(repo_swap_content, encoding="utf-8")
    try:
        validate_rendered_manifests(str(tmp_script))
        print("ERROR: validate_rendered_manifests() failed to catch swapped IMAGE_NAME!", file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        if "PROVENANCE GATE FAILURE" not in str(e) or "does not end with expected" not in str(e) or "vllm-blackwell" not in str(e):
            print(f"ERROR: Expected PROVENANCE GATE FAILURE for repository name mismatch, got: {e}", file=sys.stderr)
            sys.exit(1)
        print(f"    [OK] Case 4 (Swapped Repo Name) passed: Caught expected fail-closed error: {e}")
'
echo "    [OK] Check 13 passed: Rendered manifest tag verification and fail-closed absence checks verified."

echo "=============================================================================="
echo "=== ALL 13 REMEDIATION CHECKS PASSED ==="
echo "=============================================================================="
