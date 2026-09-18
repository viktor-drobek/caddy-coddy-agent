#!/usr/bin/env bash
# List the users of Keycloak realm "coddy" as CSV: username, email, enabled.
#
#   ./list-users.sh
#
# Runs kcadm inside the keycloak container on @@EDGE_NAME@@ (admin credentials come
# from @@EDGE_DIR@@/.env there).
set -euo pipefail

TARGET_HOST=${TARGET_HOST:-@@EDGE_SSH@@}
TARGET_DIR=${TARGET_DIR:-@@EDGE_DIR@@}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "usage: $0" >&2
  exit 2
fi

echo "username,email,enabled"
ssh "$TARGET_HOST" "$(printf 'TARGET_DIR=%q bash -s' "$TARGET_DIR")" <<'REMOTE'
set -euo pipefail
cd "$TARGET_DIR"
set -a; . ./.env; set +a
sudo docker compose exec -T -e A="$KC_ADMIN_USER" -e P="$KC_ADMIN_PASSWORD" keycloak bash -s <<'IN'
set -euo pipefail
K=/opt/keycloak/bin/kcadm.sh
$K config credentials --server "http://127.0.0.1:8080${KC_HTTP_RELATIVE_PATH:-/auth}" --realm master --user "$A" --password "$P" >/dev/null
# kcadm pages at 100 by default; realms with more users than that need paging.
$K get users -r coddy -q max=1000 --fields username,email,enabled --format csv --noquotes
IN
REMOTE
