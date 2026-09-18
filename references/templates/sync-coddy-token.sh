#!/usr/bin/env bash
# Copy Coddy's own API token (httpserver.auth_token in Coddy's config on this
# box) into the proxy's .env on @@EDGE_NAME@@ (CODDY_API_TOKEN) and restart Caddy.
#
#   ./sync-coddy-token.sh          # run on @@CODDY_HOST_NAME@@ after the token in Coddy's config changed
#
# Caddy presents this token to Coddy on behalf of every authenticated Keycloak
# user or service; nobody else needs it. Reads, in order: $CODDY_HTTP_TOKEN,
# then httpserver.auth_token from $CODDY_CONFIG (default $CODDY_HOME/config.yaml,
# $CODDY_HOME default ~/.coddy), resolving a "${ENV}" reference.
set -euo pipefail

TARGET_HOST=${TARGET_HOST:-@@EDGE_SSH@@}
TARGET_DIR=${TARGET_DIR:-@@EDGE_DIR@@}
CODDY_HOME=${CODDY_HOME:-$HOME/.coddy}
CONFIG=${CODDY_CONFIG:-$CODDY_HOME/config.yaml}
CODDY_LOCAL=${CODDY_LOCAL:-@@CODDY_LOCAL_URL@@}

TOKEN=${CODDY_HTTP_TOKEN:-}
if [ -z "$TOKEN" ]; then
  TOKEN=$(sed -n -E 's/^[[:space:]]+auth_token:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' "$CONFIG" | head -n1)
fi
case "$TOKEN" in
  '${'*'}')
    var=${TOKEN#'${'}; var=${var%'}'}
    TOKEN=${!var:-}
    [ -n "$TOKEN" ] || { echo "config references \${$var} but it is not set" >&2; exit 1; }
    ;;
esac
if [ -z "$TOKEN" ]; then
  echo "no httpserver.auth_token in $CONFIG and CODDY_HTTP_TOKEN is unset" >&2
  exit 1
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$CODDY_LOCAL/coddy/sessions" || true)
if [ "$code" != 200 ]; then
  echo "coddy at $CODDY_LOCAL rejected the token from $CONFIG (HTTP $code); is coddy serve restarted with the new config?" >&2
  exit 1
fi
echo "token accepted by coddy at $CODDY_LOCAL"

ssh "$TARGET_HOST" "$(printf 'TARGET_DIR=%q T=%q bash -s' "$TARGET_DIR" "$TOKEN")" <<'REMOTE'
set -euo pipefail
cd "$TARGET_DIR"
current=$(sed -n 's/^CODDY_API_TOKEN=//p' .env | head -n1)
if [ "$current" = "$T" ]; then
  echo "CODDY_API_TOKEN in $TARGET_DIR/.env is already up to date"
else
  cp -p .env ".env.bak.$(date +%s)"
  if grep -q '^CODDY_API_TOKEN=' .env; then
    sed -i "s|^CODDY_API_TOKEN=.*|CODDY_API_TOKEN=$T|" .env
  else
    printf 'CODDY_API_TOKEN=%s\n' "$T" >> .env
  fi
  chmod 600 .env
  sudo docker compose up -d --force-recreate caddy >/dev/null 2>&1
  echo "CODDY_API_TOKEN updated and caddy restarted"
fi

# Verify end to end with a Keycloak service token (the proxy must swap it for the new Coddy token).
set -a; . ./.env; set +a
for _ in $(seq 1 20); do
  [ "$(sudo docker inspect -f '{{.State.Health.Status}}' caddy-coddy 2>/dev/null)" = healthy ] && break
  sleep 2
done
KC=$(curl -s --resolve "$PUBLIC_HOST:443:127.0.0.1" -X POST "$KC_HOSTNAME/realms/coddy/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id=coddy-service -d client_secret="$CODDY_SERVICE_CLIENT_SECRET" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
me=$(curl -s --resolve "$PUBLIC_HOST:443:127.0.0.1" -H "Authorization: Bearer $KC" "$PUBLIC_URL/coddy/auth/me")
case "$me" in
  *'"authenticated":true'*) echo "verified: $PUBLIC_URL/coddy/auth/me -> authenticated with a Keycloak token" ;;
  *) echo "verification FAILED: $me" >&2; exit 1 ;;
esac
REMOTE
