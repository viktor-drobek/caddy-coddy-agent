#!/usr/bin/env bash
# Create a machine client in Keycloak realm "coddy" for the OAuth2 client_credentials
# grant, with the "coddy-web" audience mapper the proxy requires, and print its
# secret once. Or issue a new secret for an existing client.
#
#   ./add-service.sh <client-id> [name]              # e.g. ./add-service.sh reporting-bot "Nightly reports"
#   ./add-service.sh --rotate <client-id>            # new secret for an existing client
#   CLIENT_SECRET='...' ./add-service.sh <client-id> # choose the secret yourself
#
# The service then gets a token (valid 15 minutes, the realm's accessTokenLifespan):
#   curl -s -X POST @@PUBLIC_URL@@/auth/realms/coddy/protocol/openid-connect/token \
#     -d grant_type=client_credentials -d client_id=<client-id> -d client_secret=<secret>
#
# Runs kcadm inside the keycloak container on @@EDGE_NAME@@ (admin credentials come
# from @@EDGE_DIR@@/.env there).
set -euo pipefail

TARGET_HOST=${TARGET_HOST:-@@EDGE_SSH@@}
TARGET_DIR=${TARGET_DIR:-@@EDGE_DIR@@}

ROTATE=0
if [ "${1:-}" = "--rotate" ]; then ROTATE=1; shift; fi
CLIENT=${1:-}
NAME=${2:-$CLIENT}
if [ -z "$CLIENT" ] || [ "$CLIENT" = "-h" ] || [ "$CLIENT" = "--help" ]; then
  echo "usage: $0 [--rotate] <client-id> [name]" >&2
  exit 2
fi
case "$CLIENT" in
  coddy-web|coddy-cli) echo "'$CLIENT' is a login client of the stack, not a service client" >&2; exit 2 ;;
esac
SECRET=${CLIENT_SECRET:-$(openssl rand -hex 32)}

ssh "$TARGET_HOST" "$(printf 'TARGET_DIR=%q C=%q N=%q S=%q ROTATE=%q bash -s' "$TARGET_DIR" "$CLIENT" "$NAME" "$SECRET" "$ROTATE")" <<'REMOTE'
set -euo pipefail
cd "$TARGET_DIR"
set -a; . ./.env; set +a
sudo docker compose exec -T -e A="$KC_ADMIN_USER" -e P="$KC_ADMIN_PASSWORD" -e C="$C" -e N="$N" -e S="$S" -e ROTATE="$ROTATE" keycloak bash -s <<'IN'
set -euo pipefail
K=/opt/keycloak/bin/kcadm.sh
$K config credentials --server "http://127.0.0.1:8080${KC_HTTP_RELATIVE_PATH:-/auth}" --realm master --user "$A" --password "$P" >/dev/null
id=$($K get clients -r coddy -q clientId="$C" --fields id --format csv --noquotes | head -n1)
if [ "$ROTATE" = 1 ]; then
  if [ -z "$id" ]; then echo "client '$C' does not exist in realm coddy" >&2; exit 1; fi
else
  if [ -n "$id" ]; then echo "client '$C' already exists in realm coddy (use --rotate for a new secret)" >&2; exit 1; fi
  # Confidential client with a service account only: no browser flow, no password grant.
  id=$($K create clients -r coddy -i -s clientId="$C" -s name="$N" -s enabled=true -s publicClient=false \
    -s clientAuthenticatorType=client-secret -s standardFlowEnabled=false -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=true)
  # oauth2-proxy accepts a token only when its audience includes coddy-web.
  $K create "clients/$id/protocol-mappers/models" -r coddy -s name="audience coddy-web" \
    -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper -s consentRequired=false \
    -s 'config."included.client.audience"=coddy-web' -s 'config."id.token.claim"=false' \
    -s 'config."access.token.claim"=true' -s 'config."introspection.token.claim"=true' >/dev/null
fi
$K update "clients/$id" -r coddy -s secret="$S"
IN
REMOTE

if [ "$ROTATE" = 1 ]; then
  echo "New secret set for client '$CLIENT' in realm coddy."
else
  echo "Created service client '$CLIENT' in realm coddy (client_credentials, audience coddy-web)."
fi
echo "Client secret (shown once; keep it in the service's secret store): $SECRET"
