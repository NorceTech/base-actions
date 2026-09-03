#!/usr/bin/env bash
set -euo pipefail

# Which release of this action is actually executing.
#
# Partners pin the moving `v1` tag — that is deliberate, we cannot ask them to bump a
# pin on every minor. The cost is that a runner which caches
# `_work/_actions/<owner>/<repo>/v1` can keep serving an old release long after `v1`
# has moved. On 2026-08-21 a partner ran v1.0.x code while `v1` had pointed at v1.1.1
# for 16 days, and it took timing forensics against a mock API to establish that.
# Printing the version makes that a one-line read in the job log instead.
#
# VERSION is written into the published tree by the release workflow, so an
# unreleased/internal checkout correctly reports "dev".
action_version() {
  local vf="${GITHUB_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../VERSION"
  if [ -f "$vf" ]; then
    cat "$vf"
  else
    echo "dev"
  fi
}

echo "::group::⏳ Waiting for deployment to become healthy (timeout: ${TIMEOUT}s)"

START_TIME=$(date +%s)
POLL_INTERVAL=${POLL_INTERVAL:-10}
SYNC_GRACE=${SYNC_GRACE:-30}
LAST_STATUS=""
UNKNOWN_WARNED=false
TAG_WAIT_WARNED=false
# There is deliberately no TAG_GRACE any more.
#
# The status endpoint reports the health of whatever is LIVE. While our tag is not
# live, that verdict describes the PREVIOUS release, not this deploy — so no amount
# of elapsed time makes it "genuinely ours", which is what the old TAG_GRACE=60
# assumed. Base aborts a paused canary *before* writing our commit, so this window
# is Degraded by construction, and ArgoCD reconcile latency on the shared controller
# measured 6m23s–11m23s in 5 of 8 partnersense prod deploys (2026-08-19..21).
# A 60s grace turned "ArgoCD is busy" into "your deploy is broken".
#
# We now keep waiting while our tag is not live; TIMEOUT is the only backstop. A
# genuinely broken release still fails fast, because once our tag IS live a
# crash-loop trips DEGRADED_GRACE below within a minute.
#
# DEGRADED_GRACE tolerates a transient Degraded *after* our tag is live — a new
# ReplicaSet starting up, image pull, probes not yet green. The streak resets only on
# Healthy, not on Progressing, so an oscillating crash-loop still accumulates.
DEGRADED_GRACE=${DEGRADED_GRACE:-60}
DEGRADED_SINCE=-1   # ELAPSED at which the current Degraded streak began (-1 = none)

MIN_USEFUL_TIMEOUT=$((DEGRADED_GRACE + SYNC_GRACE + 30))
if [ "$TIMEOUT" -lt "$MIN_USEFUL_TIMEOUT" ]; then
  echo "::warning::TIMEOUT=${TIMEOUT}s is less than combined grace periods (${MIN_USEFUL_TIMEOUT}s) — a degraded deployment may always timeout rather than fail fast. Consider increasing wait_timeout."
fi

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
    echo "║ Action version: $(action_version)"
    echo "║ Last status: Health=${LAST_HEALTH:-Unknown}, Sync=${LAST_SYNC:-Unknown}"
    echo "║ Expected tag: $IMAGE_TAG"
    echo "║ Current tag:  ${LAST_TAG:-unknown}"
    echo "║"
    echo "║ Common causes:"
    if [ "${LAST_HEALTH:-Unknown}" == "Unknown" ] && [ "${LAST_SYNC:-Unknown}" == "Unknown" ]; then
    echo "║   • New environment — platform is still provisioning it"
    echo "║   • The deploy is submitted and will go live automatically"
    echo "║   • Check the Base Portal for status"
    fi
    if [ "${LAST_TAG:-unknown}" != "$IMAGE_TAG" ] && [ "${LAST_TAG:-unknown}" != "unknown" ]; then
    echo "║   • ArgoCD never reconciled ${IMAGE_TAG} — cluster still on ${LAST_TAG}"
    echo "║     (check ArgoCD for the Application, or retry)"
    fi
    if [ "${LAST_TAG:-unknown}" == "unknown" ]; then
    echo "║   • No image is live for this app/environment — check that"
    echo "║     app and environment are spelled the way Base knows them"
    fi
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
    "${API_URL}/api/v1/deploy/status?customer=${APP}&environment=${ENVIRONMENT}" \
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

  # `imageTags` is EVERY tag currently live for this Application — during a rollout
  # that is both the old and the new ReplicaSet. Ask the question we actually care
  # about ("is MY tag live?") by membership, rather than equality against the single
  # `imageTag` field, which falls back to an arbitrary live tag when Base's record
  # and the cluster disagree. Older API versions omit the array — fall back to
  # equality there so this action keeps working against them.
  LIVE_TAGS=$(echo "$BODY" | jq -r '.data.imageTags // [] | .[]' 2>/dev/null || true)
  if [ -n "$LIVE_TAGS" ]; then
    if printf '%s\n' "$LIVE_TAGS" | grep -qxF -- "$IMAGE_TAG"; then
      TAG_LIVE=true
    else
      TAG_LIVE=false
    fi
  elif [ "$CURRENT_TAG" == "$IMAGE_TAG" ]; then
    TAG_LIVE=true
  else
    TAG_LIVE=false
  fi

  LAST_HEALTH="$HEALTH"
  LAST_SYNC="$SYNC"
  LAST_TAG="$CURRENT_TAG"

  # Reset the Degraded streak on Healthy. Progressing is a pod restarting, not
  # a recovery — resetting on it would let a crash-loop oscillate indefinitely
  # without accumulating toward DEGRADED_GRACE. Suspended exits before reaching
  # the Degraded block, so no reset is needed there.
  if [ "$HEALTH" == "Healthy" ]; then
    DEGRADED_SINCE=-1
  fi

  STATUS_LINE="  [${ELAPSED}s] Health: ${HEALTH}, Sync: ${SYNC}, Tag: ${CURRENT_TAG}"

  if [ "$STATUS_LINE" != "$LAST_STATUS" ]; then
    echo "$STATUS_LINE"
    LAST_STATUS="$STATUS_LINE"
  fi

  # Suspended = staged/canary preview deployed, waiting for manual promotion.
  # When Synced, this is the expected end state for staged deployments.
  # When OutOfSync, ArgoCD may still be syncing a strategy change (e.g. auto_promote
  # was just toggled), so we keep polling during the grace period to let it resolve.
  if [ "$HEALTH" == "Suspended" ]; then
    if [ "$SYNC" != "Synced" ] && [ $ELAPSED -lt $SYNC_GRACE ]; then
      # ArgoCD hasn't synced yet — the strategy may change (Suspended → Healthy)
      sleep $POLL_INTERVAL
      continue
    fi

    # Suspended only means "a canary is paused" — not necessarily OURS. If Base's
    # replace-on-deploy abort failed, the PREVIOUS release's canary is still paused
    # and reporting Suspended. Exiting green there would tell the partner their
    # release is staged when nothing of theirs reached the cluster. Keep waiting
    # until our tag is actually live.
    if [ "$TAG_LIVE" != "true" ]; then
      if [ "$TAG_WAIT_WARNED" == "false" ]; then
        TAG_WAIT_WARNED=true
        echo "  ⏳ A canary is paused but it is not ${IMAGE_TAG} (live: ${CURRENT_TAG}) — waiting for this deploy to reach the cluster"
      fi
      sleep $POLL_INTERVAL
      continue
    fi

    # The platform reports the preview URL on the deploy response; derive it
    # from the namespace ({partner}-{app}-{env}) only for platform versions
    # that do not. Both give preview-{app}-{env}.{partner}.base.norce.tech.
    PREVIEW_URL="${DEPLOY_PREVIEW_URL:-}"
    if [ -z "$PREVIEW_URL" ] && [ -n "${NAMESPACE:-}" ]; then
      # The platform always reports the BASE environment's namespace here, even
      # when the canary runs as its own "<namespace>-preview" environment; strip
      # the suffix defensively so a preview namespace can never yield
      # "preview-<app>-<env>-preview".
      BASE_NAMESPACE="${NAMESPACE%-preview}"
      PARTNER=$(echo "$BASE_NAMESPACE" | cut -d'-' -f1)
      APP_ENV=$(echo "$BASE_NAMESPACE" | cut -d'-' -f2-)
      PREVIEW_URL="https://preview-${APP_ENV}.${PARTNER}.base.norce.tech"
    fi

    echo "::endgroup::"
    echo "::warning::Canary staged — traffic has NOT shifted to the new version. (${ELAPSED}s)"
    echo "   auto_promote=false — manual promotion required."
    if [ -n "$PREVIEW_URL" ]; then
      echo "   Preview URL: $PREVIEW_URL"
    fi
    echo "   Promote via Base Portal or CI/CD when ready."
    echo "health_status=$HEALTH" >> $GITHUB_OUTPUT
    echo "sync_status=$SYNC" >> $GITHUB_OUTPUT
    echo "healthy=suspended" >> $GITHUB_OUTPUT
    echo "preview_url=$PREVIEW_URL" >> $GITHUB_OUTPUT
    exit 0
  fi

  if [ "$HEALTH" == "Healthy" ] && [ "$TAG_LIVE" == "true" ]; then
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

  # New environment: platform is still provisioning the deployment target
  if [ "$HEALTH" == "Unknown" ] && [ "$SYNC" == "Unknown" ] && [ "$UNKNOWN_WARNED" == "false" ] && [ $ELAPSED -ge 30 ]; then
    UNKNOWN_WARNED=true
    echo "  ℹ️  Environment not found yet — platform is provisioning the new environment..."
  fi

  # Our tag is not live yet, so everything reported above describes the release we
  # are REPLACING. Never fail-fast on it — see the TAG_GRACE note at the top.
  if [ "$TAG_LIVE" != "true" ]; then
    if [ "$TAG_WAIT_WARNED" == "false" ]; then
      TAG_WAIT_WARNED=true
      echo "  ⏳ ArgoCD hasn't picked up ${IMAGE_TAG} yet (live: ${CURRENT_TAG}) — health above describes the previous release, not this deploy"
    fi
    sleep $POLL_INTERVAL
    continue
  fi

  if [ "$HEALTH" == "Degraded" ] || [ "$HEALTH" == "Missing" ]; then
    # Tolerate transient Degraded/Missing during a rollout: start (or continue)
    # the streak and keep polling until it has persisted for DEGRADED_GRACE.
    if [ "$DEGRADED_SINCE" -lt 0 ]; then
      DEGRADED_SINCE=$ELAPSED
    fi
    DEGRADED_FOR=$((ELAPSED - DEGRADED_SINCE))
    if [ $DEGRADED_FOR -lt $DEGRADED_GRACE ]; then
      echo "  ⏳ $HEALTH for ${DEGRADED_FOR}s (tolerating up to ${DEGRADED_GRACE}s) — deployment may still be initialising (new ReplicaSet starting, or Application not yet created)..."
      sleep $POLL_INTERVAL
      continue
    fi

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
