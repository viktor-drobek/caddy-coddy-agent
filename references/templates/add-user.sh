#!/usr/bin/env bash
# Create a Coddy user in Keycloak realm "coddy" with a temporary password.
#
#   ./add-user.sh <username> [email]
#   ./add-user.sh --reset <username>                        # new temporary password for an existing user
#   TEMP_PASSWORD='...' ./add-user.sh <username> [email]   # choose the temp password
#
# The password is printed once; the user must change it at first login.
# Runs kcadm inside the keycloak container on @@EDGE_NAME@@ (admin credentials come
# from @@EDGE_DIR@@/.env there). Users MUST live in realm "coddy" — a user
# created in the master realm cannot sign in to Coddy.
set -euo pipefail

TARGET_HOST=${TARGET_HOST:-@@EDGE_SSH@@}
TARGET_DIR=${TARGET_DIR:-@@EDGE_DIR@@}

RESET=0
if [ "${1:-}" = "--reset" ]; then RESET=1; shift; fi
USERNAME=${1:-}
EMAIL=${2:-}
if [ -z "$USERNAME" ]; then
  echo "usage: $0 [--reset] <username> [email]" >&2
  exit 2
fi
PW=${TEMP_PASSWORD:-$(openssl rand -base64 15 | tr -d '/+=')}

ssh "$TARGET_HOST" "$(printf 'TARGET_DIR=%q U=%q E=%q PW=%q RESET=%q bash -s' "$TARGET_DIR" "$USERNAME" "$EMAIL" "$PW" "$RESET")" <<'REMOTE'
set -euo pipefail
cd "$TARGET_DIR"
set -a; . ./.env; set +a
sudo docker compose exec -T -e A="$KC_ADMIN_USER" -e P="$KC_ADMIN_PASSWORD" -e U="$U" -e E="$E" -e PW="$PW" -e RESET="$RESET" keycloak bash -s <<'IN'
set -euo pipefail
K=/opt/keycloak/bin/kcadm.sh
$K config credentials --server "http://127.0.0.1:8080${KC_HTTP_RELATIVE_PATH:-/auth}" --realm master --user "$A" --password "$P" >/dev/null
exists=$($K get users -r coddy -q username="$U" -q exact=true --fields id --format csv --noquotes | head -n1)
if [ "$RESET" = 1 ]; then
  if [ -z "$exists" ]; then echo "user '$U' does not exist in realm coddy" >&2; exit 1; fi
else
  if [ -n "$exists" ]; then echo "user '$U' already exists in realm coddy (use --reset for a new password)" >&2; exit 1; fi
  args=(-s "username=$U" -s enabled=true)
  if [ -n "$E" ]; then args+=(-s "email=$E" -s emailVerified=true); fi
  $K create users -r coddy "${args[@]}" >/dev/null
fi
$K set-password -r coddy --username "$U" --new-password "$PW" --temporary
IN
REMOTE

if [ "$RESET" = 1 ]; then echo "Password reset for '$USERNAME' in realm coddy."; else echo "Created user '$USERNAME' in realm coddy."; fi
echo "Temporary password (must be changed at first login): $PW"
echo "Sign in at @@PUBLIC_URL@@/"
