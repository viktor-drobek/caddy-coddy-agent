#!/usr/bin/env bash
# deploy.sh — Wrapper around caddy-coddy deploy with pre-flight validation.
set -euo pipefail

REPO=${1:-}
if [ -z "$REPO" ]; then
  echo "usage: $0 <path-to-caddy-coddy-repo>" >&2
  exit 2
fi

cd "$REPO"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Pre-flight validation
echo "[deploy] Running validation..."
"$SCRIPT_DIR/validate.sh" "$REPO"

# Safety checks
echo "[deploy] Checking .env exists on superset..."
ssh huron@192.168.135.10 'cd /opt/caddy-coddy && [ -f .env ] && echo OK || { echo "MISSING .env" >&2; exit 1; }'

# Run the real deploy
echo "[deploy] Starting deploy..."
./deploy.sh

echo "[deploy] Done. Run tests/smoke.sh to accept."
