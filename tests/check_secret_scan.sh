#!/usr/bin/env bash
# Secret scan: single source of truth, invoked by both CI and the local
# remediation suite so the two can never drift apart.
#
# Scans git-tracked content only. benchmarks/telemetry_sanitizer.py is the one
# file-level exclusion: it must carry these patterns as regex literals, and its
# behaviour is covered by tests/test_telemetry_sanitizer.py.
set -uo pipefail

echo "FORBIDDEN_PROJECT_ID length: ${#FORBIDDEN_PROJECT_ID}"

cd "$(dirname "$0")/.." || exit 1
EXCLUDE=':(exclude)benchmarks/telemetry_sanitizer.py'
FAIL=0

echo "Scanning git-tracked files for credentials, home paths and project IDs..."

if git grep -nE 'sk-[a-zA-Z0-9-]{16,}' -- "$EXCLUDE" \
   | grep -vE 'sk-glm52-master-secret-key-change-me|sk-glm52-quota-test-'; then
  echo "ERROR: Found potential exposed API keys!" >&2; FAIL=1
fi

if git grep -nE '/usr/local/google/home/[a-zA-Z0-9_-]|/home/[a-zA-Z0-9_-]' -- "$EXCLUDE" \
   | grep -vE '/home/(kubernetes|runner)/'; then
  echo "ERROR: Found local filesystem home paths in repository!" >&2; FAIL=1
fi

# Primary project-ID guard: shape-based, so it needs no repository configuration
# and cannot be switched off by a missing variable. Matches GCP's
# <name>-<6 digits> project-ID form. The YOUR_PROJECT_ID placeholder does not match.
if git grep -nE '[a-z][a-z0-9-]{3,26}-[0-9]{6}([^0-9]|$)' -- "$EXCLUDE"; then
  echo "ERROR: Found a GCP-project-ID-shaped literal!" >&2; FAIL=1
fi

# Secondary exact-value guard. Skipping when unset is not fail-open here: the
# shape guard above already covers this repo's project ID unconditionally.
if [ -n "${FORBIDDEN_PROJECT_ID:-}" ]; then
  if git grep -nF -e "${FORBIDDEN_PROJECT_ID}" -- "$EXCLUDE"; then
    echo "ERROR: Found hardcoded GCP project ID!" >&2; FAIL=1
  fi
else
  echo "NOTE: FORBIDDEN_PROJECT_ID unset; exact-value check skipped (shape check still enforced)."
fi

[ "$FAIL" -eq 0 ] || { echo "SECRET SCAN FAILED." >&2; exit 1; }
echo "Secret scan passed cleanly."
