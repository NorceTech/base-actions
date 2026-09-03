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
    -d "$(add_source_metadata "$(jq -n \
      --arg action "promote-canary" \
      --arg customer "$APP" \
      --arg environment "$ENVIRONMENT" \
      --arg image_tag "ignored" \
      '{
        action: $action,
        customer: $customer,
        environment: $environment,
        image_tag: $image_tag
      }')")")
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
    -d "$(add_source_metadata "$(jq -n \
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
      }')")")
fi

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

# 200 = promoted (or nothing to do). 202 = accepted, still converging: the
# platform strips the <env>-preview overrides from the canary and re-rolls it
# on the clean template before it clears the pause, so the switch happens a
# little later — we wait for it below instead of calling it done.
if [ "$HTTP_CODE" -ne 200 ] && [ "$HTTP_CODE" -ne 202 ]; then
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

PROMOTION_STATE=$(echo "$BODY" | jq -r '.data.promotion.state // empty')

echo "namespace=$NAMESPACE" >> $GITHUB_OUTPUT
echo "git_commit_sha=$GIT_SHA" >> $GITHUB_OUTPUT
echo "previous_image_tag=$PREV_TAG" >> $GITHUB_OUTPUT
echo "new_image_tag=$NEW_TAG" >> $GITHUB_OUTPUT
echo "message=$MESSAGE" >> $GITHUB_OUTPUT

# Wait for a converging canary promotion. Terminal states, in order of what
# the deploy status endpoint reports for the environment:
#   Healthy    -> the switch happened (or the clean template equalled stable
#                 and there was nothing left to switch) -> success
#   Degraded   -> tolerated for DEGRADED_GRACE (new pods starting), then fail
#   Suspended / Progressing -> still converging (old canary paused, clean canary
#                 rolling, clean canary paused, then promoted) -> keep waiting
# The platform's own wait gives up after 10 minutes and leaves the canary
# paused; re-running this action is safe and converges from the current state.
wait_for_promotion() {
  local timeout="${TIMEOUT:-900}"
  local poll="${POLL_INTERVAL:-10}"
  local degraded_grace="${DEGRADED_GRACE:-60}"
  local start elapsed resp code body health last="" degraded_since=-1
  start=$(date +%s)

  echo "::group::⏳ Waiting for the canary promotion to complete (timeout: ${timeout}s)"
  while true; do
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "::endgroup::"
      echo ""
      echo "╔══════════════════════════════════════════════════════"
      echo "║ ❌ PROMOTION NOT COMPLETE AFTER ${timeout}s"
      echo "╠══════════════════════════════════════════════════════"
      echo "║"
      echo "║ Target:      $LABEL"
      echo "║ Last health: ${health:-unknown}"
      echo "║"
      echo "║ The platform accepted the promotion but the rollout did"
      echo "║ not become Healthy in time (ArgoCD sync + canary re-roll"
      echo "║ can take minutes under load). The canary is left paused."
      echo "║ Re-run this job to retry — it converges from the current"
      echo "║ state — or check the environment in the portal."
      echo "╚══════════════════════════════════════════════════════"
      echo "::error::Canary promotion did not complete within ${timeout}s"
      echo "success=false" >> $GITHUB_OUTPUT
      exit 1
    fi

    resp=$(curl -s -w "\n%{http_code}" \
      "${API_URL}/api/v1/deploy/status?customer=${APP}&environment=${ENVIRONMENT}" \
      -H "Authorization: Bearer ${API_KEY}") || resp=$'\n000'
    code=$(echo "$resp" | tail -n1)
    body=$(echo "$resp" | sed '$d')

    if [ "$code" != "200" ]; then
      echo "  [${elapsed}s] status unavailable (HTTP ${code}), retrying"
      sleep "$poll"
      continue
    fi

    health=$(echo "$body" | jq -r '.data.healthStatus // "Unknown"')
    if [ "  [${elapsed}s] health=${health}" != "$last" ]; then
      last="  [${elapsed}s] health=${health}"
      echo "$last"
    fi

    # Every tag currently live for the environment. When the platform told us
    # which tag the promotion ships, Healthy alone is not done: right after the
    # promotion commit ArgoCD may still report the OLD revision as Healthy.
    tag_live=true
    if [ -n "${PROMOTED_TAG:-}" ]; then
      tag_live=false
      if echo "$body" | jq -e --arg t "$PROMOTED_TAG" '(.data.imageTags // []) | index($t) != null' >/dev/null 2>&1; then
        tag_live=true
      fi
    fi
    case "$health" in
      Healthy)
        if [ "$tag_live" != "true" ]; then
          if [ "  [${elapsed}s] health=Healthy on the previous revision — waiting for ${PROMOTED_TAG}" != "$last" ]; then
            last="  [${elapsed}s] health=Healthy on the previous revision — waiting for ${PROMOTED_TAG}"
            echo "$last"
          fi
          sleep "$poll"
          continue
        fi
        echo "::endgroup::"
        echo "success=true" >> $GITHUB_OUTPUT
        echo "✅ Promoted: $LABEL (${elapsed}s)"
        return 0
        ;;
      Degraded)
        if [ "$degraded_since" -lt 0 ]; then
          degraded_since=$elapsed
        elif [ $((elapsed - degraded_since)) -ge "$degraded_grace" ]; then
          echo "::endgroup::"
          echo "::error::Rollout degraded for ${degraded_grace}s during canary promotion — fix or abort the canary, then promote again"
          echo "success=false" >> $GITHUB_OUTPUT
          exit 1
        fi
        ;;
      *)
        degraded_since=-1
        ;;
    esac
    sleep "$poll"
  done
}

# Canary preview environments (platform 2026-09+): the platform promotes by a
# Git commit — the environment gets the preview's image and the preview closes
# — and answers 200 with the commit sha and the promoted tag. The rollout is
# then still in flight, so wait for the environment to be Healthy ON THAT TAG.
# The legacy in-Rollout promotion carries no commit sha and completes on the
# platform side; it is only waited for when the API says "converging".
if [ "${CANARY:-false}" = "true" ] && [ -n "$GIT_SHA" ] && [ -n "$NEW_TAG" ]; then
  echo "⏳ Promotion committed (${GIT_SHA:0:7}): waiting for ${NEW_TAG} to be live on ${ENVIRONMENT}"
  PROMOTED_TAG="$NEW_TAG" wait_for_promotion
elif [ "${CANARY:-false}" = "true" ] && { [ "$HTTP_CODE" -eq 202 ] || [ "$PROMOTION_STATE" = "converging" ]; }; then
  echo "⏳ Promotion accepted: $MESSAGE"
  wait_for_promotion
else
  echo "success=$SUCCESS" >> $GITHUB_OUTPUT
  echo "✅ Promoted: $LABEL"
  echo "$MESSAGE"
fi
