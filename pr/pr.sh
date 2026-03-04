#!/usr/bin/env bash
set -euo pipefail

# Manage PR ephemeral environments (pr-*).
# Config resolution (three-layer): global → inherited env → pr scope overrides
if [ "$ACTION" != "delete" ] && [ -f "$CONFIG_FILE" ]; then
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
