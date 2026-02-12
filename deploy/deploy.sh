#!/usr/bin/env bash
set -euo pipefail

# Read environment config from YAML
CONFIG="{}"
GLOBAL_ENV="[]"

if [ -f "$CONFIG_FILE" ]; then
  if command -v yq &> /dev/null; then
    CONFIG=$(yq -o=json -I=0 ".environments.$ENVIRONMENT // {}" "$CONFIG_FILE")
    GLOBAL_ENV=$(yq -o=json -I=0 ".environments.global.env // []" "$CONFIG_FILE")
  else
    CONFIG=$(python3 -c "
import yaml, json, os, sys
with open(os.environ['CONFIG_FILE']) as f:
    data = yaml.safe_load(f)
    env_config = data.get('environments', {}).get(os.environ['ENVIRONMENT'], {})
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

BODY=$(jq -n \
  --arg action "deploy" \
  --arg customer "$CUSTOMER" \
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

# Add image field if specified (overrides customer name as ACR repository)
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

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}/api/v1/deploy" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$BODY")

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

  case "$HTTP_CODE" in
    401)
      echo "║"
      echo "║ 🔑 Fix: Check that your api_key secret is set correctly."
      echo "║   The API key should start with 'base_' and be configured"
      echo "║   as a repository or organization secret."
      ;;
    403)
      echo "║"
      echo "║ 🔒 Fix: The customer name '$CUSTOMER' was not found."
      echo "║   Check that the 'customer' input matches the exact name"
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
  echo "║ Customer:    $CUSTOMER"
  echo "║ Environment: $ENVIRONMENT"
  echo "║ Image Tag:   $IMAGE_TAG"
  if [ -n "$REQUEST_ID" ]; then
    echo "║ Request ID:  $REQUEST_ID"
  fi
  echo "╚══════════════════════════════════════════════════════"
  echo ""

  echo "::error::Deploy failed ($HTTP_CODE): ${ERROR_MSG:-Unknown error}"

  echo "success=false" >> $GITHUB_OUTPUT
  echo "deploy_success=false" >> $GITHUB_OUTPUT
  exit 1
fi

SUCCESS=$(echo "$BODY" | jq -r '.data.success // false')
NAMESPACE=$(echo "$BODY" | jq -r '.data.namespace // empty')
GIT_SHA=$(echo "$BODY" | jq -r '.data.gitCommitSha // empty')
PREV_TAG=$(echo "$BODY" | jq -r '.data.previousImageTag // empty')
MESSAGE=$(echo "$BODY" | jq -r '.data.message // empty')

echo "success=$SUCCESS" >> $GITHUB_OUTPUT
echo "deploy_success=$SUCCESS" >> $GITHUB_OUTPUT
echo "namespace=$NAMESPACE" >> $GITHUB_OUTPUT
echo "git_commit_sha=$GIT_SHA" >> $GITHUB_OUTPUT
echo "previous_image_tag=$PREV_TAG" >> $GITHUB_OUTPUT
echo "message=$MESSAGE" >> $GITHUB_OUTPUT

echo "✅ Deploy submitted: ${IMAGE_TAG} → ${ENVIRONMENT}"
if [ -n "$PREV_TAG" ]; then
  echo "   Previous tag: $PREV_TAG"
fi
if [ -n "$GIT_SHA" ]; then
  echo "   Git commit:   ${GIT_SHA:0:7}"
fi
echo "$MESSAGE"
