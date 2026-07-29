#!/bin/bash
set -euo pipefail

echo "=============================================================================="
echo "GLM-5.2 Sovereign Enterprise Inference - Automated Validation Suite"
echo "=============================================================================="

# Step 1: ShellCheck Static Analysis
echo "--> 1. Running ShellCheck over scripts/*.sh tests/*.sh..."
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/*.sh tests/*.sh
  echo "    [OK] ShellCheck static analysis completed with zero findings."
else
  echo "    [SKIP] shellcheck not found in PATH."
fi

# Step 2: Python Syntax Compilation
echo "--> 2. Compiling Python source files..."
python3 -m py_compile scripts/*.py benchmarks/*.py tests/*.py
echo "    [OK] All Python files compiled cleanly."

# Step 3: Unit Test Discovery
echo "--> 3. Discovering and running unit tests..."
python3 -m unittest discover -s tests -p "test_*.py"
echo "    [OK] Unit test execution completed."

# Step 4: Full Remediation Test Suite
echo "--> 4. Executing full offline remediation test suite..."
./tests/adv_test_serving_remediation.sh

# Step 5: Byte-Identical Default Render Baseline Check
echo "--> 5. Verifying default manifest render matches origin/main baseline..."
export PROJECT_ID="YOUR_PROJECT_ID"
export INFERENCE_ENGINE="vllm"
export ENGINE_WARMUP_REQUESTS="0"
export ENABLE_SPECULATIVE_DECODING="false"
export ENABLE_EXPERT_PARALLEL="false"
./scripts/03_deploy_workloads.sh --render-only >/dev/null

WORKTREE_DIR=$(mktemp -d)
trap 'rm -rf "${WORKTREE_DIR}"' EXIT

git fetch --depth=1 origin main 2>/dev/null || true
if git worktree add -q "${WORKTREE_DIR}" origin/main 2>/dev/null; then
  cp scripts/config.env "${WORKTREE_DIR}/scripts/config.env" 2>/dev/null || true
  (
    cd "${WORKTREE_DIR}"
    export PROJECT_ID="YOUR_PROJECT_ID"
    export INFERENCE_ENGINE="vllm"
    export ENGINE_WARMUP_REQUESTS="0"
    export ENABLE_SPECULATIVE_DECODING="false"
    export ENABLE_EXPERT_PARALLEL="false"
    ./scripts/03_deploy_workloads.sh --render-only >/dev/null
  )
  diff -u "${WORKTREE_DIR}/terraform/manifests/generated/03-vllm-spot-serving.yaml" terraform/manifests/generated/03-vllm-spot-serving.yaml
  echo "    [OK] Default vLLM render matches origin/main baseline byte-for-byte."
else
  echo "    [WARNING] Could not create origin/main worktree to compare baseline."
fi

# Step 6: 16-Combination Knob Matrix Render & Kubeconform Validation
echo "--> 6. Executing 16-combination knob matrix render and schema validation..."
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
          kubeconform -strict -schema-location default -schema-location 'terraform/manifests/schemas/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json' terraform/manifests/generated/*.yaml >/dev/null
        fi

        # Verify YAML parsing
        python3 -c '
import yaml, glob
for f in glob.glob("terraform/manifests/generated/*.yaml"):
    with open(f) as fh:
        list(yaml.safe_load_all(fh))
'

        # Verify embedded bash syntax
        python3 -c '
import yaml, glob, subprocess, sys
checked_count = 0
for f in glob.glob("terraform/manifests/generated/*.yaml"):
    with open(f) as fh:
        for doc in yaml.safe_load_all(fh):
            if not doc: continue
            kind = doc.get("kind")
            if kind in ["Deployment", "DaemonSet"]:
                containers = doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
                for c in containers:
                    cmd = c.get("command", [])
                    if len(cmd) >= 2 and cmd[:2] in [["/bin/bash", "-c"], ["/bin/sh", "-c"]]:
                        script = cmd[2] if len(cmd) >= 3 else (c.get("args", [])[0] if c.get("args", []) else None)
                        if script:
                            checked_count += 1
                            res = subprocess.run(["bash", "-n"], input=script, text=True, capture_output=True)
                            if res.returncode != 0:
                                c_name = c.get("name", "unknown")
                                sys.stderr.write(f"ERROR: Embedded bash syntax check failed in {f} for container {c_name}\n")
                                sys.exit(1)
if checked_count == 0:
    sys.stderr.write("ERROR: No embedded scripts checked in validate.sh\n")
    sys.exit(1)
'
      done
    done
  done
done
echo "    [OK] 16-combination knob matrix validated successfully."

# Step 7: Benchmark Comparison & README Reproducibility
echo "--> 7. Verifying benchmark comparison script idempotency..."
python3 benchmarks/generate_comparison.py && git diff --exit-code README.md
echo "    [OK] Benchmark comparison output matches README.md cleanly."

echo "=============================================================================="
echo "=== VALIDATION SUITE COMPLETE ==="
echo "=============================================================================="
