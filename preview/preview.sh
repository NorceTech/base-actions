#!/usr/bin/env bash
set -euo pipefail

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}/api/v1/preview" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg action "$ACTION" \
    --arg customer "$CUSTOMER" \
    --argjson pr_number "${PR_NUMBER:-0}" \
    --arg pr_branch "${PR_BRANCH:-}" \
    --arg image_tag "${IMAGE_TAG:-}" \
    --arg commit_sha "${COMMIT_SHA:-}" \
    --arg pr_title "${PR_TITLE:-}" \
    --arg pr_url "${PR_URL:-}" \
    --argjson config "${CONFIG:-{}}" \
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

echo "Response: $HTTP_CODE"

if [ "$HTTP_CODE" -ne 200 ]; then
  if [ "$ACTION" = "delete" ]; then
    echo "::warning::Preview may already be deleted"
    echo "success=true" >> $GITHUB_OUTPUT
    echo "message=Preview environment deleted or not found" >> $GITHUB_OUTPUT
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
NAMESPACE=$(echo "$BODY" | jq -r '.data.namespace // empty')
GIT_SHA=$(echo "$BODY" | jq -r '.data.gitCommitSha // empty')
MESSAGE=$(echo "$BODY" | jq -r '.data.message // empty')

echo "success=$SUCCESS" >> $GITHUB_OUTPUT
echo "preview_url=$PREVIEW_URL" >> $GITHUB_OUTPUT
echo "namespace=$NAMESPACE" >> $GITHUB_OUTPUT
echo "git_commit_sha=$GIT_SHA" >> $GITHUB_OUTPUT
echo "message=$MESSAGE" >> $GITHUB_OUTPUT

if [ -n "$PREVIEW_URL" ]; then
  echo "Preview URL: $PREVIEW_URL"
fi
echo "$MESSAGE"
