#!/usr/bin/env bash
set -euo pipefail

if [ ! -f "$SECRETS_FILE" ]; then
  echo "::error::Secrets mapping file not found: $SECRETS_FILE"
  echo "synced_count=0" >> $GITHUB_OUTPUT
  echo "failed_count=0" >> $GITHUB_OUTPUT
  echo "synced_names=" >> $GITHUB_OUTPUT
  exit 1
fi

echo "Reading secrets mapping from: $SECRETS_FILE"

# Verify a YAML parser exists before reading the mapping.
#
# The python fallback below used to discard stderr and carry no `|| ...` guard,
# so on a runner with neither yq nor PyYAML `set -e` killed this script right
# here: exit 1 immediately after the line above, with no error of any kind.
# Every self-hosted run from 2026-07-09 onward failed that way — twelve in a
# row, each one a two-line log ending in a bare exit code. The redirection is
# gone now; this preflight is what keeps the failure legible.
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
  echo "synced_count=0" >> "$GITHUB_OUTPUT"
  echo "failed_count=0" >> "$GITHUB_OUTPUT"
  echo "synced_names=" >> "$GITHUB_OUTPUT"
  exit 1
}

require_yaml_parser "$SECRETS_FILE"

if command -v yq &> /dev/null; then
  FILE_JSON=$(yq -o=json '.' "$SECRETS_FILE")
else
  FILE_JSON=$(python3 -c "
import yaml, json, os
with open(os.environ['SECRETS_FILE']) as f:
    data = yaml.safe_load(f)
    print(json.dumps(data, separators=(',', ':')))
")
fi

HAS_ENVIRONMENTS=$(echo "$FILE_JSON" | jq 'has("environments")')
HAS_SECRETS=$(echo "$FILE_JSON" | jq 'has("secrets")')

TOTAL_SYNCED=0
TOTAL_FAILED=0
ALL_SYNCED_NAMES=""

sync_env_secrets() {
  local ENV_NAME="$1"
  local MAPPINGS="$2"

  local SECRETS_JSON="[]"
  local SKIPPED=0
  local TOTAL=$(echo "$MAPPINGS" | jq 'length')

  if [ "$TOTAL" -eq 0 ]; then
    return
  fi

  echo ""
  echo "── $ENV_NAME ($TOTAL secret(s)) ──"

  for i in $(seq 0 $((TOTAL - 1))); do
    local GITHUB_NAME=$(echo "$MAPPINGS" | jq -r ".[$i].github")
    local KV_NAME=$(echo "$MAPPINGS" | jq -r ".[$i].keyvault")

    # Indirect expansion: reads the env var whose name matches GITHUB_NAME
    local VALUE="${!GITHUB_NAME:-}"

    if [ -z "$VALUE" ]; then
      echo "::warning::Secret '$GITHUB_NAME' is not set in environment, skipping '$KV_NAME'"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    SECRETS_JSON=$(echo "$SECRETS_JSON" | jq --arg name "$KV_NAME" --arg value "$VALUE" \
      '. + [{"name": $name, "value": $value}]')

    echo "  Mapped: $GITHUB_NAME → $KV_NAME"
  done

  if [ "$SKIPPED" -gt 0 ]; then
    echo "::warning::Skipped $SKIPPED secret(s) with missing values for $ENV_NAME"
  fi

  local SECRETS_COUNT=$(echo "$SECRETS_JSON" | jq 'length')

  if [ "$SECRETS_COUNT" -eq 0 ]; then
    echo "  No secrets to sync for $ENV_NAME (all values missing)"
    TOTAL_FAILED=$((TOTAL_FAILED + SKIPPED))
    return
  fi

  local BODY=$(jq -n \
    --arg customer "$APP" \
    --arg environment "$ENV_NAME" \
    --argjson secrets "$SECRETS_JSON" \
    '{ customer: $customer, environment: $environment, secrets: $secrets }')

  local RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}/api/v1/secrets" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$BODY")

  local HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  local RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" -ne 200 ] && [ "$HTTP_CODE" -ne 207 ]; then
    echo "::error::Secrets sync failed for $ENV_NAME (HTTP $HTTP_CODE)"
    echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
    TOTAL_FAILED=$((TOTAL_FAILED + SECRETS_COUNT))
    return
  fi

  local SYNCED=$(echo "$RESPONSE_BODY" | jq -r '.data.synced | join(",")')
  local SYNCED_COUNT=$(echo "$RESPONSE_BODY" | jq '.data.synced | length')
  local FAILED_COUNT=$(echo "$RESPONSE_BODY" | jq '.data.failed | length')

  TOTAL_SYNCED=$((TOTAL_SYNCED + SYNCED_COUNT))
  TOTAL_FAILED=$((TOTAL_FAILED + FAILED_COUNT))

  if [ -n "$SYNCED" ]; then
    if [ -n "$ALL_SYNCED_NAMES" ]; then
      ALL_SYNCED_NAMES="${ALL_SYNCED_NAMES},${SYNCED}"
    else
      ALL_SYNCED_NAMES="$SYNCED"
    fi
  fi

  echo "  Synced: $SYNCED_COUNT, Failed: $FAILED_COUNT"

  if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "$RESPONSE_BODY" | jq -r '.data.failed[] | "  ✗ \(.name): \(.error)"'
  fi
}

if [ "$HAS_ENVIRONMENTS" != "true" ] && [ "$HAS_SECRETS" != "true" ]; then
  echo "::error::Invalid secrets file format. Expected 'environments:' and/or 'secrets:' key."
  echo "synced_count=0" >> $GITHUB_OUTPUT
  echo "failed_count=0" >> $GITHUB_OUTPUT
  echo "synced_names=" >> $GITHUB_OUTPUT
  exit 1
fi

# Support both formats for global secrets:
#   New (consistent with config.yaml): environments.global: [...]
#   Legacy: secrets: [...]
# Both are synced as environment="all". If both exist, they are merged.
if [ "$HAS_SECRETS" = "true" ]; then
  MAPPINGS=$(echo "$FILE_JSON" | jq '.secrets')
  sync_env_secrets "all" "$MAPPINGS"
fi

if [ "$HAS_ENVIRONMENTS" = "true" ]; then
  ENV_NAMES=$(echo "$FILE_JSON" | jq -r '.environments | keys[]')

  for ENV_NAME in $ENV_NAMES; do
    # Validate environment name against allowed list (must match backend isAllowedSecretEnvironment)
    # Allowed: global, dev, test, stage, prod, preview, <env>-preview, pr-*, preview-*, feature-*, branch-*
    ALLOWED_SECRET_ENVS="dev test stage prod"
    is_valid_secret_env() {
      local env="$1"
      if [ "$env" = "global" ]; then return 0; fi
      if [ "$env" = "preview" ]; then return 0; fi
      # Named environments
      for allowed in $ALLOWED_SECRET_ENVS; do
        if [ "$env" = "$allowed" ]; then return 0; fi
      done
      # Per-environment preview overrides: <env>-preview
      for allowed in $ALLOWED_SECRET_ENVS; do
        if [ "$env" = "${allowed}-preview" ]; then return 0; fi
      done
      # PR/preview patterns
      if echo "$env" | grep -qE '^(pr-|preview-|feature-|branch-)[0-9]'; then return 0; fi
      return 1
    }

    if ! is_valid_secret_env "$ENV_NAME"; then
      echo ""
      echo "::error::Invalid environment name in secrets file: '$ENV_NAME'"
      echo ""
      echo "╔══════════════════════════════════════════════════════"
      echo "║ ❌ INVALID SECRET ENVIRONMENT: '$ENV_NAME'"
      echo "╠══════════════════════════════════════════════════════"
      echo "║"
      echo "║ Allowed environment names:"
      echo "║   dev, test, stage, prod, preview, pr-*"
      echo "║   <env>-preview (e.g. prod-preview, stage-preview)"
      echo "║"
      echo "║ Common mistakes:"
      echo "║   staging    → use 'stage' instead"
      echo "║   production → use 'prod' instead"
      echo "║   development → use 'dev' instead"
      echo "║   pre-prod   → use 'prod-preview' instead"
      echo "║"
      echo "║ Check your .base/secrets.yaml"
      echo "╚══════════════════════════════════════════════════════"
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      continue
    fi

    # environments.global → sync as "all" (global secrets)
    local_env="$ENV_NAME"
    if [ "$ENV_NAME" = "global" ]; then
      local_env="all"
    fi

    if [ -n "$TARGET_ENV" ] && [ "$ENV_NAME" != "$TARGET_ENV" ] && [ "$ENV_NAME" != "global" ]; then
      continue
    fi

    MAPPINGS=$(echo "$FILE_JSON" | jq --arg env "$ENV_NAME" '.environments[$env]')
    sync_env_secrets "$local_env" "$MAPPINGS"
  done
fi

echo ""
echo "╔══════════════════════════════════════════════════════"
echo "║ Secrets sync complete"
echo "╠══════════════════════════════════════════════════════"
echo "║ Synced: $TOTAL_SYNCED"
echo "║ Failed: $TOTAL_FAILED"
echo "╚══════════════════════════════════════════════════════"

echo "synced_count=$TOTAL_SYNCED" >> $GITHUB_OUTPUT
echo "failed_count=$TOTAL_FAILED" >> $GITHUB_OUTPUT
echo "synced_names=$ALL_SYNCED_NAMES" >> $GITHUB_OUTPUT

if [ "$TOTAL_FAILED" -gt 0 ] && [ "$TOTAL_SYNCED" -eq 0 ]; then
  exit 1
fi
