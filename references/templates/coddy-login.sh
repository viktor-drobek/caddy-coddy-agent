#!/usr/bin/env bash
# Sign in to Keycloak with your Coddy username/password and get a Keycloak access
# token (valid 7 days) for the Coddy CLI and API clients.
#
#   eval "$(./coddy-login.sh alice)"     # asks for the password, exports CODDY_REMOTE_TOKEN, OPENAI_BASE_URL, OPENAI_API_KEY
#   coddy cli --remote @@PUBLIC_URL@@
#
#   ./coddy-login.sh alice --raw         # print only the token
#   CODDY_PASSWORD=... ./coddy-login.sh alice --raw   # non-interactive
#
# This is a Keycloak token, not Coddy's own API token: Caddy verifies it and
# swaps it for Coddy's token on every request. Nobody but the proxy ever holds
# Coddy's token. Needs curl only.
set -euo pipefail

BASE_URL=${CODDY_PUBLIC_URL:-@@PUBLIC_URL@@}
TOKEN_URL="$BASE_URL/auth/realms/coddy/protocol/openid-connect/token"

USERNAME=${1:-}
RAW=0
[ "${2:-}" = "--raw" ] && RAW=1
if [ -z "$USERNAME" ]; then
  echo "usage: $0 <username> [--raw]" >&2
  exit 2
fi

if [ -n "${CODDY_PASSWORD:-}" ]; then
  PASSWORD=$CODDY_PASSWORD
else
  read -rs -p "Keycloak password for $USERNAME: " PASSWORD </dev/tty
  echo >&2
fi

RESP=$(curl -sS -X POST "$TOKEN_URL" \
  -d grant_type=password -d client_id=coddy-cli -d scope=openid \
  --data-urlencode "username=$USERNAME" --data-urlencode "password=$PASSWORD")

TOKEN=$(printf '%s' "$RESP" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
if [ -z "$TOKEN" ]; then
  DESC=$(printf '%s' "$RESP" | sed -n 's/.*"error_description":"\([^"]*\)".*/\1/p')
  echo "login failed: ${DESC:-$RESP}" >&2
  case "$DESC" in
    *"not fully set up"*) echo "hint: sign in once at $BASE_URL/ in a browser to set a permanent password" >&2 ;;
  esac
  exit 1
fi
EXPIRES=$(printf '%s' "$RESP" | sed -n 's/.*"expires_in":\([0-9]*\).*/\1/p')

if [ "$RAW" = 1 ]; then
  printf '%s\n' "$TOKEN"
  exit 0
fi

cat <<OUT
export CODDY_REMOTE_TOKEN='$TOKEN'
export OPENAI_BASE_URL='$BASE_URL/v1'
export OPENAI_API_KEY='$TOKEN'
# Keycloak token for $USERNAME, valid $(( ${EXPIRES:-0} / 3600 ))h. Now: coddy cli --remote $BASE_URL
OUT
