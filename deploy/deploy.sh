#!/usr/bin/env bash
set -euo pipefail

# Which release of this action is actually executing.
#
# Partners pin the moving `v1` tag — that is deliberate, we cannot ask them to bump a
# pin on every minor. The cost is that a runner which caches
# `_work/_actions/<owner>/<repo>/v1` can keep serving an old release long after `v1`
# has moved. On 2026-08-21 a partner ran v1.0.x code while `v1` had pointed at v1.1.1
# for 16 days, and it took timing forensics against a mock API to establish that.
# Printing the version makes that a one-line read in the job log instead.
#
# VERSION is written into the published tree by the release workflow, so an
# unreleased/internal checkout correctly reports "dev".
action_version() {
  local vf="${GITHUB_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../VERSION"
  if [ -f "$vf" ]; then
    cat "$vf"
  else
    echo "dev"
  fi
}

echo "base-actions $(action_version) (ref: ${GITHUB_ACTION_REF:-unknown})"

# Validate environment name
ALLOWED_ENVS="dev test stage prod"
validate_env() {
  local env="$1"
  local label="$2"
  # Allow pr-123, preview-42 etc. (ephemeral preview environments, digit after prefix)
  if [[ "$env" =~ ^(pr-|preview-|feature-|branch-)[0-9] ]]; then
    return 0
  fi
  for allowed in $ALLOWED_ENVS; do
    if [ "$env" = "$allowed" ]; then
      return 0
    fi
  done
  echo ""
  echo "::error::Invalid ${label} name: '${env}'"
  echo ""
  echo "╔══════════════════════════════════════════════════════"
  echo "║ ❌ INVALID ENVIRONMENT NAME: '${env}'"
  echo "╠══════════════════════════════════════════════════════"
  echo "║"
  echo "║ Allowed environment names:"
  echo "║   dev, test, stage, prod, pr-*"
  echo "║"
  echo "║ Common mistakes:"
  echo "║   staging  → use 'stage' instead"
  echo "║   production → use 'prod' instead"
  echo "║   development → use 'dev' instead"
  echo "║"
  echo "║ Check your workflow file or .base/config.yaml"
  echo "╚══════════════════════════════════════════════════════"
  exit 1
}

validate_env "$ENVIRONMENT" "environment"

# Verify a YAML parser exists before any .base/*.yaml is read.
#
# Every YAML read below is `yq` with a `python3 -c "import yaml"` fallback.
# Three of those fallbacks used to discard stderr and carry no `|| ...` guard,
# so on a runner with neither yq nor PyYAML `set -e` killed the script the
# moment one ran: exit 1, no stdout, no stderr, no annotation. Deploys failed
# that way on self-hosted runners from 2026-07-09 with a completely empty step
# log. Those call sites are guarded now; this preflight is what turns the
# remaining "no parser at all" case into a message instead of an exit code.
#
# The guard belongs here rather than on each call site: a missing parser is a
# runner problem, and it should be reported once, up front, in the operator's
# terms — not as an opaque exit code from whichever read happened to be first.
require_yaml_parser() {
  local what="$1"
  if command -v yq &> /dev/null; then
    return 0
  fi
  if command -v python3 &> /dev/null && python3 -c "import yaml" 2>/dev/null; then
    return 0
  fi
  # Report the version only when python3 actually exists, otherwise the probe
  # itself prints "command not found" above the box.
  local pyyaml="MISSING"
  if command -v python3 &> /dev/null; then
    pyyaml=$(python3 -c 'import yaml; print(yaml.__version__)' 2>/dev/null || echo "MISSING")
  fi
  # The box prints this runner's arch, so the install line has to match it —
  # handing an arm64 runner an amd64 URL makes the "Fix" actively wrong.
  local yq_arch
  case "$(uname -m)" in
    x86_64) yq_arch=amd64 ;;
    aarch64|arm64) yq_arch=arm64 ;;
    *) yq_arch="<your-arch>" ;;
  esac
  echo ""
  echo "::error::No YAML parser on this runner — cannot read ${what}"
  echo ""
  echo "╔══════════════════════════════════════════════════════"
  echo "║ ❌ NO YAML PARSER AVAILABLE"
  echo "╠══════════════════════════════════════════════════════"
  echo "║"
  echo "║ Reading ${what} needs one of:"
  echo "║   • yq            (preferred)"
  echo "║   • python3 + PyYAML"
  echo "║"
  echo "║ On this runner:"
  echo "║   yq        $(command -v yq || echo 'MISSING')"
  echo "║   python3   $(command -v python3 || echo 'MISSING')"
  echo "║   PyYAML    ${pyyaml}"
  echo "║   arch      $(uname -m)"
  echo "║"
  echo "║ 📋 Fix: install yq on the runner image, or add a step"
  echo "║    before this action:"
  echo "║"
  echo "║      - name: Ensure yq is available"
  echo "║        run: |"
  echo "║          command -v yq >/dev/null && exit 0"
  echo "║          mkdir -p \"\$RUNNER_TEMP/bin\""
  echo "║          curl -fsSL -o \"\$RUNNER_TEMP/bin/yq\" \\"
  echo "║            https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}"
  echo "║          chmod +x \"\$RUNNER_TEMP/bin/yq\""
  echo "║          echo \"\$RUNNER_TEMP/bin\" >> \"\$GITHUB_PATH\""
  echo "║"
  echo "║ That snippet is a stopgap — it runs an unpinned binary"
  echo "║ fetched at job time. For anything permanent, pin the"
  echo "║ release tag and check it against the SHA-256 column of"
  echo "║ that release's 'checksums' asset before chmod +x."
  echo "║"
  echo "║ GitHub-hosted runners ship yq preinstalled. Self-hosted"
  echo "║ runners often do not — that is the usual cause here."
  echo "╚══════════════════════════════════════════════════════"
  exit 1
}

# Runtime profile knobs (set by action.yml; defaults match public behavior).
# ENABLE_HEALTH_PROBE: when 'true', run a 5s GET /health pre-flight before the
# deploy POST to surface DNS/proxy/connectivity errors with an actionable hint.
# USE_NOPROXY: when 'true', pass `--noproxy '*'` to the deploy curl so it
# bypasses any configured HTTP(S) proxy. Internal callers leave this off
# because the internal API is only reachable through the corporate proxy.
ENABLE_HEALTH_PROBE="${ENABLE_HEALTH_PROBE:-false}"
USE_NOPROXY="${USE_NOPROXY:-true}"

# A YAML read only happens when one of these files is present, so the parser
# check is conditional too — an app with no .base/ directory still deploys on a
# runner without yq.
#
# redirects_file may legitimately point at a .csv (action.yml allows it), and
# CSV parsing needs python3 but NOT yq or PyYAML. Demanding a YAML parser for a
# CSV-only app would block a deploy that would otherwise work, so the redirects
# path only counts when it is actually YAML. The CSV branches check python3 at
# their own call site instead.
NEEDS_YAML_PARSER=false
if [ -f "$CONFIG_FILE" ] || [ -f "${NGINX_CONFIG_FILE:-}" ]; then
  NEEDS_YAML_PARSER=true
fi
case "${REDIRECTS_FILE:-.base/redirects.yaml}" in
  *.csv) ;;
  *)
    if [ -f "${REDIRECTS_FILE:-.base/redirects.yaml}" ]; then
      NEEDS_YAML_PARSER=true
    fi
    ;;
esac
if [ "$NEEDS_YAML_PARSER" = "true" ]; then
  require_yaml_parser "your .base/*.yaml config"
fi

# CSV redirects need python3 (stdlib csv only). Same reasoning as the YAML
# preflight: without this the unguarded parser below dies silently.
require_python3() {
  if command -v python3 &> /dev/null; then
    return 0
  fi
  echo ""
  echo "::error::python3 is required to parse $1 but is not installed on this runner"
  echo ""
  echo "╔══════════════════════════════════════════════════════"
  echo "║ ❌ python3 NOT AVAILABLE"
  echo "╠══════════════════════════════════════════════════════"
  echo "║"
  echo "║ Parsing $1 needs python3 (standard library only)."
  echo "║ Install it on the runner image, or switch to the YAML"
  echo "║ redirects format and install yq instead."
  echo "╚══════════════════════════════════════════════════════"
  exit 1
}

# Read environment config from YAML
CONFIG="{}"
GLOBAL_ENV="[]"

if [ -f "$CONFIG_FILE" ]; then
  if command -v yq &> /dev/null; then
    # Check for config inheritance (e.g., stage inherits from dev)
    INHERITS=$(yq -r ".environments.$ENVIRONMENT.inherits // \"\"" "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$INHERITS" ]; then
      PARENT_CONFIG=$(yq -o=json -I=0 ".environments.$INHERITS // {}" "$CONFIG_FILE")
      CHILD_CONFIG=$(yq -o=json -I=0 ".environments.$ENVIRONMENT // {}" "$CONFIG_FILE")
      # Remove inherits key from child before merging
      CHILD_CONFIG=$(echo "$CHILD_CONFIG" | jq 'del(.inherits)')
      # Deep merge: parent as base, child overrides scalar/object fields
      # For env arrays: merge by name (child wins on name conflict)
      CONFIG=$(jq -n --argjson parent "$PARENT_CONFIG" --argjson child "$CHILD_CONFIG" '
        ($parent * ($child | del(.env))) as $merged |
        if ($child.env // null) != null then
          $merged | .env = (($parent.env // []) + $child.env | group_by(.name) | map(last))
        elif ($parent.env // null) != null then
          $merged
        else
          $merged
        end
      ')
    else
      CONFIG=$(yq -o=json -I=0 ".environments.$ENVIRONMENT // {}" "$CONFIG_FILE")
    fi
    GLOBAL_ENV=$(yq -o=json -I=0 ".environments.global.env // []" "$CONFIG_FILE")
  else
    CONFIG=$(python3 -c "
import yaml, json, os, sys
with open(os.environ['CONFIG_FILE']) as f:
    data = yaml.safe_load(f)
    envs = data.get('environments', {})
    env_config = envs.get(os.environ['ENVIRONMENT'], {})
    # Handle config inheritance
    inherits = env_config.get('inherits')
    if inherits:
        parent = envs.get(inherits, {})
        child = {k: v for k, v in env_config.items() if k != 'inherits'}
        merged = {**parent, **{k: v for k, v in child.items() if k != 'env'}}
        if 'env' in child:
            parent_env = {e['name']: e for e in parent.get('env', [])}
            for e in child['env']:
                parent_env[e['name']] = e
            merged['env'] = list(parent_env.values())
        env_config = merged
    print(json.dumps(env_config, separators=(',', ':')))
" 2>/dev/null || echo "{}")
    GLOBAL_ENV=$(python3 -c "
import yaml, json, os, sys
with open(os.environ['CONFIG_FILE']) as f:
    data = yaml.safe_load(f)
    global_env = data.get('environments', {}).get('global', {}).get('env', [])
    print(json.dumps(global_env, separators=(',', ':')))
" 2>/dev/null || echo "[]")
  fi
fi

# Merge global env vars into config (env-specific overrides global on name conflict)
if [ "$GLOBAL_ENV" != "[]" ]; then
  ENV_SPECIFIC_ENV=$(echo "$CONFIG" | jq '.env // []')
  MERGED_ENV=$(jq -n --argjson global "$GLOBAL_ENV" --argjson specific "$ENV_SPECIFIC_ENV" \
    '($global + $specific) | group_by(.name) | map(last)')
  CONFIG=$(echo "$CONFIG" | jq --argjson merged "$MERGED_ENV" '.env = $merged')
fi

# Read staged deployment config overrides (e.g., environments.prod-preview)
# Same top-level structure as secrets.yaml: environments.<env>-preview
PREVIEW_CONFIG="{}"
if [ -f "$CONFIG_FILE" ]; then
  if command -v yq &> /dev/null; then
    PREVIEW_CONFIG=$(yq -o=json -I=0 ".environments.\"${ENVIRONMENT}-preview\" // {}" "$CONFIG_FILE" 2>/dev/null || echo "{}")
  else
    PREVIEW_CONFIG=$(python3 -c "
import yaml, json, os
with open(os.environ['CONFIG_FILE']) as f:
    data = yaml.safe_load(f)
    preview = data.get('environments', {}).get(os.environ['ENVIRONMENT'] + '-preview', {})
    print(json.dumps(preview, separators=(',', ':')))
" 2>/dev/null || echo "{}")
  fi
fi

# Attach source metadata (repo, ref, run, actor) from GitHub's standard
# runner environment to a /api/v1/deploy payload. Skips what is not set.
add_source_metadata() {
  local body="$1"
  local server="${GITHUB_SERVER_URL:-https://github.com}"
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    body=$(echo "$body" | jq --arg v "${server}/${GITHUB_REPOSITORY}" '. + {repo_url: $v}')
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
      body=$(echo "$body" | jq --arg v "${server}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" '. + {workflow_run_url: $v}')
    fi
  fi
  [ -n "${GITHUB_REF_NAME:-}" ] && body=$(echo "$body" | jq --arg v "$GITHUB_REF_NAME" '. + {source_ref: $v}')
  [ -n "${GITHUB_ACTOR:-}" ] && body=$(echo "$body" | jq --arg v "$GITHUB_ACTOR" '. + {triggered_by: $v}')
  echo "$body"
}

BODY=$(jq -n \
  --arg action "deploy" \
  --arg customer "$APP" \
  --arg environment "$ENVIRONMENT" \
  --arg image_tag "$IMAGE_TAG" \
  --arg commit_sha "$COMMIT_SHA" \
  '{
    action: $action,
    customer: $customer,
    environment: $environment,
    image_tag: $image_tag,
    commit_sha: $commit_sha
  }')

# Where this deploy came from, so the portal can link the partner's own
# commit and workflow run and name the person who triggered it — all from
# the runner's standard environment, nothing to configure.
BODY=$(add_source_metadata "$BODY")

# Add image field if specified (overrides app name as ACR repository)
if [ -n "${IMAGE:-}" ]; then
  BODY=$(echo "$BODY" | jq --arg image "$IMAGE" '. + {image: $image}')
fi

if [ -n "$CONFIG" ] && [ "$CONFIG" != "{}" ]; then
  BODY=$(echo "$BODY" | jq --argjson config "$CONFIG" '. + {config: $config}' 2>/dev/null || echo "$BODY")
fi

# Send global env vars separately so the backend can save them under environment="all"
if [ "$GLOBAL_ENV" != "[]" ]; then
  BODY=$(echo "$BODY" | jq --argjson global_env "$GLOBAL_ENV" '. + {global_env: $global_env}')
fi

# Send per-environment preview config for staged deployments
if [ "$PREVIEW_CONFIG" != "{}" ]; then
  BODY=$(echo "$BODY" | jq --argjson preview_config "$PREVIEW_CONFIG" '. + {preview_config: $preview_config}')
fi

# Send auto_promote setting if specified (overrides portal setting for this environment)
if [ -n "${AUTO_PROMOTE:-}" ]; then
  if [ "$AUTO_PROMOTE" != "true" ] && [ "$AUTO_PROMOTE" != "false" ]; then
    echo "::error::AUTO_PROMOTE must be 'true' or 'false', got: '${AUTO_PROMOTE}'. Set auto_promote to true or false in your workflow."
    exit 1
  fi
  BODY=$(echo "$BODY" | jq --argjson auto_promote "$AUTO_PROMOTE" '. + {auto_promote: $auto_promote}')
fi

# Read custom NGINX config (./base/nginx.yaml) for proxy buffers, headers, etc.
# Generates a SnippetsFilter resource in the partner apps repo
if [ -f "${NGINX_CONFIG_FILE:-}" ]; then
  NGINX_CONFIG="{}"
  if command -v yq &> /dev/null; then
    NGINX_CONFIG=$(yq -o=json -I=0 '.' "$NGINX_CONFIG_FILE" 2>/dev/null || echo "{}")
  else
    NGINX_CONFIG=$(python3 -c "
import yaml, json, os
with open(os.environ['NGINX_CONFIG_FILE']) as f:
    data = yaml.safe_load(f)
    print(json.dumps(data, separators=(',', ':')))
" 2>/dev/null || echo "{}")
  fi
  if [ "$NGINX_CONFIG" != "{}" ]; then
    BODY=$(echo "$BODY" | jq --argjson nginx_config "$NGINX_CONFIG" '. + {nginx_config: $nginx_config}')
  fi
fi

# Read redirects file (.yaml or .csv) for bulk URL redirects.
# Backend auto-chunks across multiple SnippetsFilters to stay under the
# Kubernetes etcd object size limit. The ceiling is 16 chunks per app (Gateway
# API caps a route at 16 filters), i.e. ~120k redirects with typical URLs and
# 160k with short paths. Over the ceiling the backend rejects the deploy with
# an explicit error rather than shipping a partial list — see docs/nginx.md.
# Parse redirects to a TEMP FILE (never a shell variable — 100k+ entries = 10MB+).
#
# REDIRECTS_FILE_FOUND is set true when the file exists. We forward the
# redirects field to the backend whenever the file is present (even empty)
# so the backend can distinguish "customer explicitly cleared all redirects"
# (REDIRECTS_FILE_FOUND=true, count=0) from "no redirects config in repo"
# (REDIRECTS_FILE_FOUND=false). The cleared case must trigger a reconcile
# that prunes stale chunks and drops HTTPRoute filter refs; without this
# signal, the backend would fall into its "don't touch" path and stale
# chunks from previous deploys would leak forever.
# A redirects file that fails to parse must stop the deploy, never quietly
# resolve to zero redirects. REDIRECTS_FILE_FOUND=true with an empty list is a
# meaningful signal further down — it tells the backend to prune every existing
# chunk — so swallowing a parse error here would silently delete a partner's
# live redirects and still report the deploy as successful.
fail_redirects() {
  echo ""
  echo "::error file=$1::Could not parse redirects file: $1"
  echo ""
  echo "╔══════════════════════════════════════════════════════"
  echo "║ ❌ COULD NOT PARSE $1"
  echo "╠══════════════════════════════════════════════════════"
  echo "║"
  echo "║ The parser error is printed directly above this box."
  echo "║"
  echo "║ Deploy stopped. Treating an unreadable redirects file"
  echo "║ as 'no redirects' would drop every live redirect for"
  echo "║ this environment on the next reconcile."
  echo "╚══════════════════════════════════════════════════════"
  exit 1
}

REDIRECTS_INPUT="${REDIRECTS_FILE:-.base/redirects.yaml}"
REDIRECTS_TMP=$(mktemp)
echo "[]" > "$REDIRECTS_TMP"
REDIRECTS_FILE_FOUND=false

if [ -f "$REDIRECTS_INPUT" ]; then
  REDIRECTS_FILE_FOUND=true
  if [[ "$REDIRECTS_INPUT" == *.csv ]]; then
    require_python3 "$REDIRECTS_INPUT"
    REDIRECTS_CSV="$REDIRECTS_INPUT" REDIRECTS_TMP="$REDIRECTS_TMP" python3 -c "
import csv, json, os
with open(os.environ['REDIRECTS_CSV'], 'r', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f)
    redirects = []
    for row in reader:
        fr = (row.get('from') or '').strip()
        to = (row.get('to') or '').strip()
        if not fr or not to: continue
        redirects.append({'from': fr, 'to': to, 'status': int(row.get('status', 301) or 301)})
with open(os.environ['REDIRECTS_TMP'], 'w') as out:
    json.dump(redirects, out, separators=(',',':'))
" || fail_redirects "$REDIRECTS_INPUT"
  else
    if command -v yq &> /dev/null; then
      yq -o=json -I=0 '.redirects // []' "$REDIRECTS_INPUT" > "$REDIRECTS_TMP" || fail_redirects "$REDIRECTS_INPUT"
    else
      REDIRECTS_YAML="$REDIRECTS_INPUT" REDIRECTS_TMP="$REDIRECTS_TMP" python3 -c "
import yaml, json, os
with open(os.environ['REDIRECTS_YAML']) as f:
    data = yaml.safe_load(f) or {}
with open(os.environ['REDIRECTS_TMP'], 'w') as out:
    json.dump(data.get('redirects', []), out, separators=(',',':'))
" || fail_redirects "$REDIRECTS_INPUT"
    fi
  fi
elif [ -f "${REDIRECTS_INPUT%.yaml}.csv" ]; then
  REDIRECTS_FILE_FOUND=true
  require_python3 "${REDIRECTS_INPUT%.yaml}.csv"
  REDIRECTS_CSV="${REDIRECTS_INPUT%.yaml}.csv" REDIRECTS_TMP="$REDIRECTS_TMP" python3 -c "
import csv, json, os
with open(os.environ['REDIRECTS_CSV'], 'r', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f)
    redirects = []
    for row in reader:
        fr = (row.get('from') or '').strip()
        to = (row.get('to') or '').strip()
        if not fr or not to: continue
        redirects.append({'from': fr, 'to': to, 'status': int(row.get('status', 301) or 301)})
with open(os.environ['REDIRECTS_TMP'], 'w') as out:
    json.dump(redirects, out, separators=(',',':'))
" || fail_redirects "${REDIRECTS_INPUT%.yaml}.csv"
fi

# Build the final request body as a FILE (all large data stays on disk, never in shell vars).
BODY_FILE=$(mktemp)
echo "$BODY" > "$BODY_FILE"

REDIRECT_COUNT=$(jq 'length' "$REDIRECTS_TMP")
# Forward the redirects field whenever the file was present in the repo —
# even when empty — so the backend can distinguish "clear all redirects"
# from "no redirects config present". When the file was absent we leave
# the field off entirely (backend treats undefined as "don't touch").
if [ "$REDIRECTS_FILE_FOUND" = "true" ]; then
  if [ "$REDIRECT_COUNT" -gt 0 ]; then
    echo "Found $REDIRECT_COUNT redirects"
  else
    echo "Redirects file present but empty — signaling backend to clear any existing redirects"
  fi
  jq --slurpfile redirects "$REDIRECTS_TMP" '. + {redirects: $redirects[0]}' "$BODY_FILE" > "${BODY_FILE}.tmp" && mv "${BODY_FILE}.tmp" "$BODY_FILE"
fi
rm -f "$REDIRECTS_TMP"

# Forward is_private setting when explicitly set in config (either true or false).
# Previously only `true` was forwarded which made `is_private: false` in config.yaml
# a silent no-op — the backend would fall back to the DB value, so an env that was
# flipped to private in the portal could not be flipped back via config.yaml.
# Now we forward both values whenever the field is present.
IS_PRIVATE=$(echo "$CONFIG" | jq -r '.is_private // empty' 2>/dev/null || echo "")
if [ "$IS_PRIVATE" = "true" ]; then
  jq '. + {is_private: true}' "$BODY_FILE" > "${BODY_FILE}.tmp" && mv "${BODY_FILE}.tmp" "$BODY_FILE"
elif [ "$IS_PRIVATE" = "false" ]; then
  jq '. + {is_private: false}' "$BODY_FILE" > "${BODY_FILE}.tmp" && mv "${BODY_FILE}.tmp" "$BODY_FILE"
fi

# Forward vpn_only setting when explicitly set in config (either true or false).
# Same forwarding semantics as is_private — both values flow so the field can be
# toggled either direction from config.yaml. The backend rejects vpn_only=true
# (409) on partners that don't have an internal Gateway provisioned, and (400)
# when vpn_only and is_private are both true.
VPN_ONLY=$(echo "$CONFIG" | jq -r '.vpn_only // empty' 2>/dev/null || echo "")
if [ "$VPN_ONLY" = "true" ]; then
  jq '. + {vpn_only: true}' "$BODY_FILE" > "${BODY_FILE}.tmp" && mv "${BODY_FILE}.tmp" "$BODY_FILE"
elif [ "$VPN_ONLY" = "false" ]; then
  jq '. + {vpn_only: false}' "$BODY_FILE" > "${BODY_FILE}.tmp" && mv "${BODY_FILE}.tmp" "$BODY_FILE"
fi

# Forward force_https the same way, and for the same reason: forwarding only
# `true` would make `force_https: false` a silent no-op, so an environment
# switched on in the portal could never be switched off from config.yaml.
FORCE_HTTPS=$(echo "$CONFIG" | jq -r '.force_https // empty' 2>/dev/null || echo "")
if [ -n "${FORCE_HTTPS_INPUT:-}" ]; then
  # Workflow input wins over config.yaml, so a pipeline can override per run.
  # Validated like auto_promote above: without this, `force_https: yes` would
  # fall through to config.yaml or the portal setting, and the input would look
  # like it was ignored for no reason — the same silent no-op this whole block
  # exists to avoid.
  if [ "$FORCE_HTTPS_INPUT" != "true" ] && [ "$FORCE_HTTPS_INPUT" != "false" ]; then
    echo "::error::force_https must be 'true' or 'false', got: '${FORCE_HTTPS_INPUT}'. Set force_https to true or false in your workflow."
    exit 1
  fi
  FORCE_HTTPS="$FORCE_HTTPS_INPUT"
elif [ -n "$FORCE_HTTPS" ] && [ "$FORCE_HTTPS" != "true" ] && [ "$FORCE_HTTPS" != "false" ]; then
  # A warning, not an error: config.yaml is already in use by partners and a
  # deploy must not start failing on a value that was previously ignored. But
  # ignoring it in silence is what makes this hard to debug.
  echo "::warning::force_https in .base/config.yaml must be true or false, got: '${FORCE_HTTPS}'. Ignoring it and keeping the current portal setting."
  FORCE_HTTPS=""
fi
if [ "$FORCE_HTTPS" = "true" ]; then
  jq '. + {force_https: true}' "$BODY_FILE" > "${BODY_FILE}.tmp" && mv "${BODY_FILE}.tmp" "$BODY_FILE"
elif [ "$FORCE_HTTPS" = "false" ]; then
  jq '. + {force_https: false}' "$BODY_FILE" > "${BODY_FILE}.tmp" && mv "${BODY_FILE}.tmp" "$BODY_FILE"
fi

# Pre-flight: verify API is reachable (surfaces DNS/proxy/connectivity errors early)
if [ "$ENABLE_HEALTH_PROBE" = "true" ]; then
  if ! curl -s --max-time 5 -o /dev/null "${API_URL}/health" 2>&1; then
    echo ""
    echo "::error::Cannot reach Base API at ${API_URL}"
    echo "Hint: check DNS resolution, proxy settings (HTTPS_PROXY, NO_PROXY), and network connectivity."
    rm -f "$BODY_FILE"
    exit 1
  fi
fi

# Large redirect deploys can take >60s (parsing + chunking + git commit with retries).
# --max-time 180 prevents curl from hanging indefinitely if backend is slow.
# --connect-timeout 10 fails fast if backend is unreachable.
NOPROXY_ARGS=()
[ "$USE_NOPROXY" = "true" ] && NOPROXY_ARGS=(--noproxy '*')
CURL_EXIT=0
RESPONSE=$(curl -s -w "\n%{http_code}" "${NOPROXY_ARGS[@]}" --max-time 180 --connect-timeout 10 \
  -X POST "${API_URL}/api/v1/deploy" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "@${BODY_FILE}") || CURL_EXIT=$?
rm -f "$BODY_FILE"

if [ "$CURL_EXIT" -ne 0 ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════"
  echo "║ ❌ DEPLOY REQUEST FAILED (curl exit code $CURL_EXIT)"
  echo "╠══════════════════════════════════════════════════════"
  if [ "$CURL_EXIT" -eq 28 ]; then
    echo "║ Timeout: backend did not respond within 180 seconds."
    echo "║ The deploy may still be processing — check the portal."
  elif [ "$CURL_EXIT" -eq 5 ]; then
    echo "║ Proxy error: could not resolve proxy."
    echo "║ Check HTTP_PROXY/HTTPS_PROXY environment variables."
  elif [ "$CURL_EXIT" -eq 7 ]; then
    echo "║ Connection refused: backend is unreachable."
  else
    echo "║ Unexpected curl error."
  fi
  echo "╚══════════════════════════════════════════════════════"
  echo ""
  echo "deploy_success=false" >> $GITHUB_OUTPUT
  exit 1
fi

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ]; then
  ERROR_CODE=$(echo "$BODY" | jq -r '.error.code // empty' 2>/dev/null)
  ERROR_MSG=$(echo "$BODY" | jq -r '.error.message // empty' 2>/dev/null)
  REQUEST_ID=$(echo "$BODY" | jq -r '.error.requestId // empty' 2>/dev/null)
  DETAILS=$(echo "$BODY" | jq -r '.error.details[]?.message // empty' 2>/dev/null)

  echo ""
  echo "╔══════════════════════════════════════════════════════"
  echo "║ ❌ DEPLOYMENT FAILED (HTTP $HTTP_CODE)"
  echo "╠══════════════════════════════════════════════════════"

  if [ -n "$ERROR_MSG" ]; then
    echo "║ Error: $ERROR_MSG"
  fi

  if [ -n "$DETAILS" ]; then
    echo "║ Details: $DETAILS"
  fi

  # Special-case redirect-limit errors. Backend returns 400 with stable codes
  # REDIRECT_CHUNK_LIMIT (input would chunk to >16 NGF SnippetsFilters) or
  # HTTPROUTE_FILTER_LIMIT. Surface an actionable message instead of a generic
  # 400 so partners know the redirect list is the problem (ported from public
  # base-actions PR #9 to keep internal in sync).
  case "$ERROR_CODE" in
    REDIRECT_CHUNK_LIMIT|HTTPROUTE_FILTER_LIMIT)
      echo "║"
      echo "║ 🚧 TOO MANY REDIRECTS"
      echo "║   Source file: $REDIRECTS_INPUT"
      echo "║   Entries in this deploy: ${REDIRECT_COUNT:-unknown}"
      echo "║"
      echo "║   The platform chunks redirects into NGF SnippetsFilters"
      echo "║   under the Gateway API per-rule cap of 16. Effective"
      echo "║   ceiling per environment:"
      echo "║     • ~160,000 entries with very short paths"
      echo "║     • ~120,000 entries at realistic URL lengths (path-heavy"
      echo "║       partner catalogues hit the byte cap before the entry"
      echo "║       cap, so ~7,500 entries/chunk × 16 chunks)"
      echo "║"
      echo "║   Fix: reduce the entries in $REDIRECTS_INPUT below the"
      echo "║   cap and re-deploy. If you genuinely need more, contact"
      echo "║   the Norce Base team — the cap is a Gateway API constraint"
      echo "║   that needs an architecture change to lift safely."
      ;;
  esac

  case "$HTTP_CODE" in
    401)
      echo "║"
      echo "║ 🔑 Fix: Check that your api_key secret is set correctly."
      echo "║   The API key should start with 'base_' and be configured"
      echo "║   as a repository or organization secret."
      ;;
    403)
      echo "║"
      echo "║ 🔒 Fix: The app name '$APP' was not found."
      echo "║   Check that the 'app' input matches the exact name"
      echo "║   registered in the Base Portal. If not set, it defaults"
      echo "║   to the repository name: '${REPO_NAME}'."
      ;;
    400)
      echo "║"
      echo "║ 📋 Fix: The request payload is invalid."
      echo "║   Verify that 'environment' and 'image_tag' are correct."
      echo "║   Environment must be lowercase alphanumeric with hyphens."
      ;;
    500)
      echo "║"
      echo "║ 🔧 This is a server-side error. Contact NorceTech support"
      echo "║   with request ID: ${REQUEST_ID:-unknown}"
      ;;
    503)
      echo "║"
      echo "║ 🔧 The deploy service is temporarily unavailable."
      echo "║   Retry the deployment in a few minutes."
      ;;
  esac

  echo "║"
  echo "║ App:         $APP"
  echo "║ Environment: $ENVIRONMENT"
  echo "║ Image Tag:   $IMAGE_TAG"
  if [ -n "$REQUEST_ID" ]; then
    echo "║ Request ID:  $REQUEST_ID"
  fi
  echo "╚══════════════════════════════════════════════════════"
  echo ""

  # Sharper GitHub Actions annotation for the redirect limit so it lands on the
  # file in the PR/diff view; fall back to the generic message otherwise.
  case "$ERROR_CODE" in
    REDIRECT_CHUNK_LIMIT|HTTPROUTE_FILTER_LIMIT)
      echo "::error file=${REDIRECTS_INPUT}::Too many redirects (${REDIRECT_COUNT:-?} entries in ${REDIRECTS_INPUT}). Cap is ~120-160k per environment — reduce the list or contact NorceTech. See job log for details."
      ;;
    *)
      echo "::error::Deploy failed ($HTTP_CODE): ${ERROR_MSG:-Unknown error}"
      ;;
  esac

  echo "success=false" >> $GITHUB_OUTPUT
  echo "deploy_success=false" >> $GITHUB_OUTPUT
  exit 1
fi

SUCCESS=$(echo "$BODY" | jq -r '.data.success // false')
NAMESPACE=$(echo "$BODY" | jq -r '.data.namespace // empty')
GIT_SHA=$(echo "$BODY" | jq -r '.data.gitCommitSha // empty')
PREV_TAG=$(echo "$BODY" | jq -r '.data.previousImageTag // empty')
MESSAGE=$(echo "$BODY" | jq -r '.data.message // empty')
# Staged (auto_promote=false) deploys: the platform tells us where the canary
# preview is served. Older platform versions omit it — wait-healthy.sh then
# derives the same URL from the namespace.
PREVIEW_URL=$(echo "$BODY" | jq -r '.data.previewUrl // empty')

echo "success=$SUCCESS" >> $GITHUB_OUTPUT
echo "deploy_success=$SUCCESS" >> $GITHUB_OUTPUT
echo "namespace=$NAMESPACE" >> $GITHUB_OUTPUT
echo "git_commit_sha=$GIT_SHA" >> $GITHUB_OUTPUT
echo "previous_image_tag=$PREV_TAG" >> $GITHUB_OUTPUT
echo "message=$MESSAGE" >> $GITHUB_OUTPUT
echo "preview_url=$PREVIEW_URL" >> $GITHUB_OUTPUT

echo "✅ Deploy submitted: ${IMAGE_TAG} → ${ENVIRONMENT}"
if [ -n "$PREV_TAG" ]; then
  echo "   Previous tag: $PREV_TAG"
fi
if [ -n "$GIT_SHA" ]; then
  echo "   Git commit:   ${GIT_SHA:0:7}"
fi
echo "$MESSAGE"
