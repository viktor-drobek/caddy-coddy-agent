#!/usr/bin/env bash
# Deploy this checkout to the @@EDGE_NAME@@ edge box and (re)start the stack.
#
#   ./deploy.sh              # rsync + docker compose up -d + Keycloak bootstrap
#   TARGET_HOST=... ./deploy.sh
#
# Prerequisites on @@EDGE_NAME@@: docker + compose, passwordless sudo for the ssh
# user, and @@EDGE_DIR@@/.env filled in from .env.example (never synced; the
# caddy-coddy agent's init-env.sh generates it on the first deploy).
set -euo pipefail

TARGET_HOST=${TARGET_HOST:-@@EDGE_SSH@@}
TARGET_DIR=${TARGET_DIR:-@@EDGE_DIR@@}

cd "$(dirname "$0")"

# Only the stack goes to the edge: no git, no secrets, no agent checkouts or
# rule trees, no manifest, and README.md as the only markdown.
changed=$(rsync -a --delete --itemize-changes \
  --exclude .git --exclude .env --exclude '*.bak*' \
  --exclude memory --exclude .relay --exclude tools --exclude .coddy \
  --exclude .cursor --exclude .claude --exclude .codex --exclude caddy-coddy.yml \
  --include README.md --exclude '__pycache__' --exclude '*.md' \
  ./ "$TARGET_HOST:$TARGET_DIR/")
THEME_CHANGED=0
if grep -q 'keycloak/themes/' <<<"$changed"; then THEME_CHANGED=1; fi
PROXY_CHANGED=0
if grep -q 'oauth2-proxy/' <<<"$changed"; then PROXY_CHANGED=1; fi
TG_CHANGED=0
if grep -q 'tg-auth/' <<<"$changed"; then TG_CHANGED=1; fi
CADDY_CHANGED=0
if grep -qE '^[^ ]+ Caddyfile$' <<<"$changed"; then CADDY_CHANGED=1; fi

ssh "$TARGET_HOST" "$(printf 'TARGET_DIR=%q THEME_CHANGED=%q PROXY_CHANGED=%q CADDY_CHANGED=%q TG_CHANGED=%q bash -s' "$TARGET_DIR" "$THEME_CHANGED" "$PROXY_CHANGED" "$CADDY_CHANGED" "$TG_CHANGED")" <<'REMOTE'
set -euo pipefail
cd "$TARGET_DIR"
if [ ! -f .env ]; then
  echo "missing $TARGET_DIR/.env — copy .env.example and fill in the secrets" >&2
  exit 1
fi
sudo docker compose pull -q
sudo docker compose up -d --remove-orphans

if [ "$CADDY_CHANGED" = 1 ]; then
  # rsync replaces the file's inode. Recreate the container so its single-file
  # bind mount sees the new Caddyfile and Caddy loads the updated routes.
  echo "Caddyfile changed: recreating caddy"
  sudo docker compose up -d --no-deps --force-recreate caddy
fi

if [ "$TG_CHANGED" = 1 ]; then
  echo "tg-auth changed: restarting tg-auth"
  sudo docker compose restart tg-auth
fi

if [ "$PROXY_CHANGED" = 1 ]; then
  echo "oauth2-proxy config changed: restarting oauth2-proxy"
  sudo docker compose restart oauth2-proxy
fi

if [ "$THEME_CHANGED" = 1 ]; then
  # Keycloak keeps gzipped theme files in data/tmp/kc-gzip-cache (survives a
  # restart, served to clients that accept gzip, i.e. through Caddy) and the
  # theme itself in memory: drop both so the new theme is what gets served.
  echo "theme changed: clearing Keycloak gzip cache and restarting keycloak"
  # </dev/null: `compose exec` attaches stdin and would otherwise swallow the rest
  # of this script, which arrives over stdin (bash -s).
  sudo docker compose exec -T keycloak rm -rf /opt/keycloak/data/tmp/kc-gzip-cache </dev/null || true
  sudo docker compose restart keycloak
fi

echo "waiting for keycloak to become healthy..."
status=
for _ in $(seq 1 60); do
  status=$(sudo docker inspect -f '{{.State.Health.Status}}' keycloak 2>/dev/null || true)
  [ "$status" = healthy ] && break
  sleep 5
done
if [ "$status" != healthy ]; then
  echo "keycloak is not healthy ($status)" >&2
  sudo docker compose logs --tail 60 keycloak >&2
  exit 1
fi

# Right after (re)start Keycloak may still answer 503 while importing realms
# even though its readiness probe already passed — retry for a while.
echo "running keycloak bootstrap..."
ok=
for attempt in 1 2 3 4 5 6; do
  if sudo docker compose exec -T keycloak bash -s < keycloak/bootstrap.sh; then
    ok=1
    break
  fi
  echo "bootstrap attempt $attempt failed (keycloak may still be starting); retrying in 10s" >&2
  sleep 10
done
[ -n "$ok" ] || { echo "keycloak bootstrap failed" >&2; exit 1; }
sudo docker compose ps
REMOTE
