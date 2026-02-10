#!/usr/bin/env bash
set -euo pipefail

if [ -f "$CONFIG_FILE" ]; then
  echo "Found config file: $CONFIG_FILE"
  if command -v yq &> /dev/null; then
    ENV_CONFIG=$(yq -o=json -I=0 ".environments.$ENVIRONMENT // {}" "$CONFIG_FILE")
  else
    ENV_CONFIG=$(python3 -c "
import yaml, json, os, sys
with open(os.environ['CONFIG_FILE']) as f:
    data = yaml.safe_load(f)
    env_config = data.get('environments', {}).get(os.environ['ENVIRONMENT'], {})
    print(json.dumps(env_config, separators=(',', ':')))
" 2>/dev/null || echo "{}")
  fi
  echo "config=$ENV_CONFIG" >> $GITHUB_OUTPUT
else
  echo "No config file found, using defaults"
  echo "config={}" >> $GITHUB_OUTPUT
fi
