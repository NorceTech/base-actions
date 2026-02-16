#!/usr/bin/env bash
set -euo pipefail

echo "::group::⏳ Waiting for deployment to become healthy (timeout: ${TIMEOUT}s)"

START_TIME=$(date +%s)
POLL_INTERVAL=10
SYNC_GRACE=30
LAST_STATUS=""

while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))

  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════"
    echo "║ ⏰ HEALTH CHECK TIMEOUT (${TIMEOUT}s)"
    echo "╠══════════════════════════════════════════════════════"
    echo "║ The deployment was submitted to Git successfully,"
    echo "║ but the pods did not become healthy in time."
    echo "║"
    echo "║ Last status: Health=${LAST_HEALTH:-Unknown}, Sync=${LAST_SYNC:-Unknown}"
    echo "║ Expected tag: $IMAGE_TAG"
    echo "║ Current tag:  ${LAST_TAG:-unknown}"
    echo "║"
    echo "║ Common causes:"
    echo "║   • Image pull error (wrong tag or ACR permissions)"
    echo "║   • Application crash loop (check pod logs)"
    echo "║   • Health/readiness probe failing"
    echo "║   • Sync still in progress (try increasing wait_timeout)"
    echo "╚══════════════════════════════════════════════════════"
    echo ""
    echo "::endgroup::"
    echo "::error::Timeout after ${TIMEOUT}s — Health: ${LAST_HEALTH:-Unknown}, Sync: ${LAST_SYNC:-Unknown}"
    echo "health_status=Timeout" >> $GITHUB_OUTPUT
    echo "sync_status=${LAST_SYNC:-Unknown}" >> $GITHUB_OUTPUT
    echo "healthy=false" >> $GITHUB_OUTPUT
    exit 1
  fi

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    "${API_URL}/api/v1/deploy/status?customer=${CUSTOMER}&environment=${ENVIRONMENT}" \
    -H "Authorization: Bearer ${API_KEY}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" -ne 200 ]; then
    echo "  Warning: Failed to get deployment status (HTTP $HTTP_CODE), retrying..."
    sleep $POLL_INTERVAL
    continue
  fi

  HEALTH=$(echo "$BODY" | jq -r '.data.healthStatus // "Unknown"')
  SYNC=$(echo "$BODY" | jq -r '.data.syncStatus // "Unknown"')
  CURRENT_TAG=$(echo "$BODY" | jq -r '.data.imageTag // "unknown"')

  LAST_HEALTH="$HEALTH"
  LAST_SYNC="$SYNC"
  LAST_TAG="$CURRENT_TAG"

  STATUS_LINE="  [${ELAPSED}s] Health: ${HEALTH}, Sync: ${SYNC}, Tag: ${CURRENT_TAG}"

  if [ "$STATUS_LINE" != "$LAST_STATUS" ]; then
    echo "$STATUS_LINE"
    LAST_STATUS="$STATUS_LINE"
  fi

  # Suspended = blue-green preview deployed, waiting for manual promotion.
  # This is the expected end state when preview/blue-green is enabled.
  # The reported tag may still be the old stable tag (ArgoCD reports stable image),
  # so we don't require tag match — Suspended after sync means the preview is ready.
  if [ "$HEALTH" == "Suspended" ]; then
    if [ "$SYNC" == "Synced" ]; then
      # Derive preview URL from namespace: {partner}-{customer}-{env}
      # Preview URL: preview-{customer}-{env}.{partner}.base.norce.tech
      PREVIEW_URL=""
      if [ -n "${NAMESPACE:-}" ]; then
        # Extract partner (first segment) and the rest (customer-environment)
        PARTNER=$(echo "$NAMESPACE" | cut -d'-' -f1)
        CUSTOMER_ENV=$(echo "$NAMESPACE" | cut -d'-' -f2-)
        PREVIEW_URL="https://preview-${CUSTOMER_ENV}.${PARTNER}.base.norce.tech"
      fi

      echo "::endgroup::"
      echo "✅ Preview deployed and awaiting promotion! (${ELAPSED}s)"
      if [ -n "$PREVIEW_URL" ]; then
        echo "   Preview URL: $PREVIEW_URL"
      fi
      echo "   Promote via Base Portal or API when ready."
      echo "health_status=$HEALTH" >> $GITHUB_OUTPUT
      echo "sync_status=$SYNC" >> $GITHUB_OUTPUT
      echo "healthy=true" >> $GITHUB_OUTPUT
      echo "preview_url=$PREVIEW_URL" >> $GITHUB_OUTPUT
      exit 0
    fi

    # Suspended but not yet synced — give ArgoCD time
    sleep $POLL_INTERVAL
    continue
  fi

  if [ "$HEALTH" == "Healthy" ] && [ "$CURRENT_TAG" == "$IMAGE_TAG" ]; then
    if [ "$SYNC" == "Synced" ]; then
      echo "::endgroup::"
      echo "✅ Deployment healthy and synced! (${ELAPSED}s)"
      echo "health_status=$HEALTH" >> $GITHUB_OUTPUT
      echo "sync_status=$SYNC" >> $GITHUB_OUTPUT
      echo "healthy=true" >> $GITHUB_OUTPUT
      exit 0
    fi

    # Healthy + correct tag but OutOfSync.
    # Give ArgoCD time to sync the new Git commit before assuming drift.
    if [ $ELAPSED -lt $SYNC_GRACE ]; then
      sleep $POLL_INTERVAL
      continue
    fi

    # Past grace period — likely KEDA replica drift or similar controller drift.
    echo "::endgroup::"
    echo "✅ Deployment healthy! (${ELAPSED}s) (Sync: ${SYNC} — likely KEDA replica drift)"
    echo "health_status=$HEALTH" >> $GITHUB_OUTPUT
    echo "sync_status=$SYNC" >> $GITHUB_OUTPUT
    echo "healthy=true" >> $GITHUB_OUTPUT
    exit 0
  fi

  if [ "$HEALTH" == "Degraded" ] || [ "$HEALTH" == "Missing" ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════"
    echo "║ ❌ DEPLOYMENT UNHEALTHY — $HEALTH"
    echo "╠══════════════════════════════════════════════════════"
    echo "║ Sync: $SYNC | Tag: $CURRENT_TAG | Time: ${ELAPSED}s"
    echo "║"
    if [ "$HEALTH" == "Missing" ]; then
      echo "║ The application for this environment was not found."
      echo "║ Verify the environment name is correct in Base Portal."
    else
      echo "║ The deployment is degraded — pods are crashing or"
      echo "║ failing health checks."
    fi
    echo "║"
    echo "║ Check the Base Portal Health tab for details."
    echo "╚══════════════════════════════════════════════════════"
    echo "::endgroup::"
    echo ""
    echo "::error::Deployment $HEALTH — Sync: $SYNC, Tag: $CURRENT_TAG"
    echo "health_status=$HEALTH" >> $GITHUB_OUTPUT
    echo "sync_status=$SYNC" >> $GITHUB_OUTPUT
    echo "healthy=false" >> $GITHUB_OUTPUT
    exit 1
  fi

  sleep $POLL_INTERVAL
done
