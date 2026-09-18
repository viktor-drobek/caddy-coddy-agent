#!/usr/bin/env bash
# Delete a Coddy user from Keycloak realm "coddy".
#
#   ./remove-user.sh <username>
#
# Their Keycloak sessions end at once; a browser that still holds a proxy cookie
# is signed out when oauth2-proxy next refreshes the token (within 5 minutes).
# Runs kcadm inside the keycloak container on @@EDGE_NAME@@ (admin credentials come
# from @@EDGE_DIR@@/.env there). Only realm "coddy" is touched.
set -euo pipefail

TARGET_HOST=${TARGET_HOST:-@@EDGE_SSH@@}
TARGET_DIR=${TARGET_DIR:-@@EDGE_DIR@@}

USERNAME=${1:-}
if [ -z "$USERNAME" ] || [ "$USERNAME" = "-h" ] || [ "$USERNAME" = "--help" ]; then
  echo "usage: $0 <username>" >&2
  exit 2
fi

ssh "$TARGET_HOST" "$(printf 'TARGET_DIR=%q U=%q bash -s' "$TARGET_DIR" "$USERNAME")" <<'REMOTE'
set -euo pipefail
cd "$TARGET_DIR"
set -a; . ./.env; set +a
sudo docker compose exec -T -e A="$KC_ADMIN_USER" -e P="$KC_ADMIN_PASSWORD" -e U="$U" keycloak bash -s <<'IN'
set -euo pipefail
K=/opt/keycloak/bin/kcadm.sh
$K config credentials --server "http://127.0.0.1:8080${KC_HTTP_RELATIVE_PATH:-/auth}" --realm master --user "$A" --password "$P" >/dev/null
id=$($K get users -r coddy -q username="$U" -q exact=true --fields id --format csv --noquotes | head -n1)
if [ -z "$id" ]; then echo "user '$U' does not exist in realm coddy" >&2; exit 1; fi
$K delete "users/$id" -r coddy
IN
REMOTE

echo "Removed user '$USERNAME' from realm coddy."
