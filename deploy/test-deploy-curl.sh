#!/usr/bin/env bash
# test-deploy-curl.sh — Tests for deploy.sh curl error-handling
#
# Three scenarios:
#   1. Mechanism: verifies || captures exit codes under set -euo pipefail
#      (covers exit 28 / timeout without needing a real 180s wait)
#   2. Connection refused (exit 7): deploy.sh exits 1 with friendly error box
#   3. Success (HTTP 200): deploy.sh exits 0 and sets deploy_success=true
#
# Usage: bash deploy/test-deploy-curl.sh
# Exit:  0 if all pass, 1 if any fail.

set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/deploy.sh"

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$label: exit $expected"
  else
    fail "$label: expected exit $expected, got $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label — not found in: $haystack"
  fi
}

assert_file_contains() {
  local label="$1" needle="$2" file="$3"
  if grep -qF "$needle" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — not found in: $(cat "$file" 2>/dev/null || echo '<empty>')"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# SCENARIO 1: Mechanism — || pattern captures any exit code under set -e
#
# The old code was:
#   RESPONSE=$(curl ...) ; CURL_EXIT=$?
# Under set -e this dies before CURL_EXIT=$? on any non-zero exit.
#
# The fix is:
#   CURL_EXIT=0
#   RESPONSE=$(curl ...) || CURL_EXIT=$?
#
# This test proves the pattern works for exit 28 (timeout), exit 7
# (refused), and exit 0 (success) — without needing a real 180s wait.
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 1: curl exit-code capture mechanism under set -euo pipefail"

# 1a: exit 28 (timeout) — the bug that triggered the incident
S1_EXIT=0
(
  set -euo pipefail
  CURL_EXIT=0
  # shellcheck disable=SC2034  # RESULT mirrors what deploy.sh assigns to RESPONSE
  RESULT=$(bash -c 'exit 28') || CURL_EXIT=$?
  [ "$CURL_EXIT" -eq 28 ] || { echo "FAIL: expected 28, got $CURL_EXIT" >&2; exit 1; }
) || S1_EXIT=$?
assert_exit "exit 28 captured (CURL_EXIT=28, script continues)" 0 "$S1_EXIT"

# 1b: exit 7 (connection refused)
S1_EXIT=0
(
  set -euo pipefail
  CURL_EXIT=0
  # shellcheck disable=SC2034
  RESULT=$(bash -c 'exit 7') || CURL_EXIT=$?
  [ "$CURL_EXIT" -eq 7 ] || { echo "FAIL: expected 7, got $CURL_EXIT" >&2; exit 1; }
) || S1_EXIT=$?
assert_exit "exit 7 captured correctly" 0 "$S1_EXIT"

# 1c: exit 0 (success) — default stays 0
S1_EXIT=0
(
  set -euo pipefail
  CURL_EXIT=0
  # shellcheck disable=SC2034
  RESULT=$(bash -c 'echo hello') || CURL_EXIT=$?
  [ "$CURL_EXIT" -eq 0 ] || { echo "FAIL: expected 0, got $CURL_EXIT" >&2; exit 1; }
) || S1_EXIT=$?
assert_exit "exit 0 stays 0 on success (CURL_EXIT unchanged)" 0 "$S1_EXIT"

# ──────────────────────────────────────────────────────────────────────
# SCENARIO 2: Integration — connection refused (curl exit 7)
#
# Point deploy.sh at a port with no listener.  The script must:
#   • exit 1 (not exit 7)
#   • print the "DEPLOY REQUEST FAILED" error box
#   • print the "Connection refused" branch message
#   • set deploy_success=false in GITHUB_OUTPUT
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 2: deploy.sh with connection-refused API (curl exit 7)"

FREE_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)")
GH_OUT=$(mktemp)
DEPLOY_OUT=$(mktemp)
SCENARIO2_EXIT=0

env -i \
  HOME="$HOME" \
  PATH="$PATH" \
  APP=test-app \
  ENVIRONMENT=stage \
  IMAGE_TAG=sha-abc123 \
  COMMIT_SHA=abc123 \
  CONFIG_FILE=/nonexistent-config.yaml \
  API_URL="http://127.0.0.1:${FREE_PORT}" \
  API_KEY=test-key \
  GITHUB_OUTPUT="$GH_OUT" \
  ENABLE_HEALTH_PROBE=false \
  USE_NOPROXY=false \
  bash "$DEPLOY_SH" > "$DEPLOY_OUT" 2>&1 || SCENARIO2_EXIT=$?

assert_exit "exit code 1 (not 7 — script handled the error)" 1 "$SCENARIO2_EXIT"
assert_file_contains "error box printed" "DEPLOY REQUEST FAILED" "$DEPLOY_OUT"
assert_file_contains "connection-refused message present" "Connection refused" "$DEPLOY_OUT"
assert_file_contains "deploy_success=false in GITHUB_OUTPUT" "deploy_success=false" "$GH_OUT"

rm -f "$GH_OUT" "$DEPLOY_OUT"

# ──────────────────────────────────────────────────────────────────────
# SCENARIO 3: Integration — success (HTTP 200)
#
# Spin a minimal HTTP server that returns a valid deploy-success JSON.
# deploy.sh must:
#   • exit 0
#   • set deploy_success=true in GITHUB_OUTPUT
#   • set namespace=partnersense-test-app-stage
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 3: deploy.sh with successful API response (HTTP 200)"

MOCK_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)")

python3 - "$MOCK_PORT" <<'PYEOF' &
import http.server, json, sys

PORT = int(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        content_len = int(self.headers.get('Content-Length', 0))
        self.rfile.read(content_len)
        resp = json.dumps({
            'data': {
                'success': True,
                'namespace': 'partnersense-test-app-stage',
                'message': 'Deployed',
                'gitCommitSha': 'deadbeef',
                'previousImageTag': 'sha-old'
            }
        }).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)
    def log_message(self, fmt, *args): pass

server = http.server.HTTPServer(('127.0.0.1', PORT), Handler)
server.serve_forever()
PYEOF
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT

# Give the server a moment to bind
sleep 0.3

GH_OUT=$(mktemp)
DEPLOY_OUT=$(mktemp)
SCENARIO3_EXIT=0

env -i \
  HOME="$HOME" \
  PATH="$PATH" \
  APP=test-app \
  ENVIRONMENT=stage \
  IMAGE_TAG=sha-abc123 \
  COMMIT_SHA=abc123 \
  CONFIG_FILE=/nonexistent-config.yaml \
  API_URL="http://127.0.0.1:${MOCK_PORT}" \
  API_KEY=test-key \
  GITHUB_OUTPUT="$GH_OUT" \
  ENABLE_HEALTH_PROBE=false \
  USE_NOPROXY=false \
  bash "$DEPLOY_SH" > "$DEPLOY_OUT" 2>&1 || SCENARIO3_EXIT=$?

assert_exit "exit code 0 (success)" 0 "$SCENARIO3_EXIT"
assert_file_contains "deploy_success=true in GITHUB_OUTPUT" "deploy_success=true" "$GH_OUT"
assert_file_contains "namespace set in GITHUB_OUTPUT" "namespace=partnersense-test-app-stage" "$GH_OUT"
assert_file_contains "success message printed" "Deploy submitted" "$DEPLOY_OUT"

rm -f "$GH_OUT" "$DEPLOY_OUT"

# ──────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
