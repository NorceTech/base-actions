#!/usr/bin/env bash
set -euo pipefail

# Validate environment names
ALLOWED_ENVS="dev test stage prod"
validate_env() {
  local env="$1"
  local label="$2"
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

# Determine promotion mode
if [ "${CANARY:-false}" = "true" ]; then
  # ── Canary promotion: promote staged preview → live ──
  if [ -z "${ENVIRONMENT:-}" ]; then
    echo "::error::canary: true requires the 'environment' input"
    exit 1
  fi
  validate_env "$ENVIRONMENT" "environment"

  LABEL="canary → live on $ENVIRONMENT"

  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}/api/v1/deploy" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg action "promote-canary" \
      --arg customer "$APP" \
      --arg environment "$ENVIRONMENT" \
      --arg image_tag "ignored" \
      '{
        action: $action,
        customer: $customer,
        environment: $environment,
        image_tag: $image_tag
      }')")
else
  # ── Cross-environment promotion: stage → prod ──
  if [ -z "${FROM_ENV:-}" ] || [ -z "${TO_ENV:-}" ]; then
    echo "::error::Cross-environment promotion requires both 'from_environment' and 'to_environment'"
    exit 1
  fi
  validate_env "$FROM_ENV" "from_environment"
  validate_env "$TO_ENV" "to_environment"

  LABEL="$FROM_ENV → $TO_ENV"

  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}/api/v1/deploy" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg action "promote" \
      --arg customer "$APP" \
      --arg from_environment "$FROM_ENV" \
      --arg environment "$TO_ENV" \
      --arg image_tag "ignored" \
      '{
        action: $action,
        customer: $customer,
        from_environment: $from_environment,
        environment: $environment,
        image_tag: $image_tag
      }')")
fi

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════"
  echo "║ ❌ PROMOTION FAILED (HTTP $HTTP_CODE)"
  echo "╠══════════════════════════════════════════════════════"
  echo "║"
  echo "║ Mode:        ${CANARY:-false} = true → canary, false → cross-env"
  echo "║ Target:      $LABEL"

  ERROR_MSG=$(echo "$BODY" | jq -r '.error.message // empty' 2>/dev/null)
  if [ -n "$ERROR_MSG" ]; then
    echo "║ Error:       $ERROR_MSG"
  fi

  if [ "${CANARY:-false}" = "true" ]; then
    echo "║"
    echo "║ 💡 Canary promotion requires a staged deployment in"
    echo "║   Suspended state. Deploy with auto_promote: false first."
  fi

  echo "╚══════════════════════════════════════════════════════"
  echo ""

  echo "::error::Promotion failed ($HTTP_CODE): ${ERROR_MSG:-Unknown error}"
  echo "success=false" >> $GITHUB_OUTPUT
  exit 1
fi

SUCCESS=$(echo "$BODY" | jq -r '.data.success // false')
NAMESPACE=$(echo "$BODY" | jq -r '.data.namespace // empty')
GIT_SHA=$(echo "$BODY" | jq -r '.data.gitCommitSha // empty')
PREV_TAG=$(echo "$BODY" | jq -r '.data.previousImageTag // empty')
NEW_TAG=$(echo "$BODY" | jq -r '.data.newImageTag // empty')
MESSAGE=$(echo "$BODY" | jq -r '.data.message // empty')

echo "success=$SUCCESS" >> $GITHUB_OUTPUT
echo "namespace=$NAMESPACE" >> $GITHUB_OUTPUT
echo "git_commit_sha=$GIT_SHA" >> $GITHUB_OUTPUT
echo "previous_image_tag=$PREV_TAG" >> $GITHUB_OUTPUT
echo "new_image_tag=$NEW_TAG" >> $GITHUB_OUTPUT
echo "message=$MESSAGE" >> $GITHUB_OUTPUT

echo "✅ Promoted: $LABEL"
echo "$MESSAGE"
