#!/usr/bin/env bash
# validate.sh — Pre-deploy validation for caddy-coddy configs.
#
# Runs every validator that is available locally or on the reachable remote host.
# Usage: ./scripts/validate.sh <path-to-caddy-coddy-repo>
set -euo pipefail

REPO=${1:-}
if [ -z "$REPO" ]; then
  echo "usage: $0 <path-to-caddy-coddy-repo>" >&2
  exit 2
fi

cd "$REPO"

PASS=0
FAIL=0

run() {
  local label=$1
  shift
  if "$@"; then
    echo "  PASS  $label"
    ((PASS+=1))
  else
    echo "  FAIL  $label"
    ((FAIL+=1))
  fi
}

echo "=== Shell syntax ==="
for f in deploy.sh add-user.sh keycloak/bootstrap.sh tests/smoke.sh tests/smoke-remote.sh coddy-login.sh coddy-token.sh sync-coddy-token.sh; do
  [ -f "$f" ] && run "$f" bash -n "$f" || echo "  SKIP  $f (not found)"
done

echo "=== JSON well-formedness ==="
for f in keycloak/import/realm-coddy.json keycloak/client-coddy-cli.json; do
  [ -f "$f" ] && run "$f" jq . "$f" > /dev/null || echo "  SKIP  $f (not found)"
done

echo "=== docker compose config ==="
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  run "docker-compose.yml" docker compose config -q
else
  echo "  SKIP  docker compose config (not available on this host, run on superset)"
fi

echo "=== Caddyfile ==="
if command -v caddy &>/dev/null; then
  run "Caddyfile" caddy validate --adapter caddyfile --config Caddyfile
else
  echo "  SKIP  caddy validate (not available on this host, run on superset or in caddy container)"
fi

echo "=== shellcheck (optional) ==="
if command -v shellcheck &>/dev/null; then
  for f in deploy.sh add-user.sh keycloak/bootstrap.sh tests/smoke.sh; do
    [ -f "$f" ] && run "shellcheck $f" shellcheck "$f"
  done
else
  echo "  SKIP  shellcheck (not installed)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
