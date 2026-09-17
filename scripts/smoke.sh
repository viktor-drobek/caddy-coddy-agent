#!/usr/bin/env bash
# smoke.sh — Run E2E smoke tests against the deployed stack.
set -euo pipefail

REPO=${1:-}
if [ -z "$REPO" ]; then
  echo "usage: $0 <path-to-caddy-coddy-repo>" >&2
  exit 2
fi

cd "$REPO" && tests/smoke.sh "$@"
