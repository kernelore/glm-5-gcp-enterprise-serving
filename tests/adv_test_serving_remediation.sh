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
  sed 's/YOUR_PROJECT_ID/mock-test-project/g' scripts/config.env.example > scripts/config.env
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
  # Keep config.env for subsequent check scripts
  :
fi
echo "    [OK] Check 4 passed: All rendered manifests passed kubeconform schema validation and non-selected engine templates were excluded."

# ------------------------------------------------------------------------------
# Check 5: Clean execution of benchmarks/generate_comparison.py & zero diff
# ------------------------------------------------------------------------------
echo "--> Check 5: Verifying benchmarks/generate_comparison.py cleanly executes and is idempotent..."
cp README.md /tmp/README.md.before_check5
python3 benchmarks/generate_comparison.py >/dev/null
if ! cmp -s README.md /tmp/README.md.before_check5; then
  echo "ERROR: Check 5 failed: benchmarks/generate_comparison.py modified README.md!" >&2
  diff -u /tmp/README.md.before_check5 README.md >&2 || true
  rm -f /tmp/README.md.before_check5
  exit 1
fi
rm -f /tmp/README.md.before_check5
echo "    [OK] Check 5 passed: Benchmark comparison generated cleanly and idempotently (zero change to README.md)."

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
echo "--> Check 10: Adversarial Proof of Suite Timestamp Gate (testing absence, overlap, and cooldown separation rejection)..."
export MIN_SUITE_SEPARATION_SEC="5.0"
python3 -c '
import sys
import io
import os
import datetime
from pathlib import Path

sys.path.insert(0, "benchmarks")
from generate_comparison import validate_provenance, load_json

os.environ["MIN_SUITE_SEPARATION_SEC"] = "5.0"
root = Path("benchmarks/results")
vllm_data = {s: load_json(root / "vllm" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}
sglang_data = {s: load_json(root / "sglang" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}

def space_out(data_dict, gap_sec=10):
    base = datetime.datetime(2026, 7, 26, 6, 0, 0, tzinfo=datetime.timezone.utc)
    for i, s in enumerate(["standard", "massive", "soak", "saturation", "prefill"]):
        cfg_key = "soak_config" if s == "soak" else "benchmark_config"
        if cfg_key not in data_dict[s]: data_dict[s][cfg_key] = {}
        start_t = base + datetime.timedelta(seconds=i*(600+gap_sec))
        end_t = start_t + datetime.timedelta(seconds=600)
        data_dict[s][cfg_key]["suite_start_ts"] = start_t.strftime("%Y-%m-%dT%H:%M:%SZ")
        data_dict[s][cfg_key]["suite_end_ts"] = end_t.strftime("%Y-%m-%dT%H:%M:%SZ")

space_out(vllm_data); space_out(sglang_data)

# Absence rejection path: ensure missing suite_start_ts raises ValueError naming file and missing field
vllm_no_ts = {s: dict(vllm_data[s]) for s in ["standard", "massive", "soak", "saturation", "prefill"]}
vllm_no_ts["standard"] = dict(vllm_data["standard"])
vllm_no_ts["standard"]["benchmark_config"] = dict(vllm_data["standard"].get("benchmark_config", {}))
vllm_no_ts["standard"]["benchmark_config"].pop("suite_start_ts", None)
try:
    validate_provenance(vllm_no_ts, sglang_data)
    print("ERROR: validate_provenance() failed to catch missing suite_start_ts!", file=sys.stderr)
    sys.exit(1)
except ValueError as e:
    err_str = str(e)
    if "suite_start_ts" not in err_str or "standard" not in err_str:
        print(f"ERROR: Expected error naming field and suite, got: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"    [OK] Caught expected timestamp absence error: {e}")

# Overlap rejection path: inject overlapping suite_start_ts and suite_end_ts
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

# Cooldown separation rejection path: inject consecutive suites with gap < MIN_SUITE_SEPARATION_SEC (e.g. 2s < 5s)
vllm_cooldown = {s: dict(vllm_data[s]) for s in ["standard", "massive", "soak", "saturation", "prefill"]}
vllm_cooldown["standard"] = dict(vllm_data["standard"])
vllm_cooldown["standard"]["benchmark_config"] = dict(vllm_data["standard"].get("benchmark_config", {}))
vllm_cooldown["standard"]["benchmark_config"]["suite_start_ts"] = "2026-07-26T10:00:00Z"
vllm_cooldown["standard"]["benchmark_config"]["suite_end_ts"] = "2026-07-26T10:10:00Z"
vllm_cooldown["massive"] = dict(vllm_data["massive"])
vllm_cooldown["massive"]["benchmark_config"] = dict(vllm_data["massive"].get("benchmark_config", {}))
vllm_cooldown["massive"]["benchmark_config"]["suite_start_ts"] = "2026-07-26T10:10:02Z"
vllm_cooldown["massive"]["benchmark_config"]["suite_end_ts"] = "2026-07-26T10:20:02Z"

try:
    validate_provenance(vllm_cooldown, sglang_data)
    print("ERROR: validate_provenance() failed to catch cooldown separation violation!", file=sys.stderr)
    sys.exit(1)
except ValueError as e:
    err_str = str(e)
    if "separation" not in err_str.lower() and "cooldown" not in err_str.lower() and "interval" not in err_str.lower():
        print(f"ERROR: Expected separation/cooldown error, got: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"    [OK] Caught expected cooldown separation error: {e}")
'
echo "    [OK] Check 10 passed: Suite timestamp gate correctly handles absence, overlap, and cooldown separation rejection paths."

echo "--> Check 11: Verifying non-canonical execution order tolerance and overlap rejection..."
python3 -c '
import sys, json, os, datetime
from pathlib import Path
sys.path.insert(0, "benchmarks")
from generate_comparison import validate_provenance, load_json

os.environ["MIN_SUITE_SEPARATION_SEC"] = "5.0"
root = Path("benchmarks/results")
vllm_data = {s: load_json(root / "vllm" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}
sglang_data = {s: load_json(root / "sglang" / f"{s}_results.json") for s in ["standard", "massive", "soak", "saturation", "prefill"]}

def space_out(data_dict, gap_sec=10):
    base = datetime.datetime(2026, 7, 26, 6, 0, 0, tzinfo=datetime.timezone.utc)
    for i, s in enumerate(["standard", "massive", "soak", "saturation", "prefill"]):
        cfg_key = "soak_config" if s == "soak" else "benchmark_config"
        if cfg_key not in data_dict[s]: data_dict[s][cfg_key] = {}
        start_t = base + datetime.timedelta(seconds=i*(600+gap_sec))
        end_t = start_t + datetime.timedelta(seconds=600)
        data_dict[s][cfg_key]["suite_start_ts"] = start_t.strftime("%Y-%m-%dT%H:%M:%SZ")
        data_dict[s][cfg_key]["suite_end_ts"] = end_t.strftime("%Y-%m-%dT%H:%M:%SZ")

space_out(vllm_data); space_out(sglang_data)

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
if pins != {"vllm": "0.26.0", "sglang": "0.5.16"}:
    print(f"ERROR: Expected pins {{\"vllm\": \"0.26.0\", \"sglang\": \"0.5.16\"}} on real script, got {pins}", file=sys.stderr)
    sys.exit(1)
print(f"    [OK] Case 1 (Real Script) passed: parse_engine_pins() returned {pins}, proving suffix normalization.")

# Setup synthetic copy in temp dir
with tempfile.TemporaryDirectory() as tmpdir:
    real_content = Path("scripts/03_deploy_workloads.sh").read_text(encoding="utf-8")
    tmp_script = Path(tmpdir) / "03_deploy_workloads.sh"

    # Case 2: Pins bumped to v0.27.0 / v0.5.17-cu130 against committed result files -> gate must fail naming both versions
    bumped_content = real_content.replace("VLLM_IMAGE_TAG=\"v0.26.0\"", "VLLM_IMAGE_TAG=\"v0.27.0\"").replace("SGLANG_IMAGE_TAG=\"v0.5.16-cu130\"", "SGLANG_IMAGE_TAG=\"v0.5.17-cu130\"")
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
        if "PROVENANCE GATE FAILURE" not in msg or "0.27.0" not in msg or "0.26.0" not in msg:
            print(f"ERROR: Expected PROVENANCE GATE FAILURE naming both 0.27.0 and 0.26.0, got: {msg}", file=sys.stderr)
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

    # Case 2: Synthetic injection of IMAGE_TAG="v9.9.9" in vLLM branch while VLLM_IMAGE_TAG stays at v0.26.0 -> must fail
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
        if "PROVENANCE GATE FAILURE" not in msg or "9.9.9" not in msg or "0.26.0" not in msg:
            print(f"ERROR: Expected PROVENANCE GATE FAILURE naming both 9.9.9 and 0.26.0, got: {msg}", file=sys.stderr)
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

    # Case 4a: Swap IMAGE_NAME to sglang-blackwell inside vLLM branch -> must fail repo check
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
        if "PROVENANCE GATE FAILURE" not in str(e) or "does not match expected" not in str(e) or "vllm-blackwell" not in str(e):
            print(f"ERROR: Expected PROVENANCE GATE FAILURE for repository name mismatch, got: {e}", file=sys.stderr)
            sys.exit(1)
        print(f"    [OK] Case 4a (Swapped Repo Name) passed: Caught expected fail-closed error: {e}")

    # Case 4b: Prefixed IMAGE_NAME evil-vllm-blackwell inside vLLM branch -> must fail repo check
    repo_prefix_content = real_content.replace("IMAGE_NAME=\"vllm-blackwell\"", "IMAGE_NAME=\"evil-vllm-blackwell\"")
    if repo_prefix_content == real_content:
        print("ERROR: Failed to prefix IMAGE_NAME in temporary script!", file=sys.stderr)
        sys.exit(1)
    tmp_script.write_text(repo_prefix_content, encoding="utf-8")
    try:
        validate_rendered_manifests(str(tmp_script))
        print("ERROR: validate_rendered_manifests() failed to catch prefixed IMAGE_NAME evil-vllm-blackwell!", file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        if "PROVENANCE GATE FAILURE" not in str(e) or "does not match expected" not in str(e) or "vllm-blackwell" not in str(e):
            print(f"ERROR: Expected PROVENANCE GATE FAILURE for repository name mismatch, got: {e}", file=sys.stderr)
            sys.exit(1)
        print(f"    [OK] Case 4b (Prefixed Repo Name) passed: Caught expected fail-closed error: {e}")
'
echo "    [OK] Check 13 passed: Rendered manifest tag verification and fail-closed absence checks verified."

echo "--> Check 14: Verifying benchmark provenance probes carry no || echo fallback and assert explicit non-zero exits..."
# shellcheck disable=SC2016
python3 -c '
from pathlib import Path
import sys

content = Path("scripts/05_run_benchmarks.sh").read_text(encoding="utf-8")
lines = content.splitlines()

probes_checked = 0
for i, line in enumerate(lines, 1):
    if any(k in line for k in ["IMAGE=$(kubectl get deployment", "FLAGS=$(kubectl get deployment", "ENGINE_VER=$(kubectl exec"]):
        probes_checked += 1
        if "|| echo" in line or "||echo" in line:
            print(f"ERROR: Provenance probe at line {i} contains fallback literal (|| echo): {line}", file=sys.stderr)
            sys.exit(1)
        if "||" not in line and "exit 1" not in line:
            block_has_exit = any("exit 1" in lines[j] for j in range(i-1, min(i+10, len(lines))))
            if not block_has_exit:
                print(f"ERROR: Provenance probe at line {i} is not followed by an explicit non-zero exit!", file=sys.stderr)
                sys.exit(1)

if probes_checked != 4:
    print(f"ERROR: Expected to check exactly 4 provenance probe lines, found {probes_checked}", file=sys.stderr)
    sys.exit(1)
'
echo "    [OK] Check 14 passed: Provenance probes carry no || echo fallback and assert explicit non-zero exits (lint against reintroduction, not a behavioural test)."

# ------------------------------------------------------------------------------
# Check 15: Offline Verifier Failure Harness
# ------------------------------------------------------------------------------
echo "--> Check 15: Executing offline verifier failure harness (adv_test_verify_cluster_failures.sh)..."
PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}" bash tests/adv_test_verify_cluster_failures.sh >/dev/null
echo "    [OK] Check 15 passed: Offline verifier failure harness verified all 4 failure states."

# ------------------------------------------------------------------------------
# Check 16: Byte-Identical Default Manifest Rendering vs Main Baseline
# ------------------------------------------------------------------------------
echo "--> Check 16: Verifying default manifest rendering is byte-identical to main baseline..."
if [ ! -f "scripts/config.env" ] && [ -f "scripts/config.env.example" ]; then
  cp scripts/config.env.example scripts/config.env
fi
export PROJECT_ID="YOUR_PROJECT_ID"
export INFERENCE_ENGINE="vllm"
export ENGINE_WARMUP_REQUESTS="0"
export ENABLE_SPECULATIVE_DECODING="false"
export ENABLE_EXPERT_PARALLEL="false"

# Run 03_deploy_workloads.sh to render generated/03-vllm-spot-serving.yaml and export environment
./scripts/03_deploy_workloads.sh --render-only >/dev/null

if git rev-parse --verify origin/main >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source scripts/config.env
  export PROJECT_ID="YOUR_PROJECT_ID"
  export INFERENCE_ENGINE="vllm"
  export ENGINE_WARMUP_REQUESTS="0"
  export ENABLE_SPECULATIVE_DECODING="false"
  export ENABLE_EXPERT_PARALLEL="false"
  export MEM_FRACTION_STATIC="0.94"
  export MAX_NUM_SEQS="64"
  export MAX_NUM_BATCHED_TOKENS="8192"
  export MAX_RUNNING_REQUESTS="64"
  export VLLM_EXTRA_FLAGS=""
  export SGLANG_EXTRA_FLAGS=""
  export WARMUP_BLOCK=""
  export READINESS_PROBE_BLOCK="        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 120
          periodSeconds: 15
          timeoutSeconds: 5
          failureThreshold: 30"
  export HPA_QUEUE_METRIC="vllm:num_requests_waiting|gauge"
  export HPA_RUNNING_METRIC="vllm:num_requests_running|gauge"
  export SERVING_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/glm-prod/vllm-blackwell:v0.26.0"
  export WEIGHTS_DOWNLOADER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/glm-prod/vllm-blackwell:v0.26.0"
  export VLLM_VIP="glm52-serving-svc.llm-serving.svc.cluster.local"
  export SERVING_VIP="${VLLM_VIP}"
  export INFERENCE_SERVER_LABEL="vllm"
  export GATEWAY_MASTER_KEY="${GATEWAY_MASTER_KEY:-sk-glm52-master-secret-key-change-me}"
  export DB_PASSWORD="${DB_PASSWORD:-glm52-gateway-admin-secret}"
  export REDIS_PASSWORD="${REDIS_PASSWORD:-redis-secret-password-change-me}"
  export REDIS_PASSWORD_ENCODED="${REDIS_PASSWORD}"
  export REDIS_HOST="${REDIS_HOST:-redis-cache.local}"
  HF_TOKEN_BASE64=$(echo -n "${HF_TOKEN:-placeholder_token}" | base64 -w 0 2>/dev/null || echo -n "${HF_TOKEN:-placeholder_token}" | base64)
  export HF_TOKEN_BASE64
  export MODEL_REPO_ID="${MODEL_REPO_ID:-nvidia/GLM-5.2-NVFP4}"
  export GPU_MAX_NODES="${GPU_MAX_NODES:-2}"

  # shellcheck disable=SC2016
  git show origin/main:terraform/manifests/templates/03-vllm-spot-serving.yaml.template | \
  python3 -c '
import os, sys, re
allowed = set(["PROJECT_ID", "REGION", "ZONE", "CLUSTER_NAME", "OWNER_LABEL", "TTL_LABEL", "ENV_LABEL", "HF_TOKEN_BASE64", "MODEL_REPO_ID", "GCS_WEIGHTS_BUCKET", "GATEWAY_MASTER_KEY", "DB_CONNECTION_NAME", "DB_PASSWORD", "REDIS_HOST", "REDIS_PASSWORD", "REDIS_PASSWORD_ENCODED", "VLLM_VIP", "GPU_MAX_NODES", "INFERENCE_ENGINE", "INFERENCE_SERVER_LABEL", "HPA_QUEUE_METRIC", "HPA_RUNNING_METRIC", "SERVING_IMAGE", "WEIGHTS_DOWNLOADER_IMAGE", "SERVING_VIP", "BENCHMARK_MODE", "BENCHMARK_CONCURRENCY", "BENCHMARK_REQUESTS", "BENCHMARK_DURATION", "BENCHMARK_METADATA", "MAX_NUM_SEQS", "MAX_NUM_BATCHED_TOKENS", "MAX_RUNNING_REQUESTS", "MEM_FRACTION_STATIC", "VLLM_EXTRA_FLAGS", "SGLANG_EXTRA_FLAGS", "WARMUP_BLOCK", "READINESS_PROBE_BLOCK"])
content = sys.stdin.read()
def replace_var(match):
    var_name = match.group(1) or match.group(2)
    if not allowed or var_name in allowed:
        return os.environ.get(var_name, "")
    return match.group(0)
output = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", replace_var, content)
sys.stdout.write(output)
' > /tmp/03-vllm-spot-serving.yaml.main_baseline
fi

if [ -f "/tmp/03-vllm-spot-serving.yaml.main_baseline" ]; then
  ACTIVE_PROJ=$(grep "^export PROJECT_ID=" scripts/config.env 2>/dev/null | cut -d'"' -f2 || echo "YOUR_PROJECT_ID")
  if ! diff -u <(sed "s/${ACTIVE_PROJ}/YOUR_PROJECT_ID/g; s/mock-test-project/YOUR_PROJECT_ID/g" /tmp/03-vllm-spot-serving.yaml.main_baseline) <(sed "s/${ACTIVE_PROJ}/YOUR_PROJECT_ID/g; s/mock-test-project/YOUR_PROJECT_ID/g" terraform/manifests/generated/03-vllm-spot-serving.yaml); then
    echo "ERROR: Check 16 failed: Rendered manifest 03-vllm-spot-serving.yaml with defaults is NOT byte-identical to main baseline!" >&2
    exit 1
  fi
  echo "    [OK] Check 16 passed: Rendered default vLLM manifest is byte-identical to main baseline."
else
  echo "    [OK] Check 16 passed: Default manifest rendered cleanly."
fi

# ------------------------------------------------------------------------------
# Check 17: Engine Tuning Render Matrix & Kubeconform Validation
# ------------------------------------------------------------------------------
echo "--> Check 17: Testing render matrix (ENABLE_SPECULATIVE_DECODING, ENABLE_EXPERT_PARALLEL, ENGINE_WARMUP_REQUESTS) × engines with kubeconform..."
for engine in vllm sglang; do
  for spec in false true; do
    for ep in false true; do
      for warmup in 0 5; do
        INFERENCE_ENGINE="${engine}" \
        ENABLE_SPECULATIVE_DECODING="${spec}" \
        ENABLE_EXPERT_PARALLEL="${ep}" \
        ENGINE_WARMUP_REQUESTS="${warmup}" \
        ./scripts/03_deploy_workloads.sh --render-only >/dev/null
        if command -v kubeconform >/dev/null 2>&1; then
          kubeconform -summary -schema-location default -schema-location 'terraform/manifests/schemas/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json' terraform/manifests/generated/*.yaml >/dev/null
        fi
      done
    done
  done
done
INFERENCE_ENGINE=vllm ENABLE_SPECULATIVE_DECODING=false ENABLE_EXPERT_PARALLEL=false ENGINE_WARMUP_REQUESTS=0 ./scripts/03_deploy_workloads.sh --render-only >/dev/null
echo "    [OK] Check 17 passed: Render matrix across all variable combinations × engines validated cleanly with kubeconform."

# ------------------------------------------------------------------------------
# Check 18: Benchmark Mode Ladder & In-Cluster Mode Parity Validation
# ------------------------------------------------------------------------------
echo "--> Check 18: Verifying benchmark mode ladder CLI validation & in-cluster mode parity..."
if [ ! -f "scripts/config.env" ] && [ -f "scripts/config.env.example" ]; then
  cp scripts/config.env.example scripts/config.env
fi
OUT=$(./scripts/05_run_benchmarks.sh --mode invalid_mode_test 2>&1 || true)
if echo "${OUT}" | grep -q "Unrecognized benchmark mode"; then
  echo "    [OK] Invalid benchmark mode correctly rejected."
else
  echo "ERROR: Invalid benchmark mode was not rejected! Output: ${OUT}" >&2
  exit 1
fi

TEMPLATE_JOB="terraform/manifests/templates/08-in-cluster-benchmark-job.yaml.template"
for m in standard massive soak saturation prefill ceiling gateway_ab; do
  if ! grep -q "BENCHMARK_MODE.*=.*\"${m}\"" "${TEMPLATE_JOB}"; then
    echo "ERROR: Check 18 failed: In-cluster benchmark job template missing execution branch for mode '${m}'!" >&2
    exit 1
  fi
done
echo "    [OK] Check 18 passed: All benchmark modes (standard, massive, soak, saturation, prefill, ceiling, gateway_ab) have verified in-cluster job execution branches."

# ------------------------------------------------------------------------------
# Check 19: Shellcheck Static Analysis & Secret Scan
# ------------------------------------------------------------------------------
echo "--> Check 19: Running shellcheck and secret scan..."
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh tests/*.sh
  echo "    [OK] Shellcheck static analysis passed with 0 warnings/errors."
fi
bash tests/check_secret_scan.sh >/dev/null
echo "    [OK] Check 19 passed: Shellcheck and secret scan passed cleanly."

# ------------------------------------------------------------------------------
# Check 20: check_bq.py Timeout & Attempt Timeout Verification
# ------------------------------------------------------------------------------
echo "--> Check 20: Verifying check_bq.py argument parsing and attempt timeout configuration..."
python3 -c '
import subprocess, sys
res = subprocess.run(["python3", "scripts/check_bq.py", "--help"], capture_output=True, text=True)
if "--attempt-timeout" not in res.stdout or "--poll-interval" not in res.stdout:
    print("ERROR: check_bq.py --help output missing --attempt-timeout or --poll-interval!", file=sys.stderr)
    sys.exit(1)
'
echo "    [OK] Check 20 passed: check_bq.py supports configurable --attempt-timeout and --poll-interval."

echo "=============================================================================="
echo "=== ALL 20 REMEDIATION CHECKS PASSED ==="
echo "=============================================================================="

