#!/usr/bin/env bash
#
# Self-contained tests for the YAML-parser preflight in deploy.sh,
# sync-secrets.sh and pr.sh.
#
#   bash deploy/test-yaml-parser.sh
#
# Requires python3 (stdlib only) and jq. Runs both scripts against a fixture app
# under two simulated runners:
#
#   broken  — no yq on PATH, and `import yaml` forced to fail via a shadowing
#             yaml.py on PYTHONPATH. This is the state the Norce self-hosted
#             runner has been in since ~2026-07-09.
#   working — yq on PATH, everything normal.
#
# The no-parser cases are the regressions this file exists for: the scripts used to
# exit 1 on the broken runner with an EMPTY log — no error, no annotation, no
# hint — because the python fallback discarded stderr and `set -e` killed the
# script before anything was printed. Twelve consecutive sync-secrets runs
# failed that way before anyone worked out why.
#
# Case 3 is the other half: a redirects file that fails to parse used to
# silently resolve to zero redirects, which the backend reads as "clear them
# all". That deploys green and deletes a partner's live redirects.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# --- fixture app -----------------------------------------------------------
mkdir -p "$WORK/app/.base" "$WORK/noyaml" "$WORK/bin"
printf 'raise ImportError("No module named %s")\n' "'yaml'" > "$WORK/noyaml/yaml.py"

cat > "$WORK/app/.base/config.yaml" <<'EOF'
environments:
  stage:
    replicas: 2
EOF
cat > "$WORK/app/.base/redirects.yaml" <<'EOF'
redirects:
  - from: /old
    to: /new
    status: 301
EOF
cat > "$WORK/app/.base/secrets.yaml" <<'EOF'
environments:
  stage:
    - name: DATABASE_URL
      secret: DATABASE_URL_STAGE
EOF

# jq must stay reachable on the restricted PATH used by the broken runner.
JQ_PATH=$(command -v jq) || { echo "jq is required"; exit 1; }
ln -sf "$JQ_PATH" "$WORK/bin/jq"

# --- runner ----------------------------------------------------------------
# $1 = script to run, $2 = broken|working. Captures combined output; the deploy
# POST is pointed at a closed port so a run that gets that far fails at curl
# rather than touching a real API.
run_case() {
  local script="$1" mode="$2"
  (
    cd "$WORK/app" || exit 1
    export APP=demo ENVIRONMENT=stage IMAGE_TAG=t-123 COMMIT_SHA=deadbeef
    export CONFIG_FILE=.base/config.yaml
    export NGINX_CONFIG_FILE=.base/nginx.yaml
    export REDIRECTS_FILE="${REDIRECTS_FILE:-.base/redirects.yaml}"
    export SECRETS_FILE=.base/secrets.yaml
    export API_URL=http://127.0.0.1:9 API_KEY=x TARGET_ENV=""
    export GITHUB_OUTPUT="$WORK/gh_out"
    : > "$GITHUB_OUTPUT"
    if [ "$mode" = "broken" ]; then
      export PATH="$WORK/bin:/usr/bin:/bin"
      export PYTHONPATH="$WORK/noyaml"
      # The simulation is only meaningful if it really is broken. A yq in
      # /usr/bin, or a PyYAML the shim failed to shadow, would leave every
      # "broken" case silently exercising the happy path and passing for the
      # wrong reason. Assert the premise instead of trusting it.
      if command -v yq >/dev/null 2>&1; then
        echo "BROKEN-MODE SIMULATION INVALID: yq is reachable at $(command -v yq)" >&2
        exit 99
      fi
      if python3 -c "import yaml" 2>/dev/null; then
        echo "BROKEN-MODE SIMULATION INVALID: PyYAML still importable" >&2
        exit 99
      fi
    else
      unset PYTHONPATH
    fi
    bash "$script" 2>&1
  )
}

# Asserts the run exited non-zero AND printed $3. A silent exit 1 fails here —
# which is the entire point of the file.
expect_loud_failure() {
  local name="$1" output="$2" needle="$3" status="$4"
  if [ "$status" -eq 99 ]; then
    echo "  FAIL: $name — $output"
    FAIL=$((FAIL + 1)); return
  fi
  if [ "$status" -eq 0 ]; then
    echo "  FAIL: $name — expected non-zero exit, got 0"
    FAIL=$((FAIL + 1)); return
  fi
  if ! grep -qF "$needle" <<< "$output"; then
    echo "  FAIL: $name — exited $status but never printed '$needle'"
    echo "        (this is the silent-failure regression)"
    echo "        output was: $(wc -l <<< "$output") line(s)"
    FAIL=$((FAIL + 1)); return
  fi
  echo "  ok: $name"
  PASS=$((PASS + 1))
}

expect_contains() {
  local name="$1" output="$2" needle="$3"
  if grep -qF "$needle" <<< "$output"; then
    echo "  ok: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name — output did not contain '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== deploy.sh ==="

# 1. The regression. Broken runner must produce a real error, not an empty log.
OUT=$(run_case "$REPO_DIR/deploy/deploy.sh" broken); ST=$?
expect_loud_failure "no parser -> loud, actionable failure" "$OUT" "NO YAML PARSER AVAILABLE" "$ST"
expect_contains "names the missing tools" "$OUT" "yq        MISSING"
expect_contains "emits a GitHub annotation" "$OUT" "::error::No YAML parser"

# 2. yq present: parsing works, script proceeds to the POST.
OUT=$(run_case "$REPO_DIR/deploy/deploy.sh" working); ST=$?
expect_contains "yq present -> redirects parsed" "$OUT" "Found 1 redirects"

# 3. Malformed redirects must stop the deploy, not silently clear them.
cp "$WORK/app/.base/redirects.yaml" "$WORK/redirects.good"
cat > "$WORK/app/.base/redirects.yaml" <<'EOF'
redirects:
  - from: /old
   status: 301
  bad: [unclosed
EOF
OUT=$(run_case "$REPO_DIR/deploy/deploy.sh" working); ST=$?
expect_loud_failure "malformed redirects -> refuses to deploy" "$OUT" "COULD NOT PARSE" "$ST"
if grep -qF "signaling backend to clear any existing redirects" <<< "$OUT"; then
  echo "  FAIL: malformed redirects were treated as 'clear all' (data loss)"
  FAIL=$((FAIL + 1))
else
  echo "  ok: malformed redirects not treated as 'clear all'"
  PASS=$((PASS + 1))
fi
cp "$WORK/redirects.good" "$WORK/app/.base/redirects.yaml"

# 4. No .base/ at all: a runner without yq is fine, nothing needs parsing.
mv "$WORK/app/.base" "$WORK/base-stash"
OUT=$(run_case "$REPO_DIR/deploy/deploy.sh" broken); ST=$?
if grep -qF "NO YAML PARSER AVAILABLE" <<< "$OUT"; then
  echo "  FAIL: demanded a parser with no .base/*.yaml present"
  FAIL=$((FAIL + 1))
else
  echo "  ok: no .base/*.yaml -> no parser required"
  PASS=$((PASS + 1))
fi
mv "$WORK/base-stash" "$WORK/app/.base"

# 5. A CSV-only app needs python3, not yq/PyYAML. Demanding a YAML parser here
#    would block a deploy that works fine (Copilot caught this: the original
#    condition fired on any redirects file, .csv included, while the comment
#    right above it claimed the opposite).
mv "$WORK/app/.base/redirects.yaml" "$WORK/redirects.stash"
cat > "$WORK/app/.base/redirects.csv" <<'EOF'
from,to,status
/old,/new,301
EOF
rm -f "$WORK/app/.base/config.yaml" "$WORK/app/.base/nginx.yaml"
OUT=$(REDIRECTS_FILE=.base/redirects.csv run_case "$REPO_DIR/deploy/deploy.sh" broken); ST=$?
if grep -qF "NO YAML PARSER AVAILABLE" <<< "$OUT"; then
  echo "  FAIL: CSV-only redirects demanded a YAML parser"
  FAIL=$((FAIL + 1))
else
  echo "  ok: CSV-only redirects do not require yq/PyYAML"
  PASS=$((PASS + 1))
fi
rm -f "$WORK/app/.base/redirects.csv"
mv "$WORK/redirects.stash" "$WORK/app/.base/redirects.yaml"
cat > "$WORK/app/.base/config.yaml" <<'EOF'
environments:
  stage:
    replicas: 2
EOF

echo "=== sync-secrets.sh ==="

# 5. The other half of the regression.
OUT=$(run_case "$REPO_DIR/sync-secrets/sync-secrets.sh" broken); ST=$?
expect_loud_failure "no parser -> loud, actionable failure" "$OUT" "NO YAML PARSER AVAILABLE" "$ST"
expect_contains "still writes step outputs on failure" "$(cat "$WORK/gh_out")" "synced_count=0"

# 6. yq present: unchanged behavior.
OUT=$(run_case "$REPO_DIR/sync-secrets/sync-secrets.sh" working); ST=$?
expect_contains "yq present -> reads the mapping" "$OUT" "stage (1 secret(s))"

echo "=== pr.sh ==="

# 7. pr.sh degraded quietly rather than dying: its fallback is guarded with
#    `|| echo "{}"`, so a missing parser produced a PR environment with an
#    empty config and a green run. Must now refuse.
export ACTION=create PR_NUMBER=42
OUT=$(run_case "$REPO_DIR/pr/pr.sh" broken); ST=$?
expect_loud_failure "no parser -> refuses to build an unconfigured PR env" \
  "$OUT" "NO YAML PARSER AVAILABLE" "$ST"
expect_contains "explains the silent-config-loss risk" "$OUT" "empty config"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
