#!/usr/bin/env bash
set -euo pipefail

if [ "$DEPLOY_SUCCESS" != "true" ]; then
  echo "success=false" >> $GITHUB_OUTPUT
  echo "message=Deployment failed to submit" >> $GITHUB_OUTPUT
  exit 0
fi

if [ "$WAIT_ENABLED" == "true" ]; then
  if [ "$HEALTHY" == "true" ]; then
    echo "success=true" >> $GITHUB_OUTPUT
    echo "message=Deployment complete and healthy" >> $GITHUB_OUTPUT
  else
    echo "success=false" >> $GITHUB_OUTPUT
    echo "message=Deployment failed - Health: ${HEALTH_STATUS:-Unknown}" >> $GITHUB_OUTPUT
  fi
else
  echo "success=true" >> $GITHUB_OUTPUT
  echo "message=$DEPLOY_MESSAGE" >> $GITHUB_OUTPUT
fi
