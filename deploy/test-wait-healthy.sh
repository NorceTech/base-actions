#!/usr/bin/env bash
#
# Self-contained tests for wait-healthy.sh.
#
#   bash deploy/test-wait-healthy.sh
#
# Requires python3 (stdlib only), jq and curl. Starts a mock Base API that serves a
# scripted sequence of /api/v1/deploy/status responses, then runs wait-healthy.sh
# against it with the grace periods scaled down so a case finishes in seconds.
#
# The cases that matter are 1 and 5: they are the two ways this action used to lie to
# a partner — calling a slow ArgoCD reconcile a failed deploy, and calling someone
# else's paused canary a staged release.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT

PASS=0
FAIL=0

cat > "$WORK/mock-api.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# argv[1] = path to a JSON file holding a list of response bodies.
# Each request advances one step; the final entry repeats forever.
STEPS = json.load(open(sys.argv[1]))
PORT = int(sys.argv[2])
state = {'i': 0}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        i = min(state['i'], len(STEPS) - 1)
        state['i'] += 1
        body = json.dumps({'data': STEPS[i]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
PYEOF

free_port() {
  python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"
}

# run_case <name> <steps-json> <expect-exit> <expect-health-status>
run_case() {
  local name="$1" steps="$2" want_exit="$3" want_health="$4"
  local port; port=$(free_port)

  echo "$steps" > "$WORK/steps.json"
  python3 "$WORK/mock-api.py" "$WORK/steps.json" "$port" &
  SERVER_PID=$!

  # Wait for the mock to accept connections rather than sleeping a guessed amount.
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null "http://127.0.0.1:$port/"; then break; fi
    sleep 0.1
  done

  : > "$WORK/gh_output"
  local out rc
  out=$(
    API_URL="http://127.0.0.1:$port" \
    API_KEY=test \
    APP=testapp \
    ENVIRONMENT=prod \
    IMAGE_TAG=1118-new \
    NAMESPACE=partner-testapp-prod \
    TIMEOUT=8 \
    POLL_INTERVAL=1 \
    SYNC_GRACE=1 \
    DEGRADED_GRACE=3 \
    GITHUB_OUTPUT="$WORK/gh_output" \
    bash "$SCRIPT_DIR/wait-healthy.sh" 2>&1
  )
  rc=$?

  kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""

  local got_health
  got_health=$(grep '^health_status=' "$WORK/gh_output" | tail -1 | cut -d= -f2-)

  if [ "$rc" == "$want_exit" ] && [ "$got_health" == "$want_health" ]; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    echo "        want exit=$want_exit health=$want_health"
    echo "        got  exit=$rc health=$got_health"
    echo "$out" | sed 's/^/        | /'
    FAIL=$((FAIL + 1))
  fi
}

echo "wait-healthy.sh"

# 1. THE REGRESSION. Base aborted the previous paused canary, so the app reports
#    Degraded on the OLD tag while ArgoCD takes minutes to reconcile ours. This must
#    NOT be reported as a failed deployment. It may only ever end in Timeout.
run_case "slow ArgoCD + stale Degraded never reports Degraded" \
  '[{"healthStatus":"Degraded","syncStatus":"OutOfSync","imageTag":"1115-old","imageTags":["1115-old"]}]' \
  1 "Timeout"

# 2. A genuinely broken release still fails fast: our tag IS live and crash-looping.
run_case "crash-loop on our own tag still fails fast" \
  '[{"healthStatus":"Degraded","syncStatus":"Synced","imageTag":"1118-new","imageTags":["1118-new"]}]' \
  1 "Degraded"

# 3. Slow reconcile that eventually lands is a success, not a timeout.
run_case "stale Degraded then our tag goes Healthy" \
  '[{"healthStatus":"Degraded","syncStatus":"OutOfSync","imageTag":"1115-old","imageTags":["1115-old"]},
    {"healthStatus":"Degraded","syncStatus":"OutOfSync","imageTag":"1115-old","imageTags":["1115-old"]},
    {"healthStatus":"Healthy","syncStatus":"Synced","imageTag":"1118-new","imageTags":["1118-new"]}]' \
  0 "Healthy"

# 4. Our canary is staged and paused - needs promotion, reported green.
run_case "our paused canary reports Suspended" \
  '[{"healthStatus":"Suspended","syncStatus":"Synced","imageTag":"1118-new","imageTags":["1115-old","1118-new"]}]' \
  0 "Suspended"

# 5. THE FALSE GREEN. A canary is paused but it is the PREVIOUS release - the abort
#    failed and nothing of ours reached the cluster. Reporting "staged, go promote"
#    here would be a lie.
run_case "someone else's paused canary is not our release" \
  '[{"healthStatus":"Suspended","syncStatus":"Synced","imageTag":"1115-old","imageTags":["1115-old"]}]' \
  1 "Timeout"

# 6. Backwards compatibility: an API that predates imageTags falls back to equality.
run_case "falls back to imageTag when imageTags is absent" \
  '[{"healthStatus":"Healthy","syncStatus":"Synced","imageTag":"1118-new"}]' \
  0 "Healthy"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
