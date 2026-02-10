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

if command -v yq &> /dev/null; then
  FILE_JSON=$(yq -o=json '.' "$SECRETS_FILE")
else
  FILE_JSON=$(python3 -c "
import yaml, json, os
with open(os.environ['SECRETS_FILE']) as f:
    data = yaml.safe_load(f)
    print(json.dumps(data, separators=(',', ':')))
" 2>/dev/null)
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
    --arg customer "$CUSTOMER" \
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

if [ "$HAS_SECRETS" = "true" ]; then
  MAPPINGS=$(echo "$FILE_JSON" | jq '.secrets')
  sync_env_secrets "all" "$MAPPINGS"
fi

if [ "$HAS_ENVIRONMENTS" = "true" ]; then
  ENV_NAMES=$(echo "$FILE_JSON" | jq -r '.environments | keys[]')

  for ENV_NAME in $ENV_NAMES; do
    if [ -n "$TARGET_ENV" ] && [ "$ENV_NAME" != "$TARGET_ENV" ]; then
      continue
    fi

    MAPPINGS=$(echo "$FILE_JSON" | jq --arg env "$ENV_NAME" '.environments[$env]')
    sync_env_secrets "$ENV_NAME" "$MAPPINGS"
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
