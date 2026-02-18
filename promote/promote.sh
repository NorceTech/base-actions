#!/usr/bin/env bash
set -euo pipefail

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

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -ne 200 ]; then
  echo "::error::Promotion failed"
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY"
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

echo "Promoted $NEW_TAG from $FROM_ENV to $TO_ENV"
echo "$MESSAGE"
