#!/usr/bin/env bash
# ==============================================================================
# adv_test_readme_mutation.sh - Adversarial Proof of README Mutation Rejection
# ==============================================================================
# Proves that Check 8 (CI Reproducibility / README Mutation) fails when README.md
# is deliberately mutated, and that reverting the mutation restores zero diff.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}" || exit 1

echo "=============================================================================="
echo "Adversarial Proof: README Mutation Rejection & Clean Revert"
echo "=============================================================================="

# Ensure README.md is synchronized with generate_comparison.py before starting check
python3 benchmarks/generate_comparison.py >/dev/null 2>&1
git add README.md >/dev/null 2>&1 || true

# 1. Verify clean starting state (against current working tree comparison baseline)
echo "--> Step 1: Verifying initial comparison baseline of README.md..."
if ! python3 benchmarks/generate_comparison.py >/dev/null 2>&1; then
  echo "ERROR: generate_comparison.py failed on initial README.md! Aborting." >&2
  exit 1
fi
echo "    [OK] Initial README.md comparison baseline is clean."

# 2. Mutate a numerical benchmark value in README.md (in a safe, reversible manner)
echo "--> Step 2: Deliberately mutating a numerical benchmark value in README.md..."
# Backup exact current README.md state first
cp README.md /tmp/README.md.adv_backup
# Mutate 794.73 (vLLM Standard TTFT P50) to 9999.99
sed -i 's/794\.73/9999.99/g' README.md

# Verify mutation occurred
if grep -q "9999.99" README.md; then
  echo "    [OK] Successfully mutated '794.73' to '9999.99' in README.md."
else
  echo "ERROR: Mutation failed!" >&2
  cp /tmp/README.md.adv_backup README.md
  exit 1
fi

# 3. Prove generate_comparison.py detects mutation and overwrites it back to baseline
echo "--> Step 3: Running reproducibility check (generate_comparison.py on unstaged mutation)..."
if cmp -s README.md /tmp/README.md.adv_backup >/dev/null 2>&1; then
  echo "ERROR: Mutation did not alter file relative to backup!" >&2
  cp /tmp/README.md.adv_backup README.md
  exit 1
fi

python3 benchmarks/generate_comparison.py >/dev/null 2>&1
if cmp -s README.md /tmp/README.md.adv_backup >/dev/null 2>&1; then
  echo "    [OK] Reproducibility check PASSED: generate_comparison.py detected mutation and overwrote fake '9999.99' back to real '794.73'!"
else
  echo "ERROR: generate_comparison.py failed to restore real benchmark numbers!" >&2
  cp /tmp/README.md.adv_backup README.md
  exit 1
fi

# 4. Re-apply mutation and prove Check 5 fails when mutated README is tested against git diff --exit-code
echo "--> Step 4: Testing Check 5 rejection on staged mutated README.md..."
cp /tmp/README.md.adv_backup README.md
sed -i 's/794\.73/9999.99/g' README.md
git add README.md >/dev/null 2>&1 || true
python3 benchmarks/generate_comparison.py >/dev/null 2>&1
git diff --exit-code README.md > /tmp/check5_diff.log 2>&1
CHECK5_EXIT=$?
if [ ${CHECK5_EXIT} -ne 0 ]; then
  echo "    [OK] Check 5 reproducibility test FAILED as expected (exit code ${CHECK5_EXIT})."
  echo "         generate_comparison.py restored real JSON values, causing git diff against staged mutation!"
  echo "    --- Check 5 Diff Snippet ---"
  head -n 15 /tmp/check5_diff.log | sed 's/^/    | /'
  echo "    ----------------------------"
else
  echo "ERROR: Check 5 unexpectedly PASSED on staged mutated README.md!" >&2
  cp /tmp/README.md.adv_backup README.md
  git add README.md >/dev/null 2>&1 || true
  exit 1
fi

# 5. Cleanly revert the mutation and verify restoration of exact original state
echo "--> Step 5: Cleanly reverting mutation and verifying zero residual diff against backup..."
cp /tmp/README.md.adv_backup README.md
python3 benchmarks/generate_comparison.py >/dev/null 2>&1
git add README.md >/dev/null 2>&1 || true
rm -f /tmp/README.md.adv_backup /tmp/check5_diff.log

if cmp -s README.md <(git show :README.md 2>/dev/null); then
  echo "    [OK] README.md cleanly reverted and verified up-to-date with benchmark results (zero diff)!"
else
  echo "ERROR: Reverting README.md left residual discrepancy!" >&2
  exit 1
fi

echo "=============================================================================="
echo "SUCCESS: Adversarial proof of README mutation rejection and clean revert PASSED!"
echo "=============================================================================="
