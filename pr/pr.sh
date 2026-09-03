#!/usr/bin/env bash
set -euo pipefail

# Verify a YAML parser exists before reading .base/config.yaml.
#
# Unlike deploy.sh and sync-secrets.sh — which died outright — the fallback
# below is guarded with `|| echo "{}"`. That makes this failure quieter and
# worse: with neither yq nor PyYAML the PR ephemeral is created with an EMPTY
# config, so every env var, replica count and resource limit from
# .base/config.yaml is silently dropped and the run still reports success.
# Refuse to build a PR environment we cannot configure correctly.
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
  echo "║ Stopping rather than creating a PR environment with an"
  echo "║ empty config — every env var and limit in the file"
  echo "║ would be silently dropped."
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

# Manage PR ephemeral environments (pr-*).
# Config resolution (three-layer): global → inherited env → pr scope overrides
if [ "$ACTION" != "delete" ] && [ -f "$CONFIG_FILE" ]; then
  require_yaml_parser "$CONFIG_FILE"
  if command -v yq &> /dev/null; then
    GLOBAL_ENV=$(yq -o=json -I=0 '.environments.global.env // []' "$CONFIG_FILE")
    PR_CONFIG=$(yq -o=json -I=0 '.environments.pr // {}' "$CONFIG_FILE")

    # Check for config inheritance (e.g., pr.inherits: stage)
    INHERITS=$(yq -r '.environments.pr.inherits // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    if [ -n "$INHERITS" ]; then
      PARENT_CONFIG=$(yq -o=json -I=0 ".environments.$INHERITS // {}" "$CONFIG_FILE")
      CHILD_CONFIG=$(echo "$PR_CONFIG" | jq 'del(.inherits)')
      # Deep merge: parent as base, pr overrides scalar/object fields
      # For env arrays: merge by name (pr wins on name conflict)
      PR_CONFIG=$(jq -n --argjson parent "$PARENT_CONFIG" --argjson child "$CHILD_CONFIG" '
        ($parent * ($child | del(.env))) as $merged |
        if ($child.env // null) != null then
          $merged | .env = (($parent.env // []) + $child.env | group_by(.name) | map(last))
        elif ($parent.env // null) != null then
          $merged
        else
          $merged
        end
      ')
    fi

    # Merge global env vars: global first, then inherited+pr (last value wins)
    CONFIG=$(echo "$PR_CONFIG" | jq --argjson global "$GLOBAL_ENV" \
      '.env = (($global + (.env // [])) | group_by(.name) | map(last))')
  else
    CONFIG=$(python3 -c "
import yaml, json, os
with open(os.environ['CONFIG_FILE']) as f:
    data = yaml.safe_load(f)
    envs = data.get('environments', {})
    global_env = envs.get('global', {}).get('env', [])
    pr = dict(envs.get('pr', {}))
    # Handle config inheritance
    inherits = pr.pop('inherits', None)
    if inherits:
        parent = dict(envs.get(inherits, {}))
        child_env = pr.pop('env', None)
        merged = {**parent, **{k: v for k, v in pr.items() if k != 'env'}}
        if child_env is not None:
            parent_env = {e['name']: e for e in parent.get('env', [])}
            for e in child_env:
                parent_env[e['name']] = e
            merged['env'] = list(parent_env.values())
        pr = merged
    # Merge global env vars (global first, pr overrides)
    merged_env = {e['name']: e for e in global_env}
    for e in pr.get('env', []):
        merged_env[e['name']] = e
    pr['env'] = list(merged_env.values())
    print(json.dumps(pr, separators=(',', ':')))
" 2>/dev/null || echo "{}")
  fi
else
  CONFIG='{}'
fi

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}/api/v1/preview" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg action "$ACTION" \
    --arg customer "$APP" \
    --argjson pr_number "${PR_NUMBER:-0}" \
    --arg pr_branch "${PR_BRANCH:-}" \
    --arg image_tag "${IMAGE_TAG:-}" \
    --arg commit_sha "${COMMIT_SHA:-}" \
    --arg pr_title "${PR_TITLE:-}" \
    --arg pr_url "${PR_URL:-}" \
    --argjson config "${CONFIG}" \
    '{
      action: $action,
      customer: $customer,
      pr_number: $pr_number,
      pr_branch: $pr_branch,
      image_tag: $image_tag,
      commit_sha: $commit_sha,
      pr_title: $pr_title,
      pr_url: $pr_url,
      config: $config
    }')")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ]; then
  if [ "$ACTION" = "delete" ] && [ "$HTTP_CODE" -eq 404 ]; then
    # Only "not found" is benign on delete: the environment was already removed.
    # Any other failure (502/504 from GitHub while committing the deletion, 5xx
    # from the API) used to be mapped to success here — which is how 140 stale
    # PR environments accumulated on partnersense without a single red job.
    echo "::warning::Preview environment not found — already deleted"
    echo "success=true" >> $GITHUB_OUTPUT
    echo "message=Preview environment not found (already deleted)" >> $GITHUB_OUTPUT
    exit 0
  else
    echo "::error::Failed to $ACTION preview"
    echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
    echo "success=false" >> $GITHUB_OUTPUT
    exit 1
  fi
fi

SUCCESS=$(echo "$BODY" | jq -r '.data.success // false')
PREVIEW_URL=$(echo "$BODY" | jq -r '.data.previewUrl // empty')
MESSAGE=$(echo "$BODY" | jq -r '.data.message // empty')

echo "success=$SUCCESS" >> $GITHUB_OUTPUT
echo "preview_url=$PREVIEW_URL" >> $GITHUB_OUTPUT
echo "message=$MESSAGE" >> $GITHUB_OUTPUT

if [ -n "$PREVIEW_URL" ]; then
  echo "PR Environment URL: $PREVIEW_URL"
fi
echo "$MESSAGE"
