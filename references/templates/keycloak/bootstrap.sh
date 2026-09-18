#!/usr/bin/env bash
# Idempotent post-start configuration of realm "coddy" that must not live in
# realm-coddy.json: client secrets and the first user (both from .env).
# Runs INSIDE the keycloak container, fed over stdin (deploy.sh does this):
#   sudo docker compose exec -T keycloak bash -s < keycloak/bootstrap.sh
set -euo pipefail

KCADM=/opt/keycloak/bin/kcadm.sh
SERVER="http://127.0.0.1:8080${KC_HTTP_RELATIVE_PATH:-/auth}"
REALM=coddy

: "${KC_BOOTSTRAP_ADMIN_USERNAME:?}" "${KC_BOOTSTRAP_ADMIN_PASSWORD:?}"
: "${CODDY_WEB_CLIENT_SECRET:?}" "${CODDY_SERVICE_CLIENT_SECRET:?}"

# Session is kept in $HOME/.keycloak/kcadm.config (/opt/keycloak is writable).
kc() { "$KCADM" "$@"; }

kc config credentials --server "$SERVER" --realm master \
  --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

set_client_secret() {
  local client_id=$1 secret=$2 id
  id=$(kc get clients -r "$REALM" -q clientId="$client_id" --fields id --format csv --noquotes | head -n1)
  if [ -z "$id" ]; then
    echo "bootstrap: client $client_id not found in realm $REALM (import failed?)" >&2
    return 1
  fi
  # Confidential clients are imported disabled, without a shared placeholder
  # secret. Install the real secret and enable the client in the same update.
  kc update "clients/$id" -r "$REALM" -s secret="$secret" -s enabled=true
  echo "bootstrap: secret set and client $client_id enabled"
}

# Accounts are created by admins with just a username (+ optional email); do not
# make Keycloak block the first login asking for first/last name.
kc update authentication/required-actions/VERIFY_PROFILE -r "$REALM" -s enabled=false
echo "bootstrap: VERIFY_PROFILE required action disabled"

# A realm imported from a file with an explicit requiredActions list lacks
# Keycloak's default actions; without UPDATE_PASSWORD a temporary password is
# never forced to change. Register the defaults when they are missing.
registered=$(kc get authentication/required-actions -r "$REALM" --fields alias --format csv --noquotes)
for action in "UPDATE_PASSWORD=Update Password" "UPDATE_PROFILE=Update Profile" "CONFIGURE_TOTP=Configure OTP" "VERIFY_EMAIL=Verify Email"; do
  alias=${action%%=*}
  if ! grep -qx "$alias" <<<"$registered"; then
    kc create authentication/register-required-action -r "$REALM" -s providerId="$alias" -s name="${action#*=}"
    echo "bootstrap: registered required action $alias"
  fi
done

# Branded login theme (keycloak/themes/coddy, mounted at /opt/keycloak/themes).
kc update "realms/$REALM" -s loginTheme=coddy -s accessCodeLifespanLogin=3600
echo "bootstrap: loginTheme=coddy, login timeout 1h"

# Public client for people using the API/CLI (password grant). The realm import
# only runs on first start, so create it here when it is missing.
if [ -z "$(kc get clients -r "$REALM" -q clientId=coddy-cli --fields id --format csv --noquotes)" ]; then
  kc create clients -r "$REALM" -f /opt/keycloak/coddy/client-coddy-cli.json
  echo "bootstrap: created client coddy-cli"
fi

set_client_secret coddy-web "$CODDY_WEB_CLIENT_SECRET"
set_client_secret coddy-service "$CODDY_SERVICE_CLIENT_SECRET"

if [ -n "${KC_INITIAL_USER:-}" ]; then
  existing=$(kc get users -r "$REALM" -q username="$KC_INITIAL_USER" -q exact=true --fields id --format csv --noquotes | head -n1)
  if [ -n "$existing" ]; then
    echo "bootstrap: user $KC_INITIAL_USER already exists, leaving it alone"
  else
    : "${KC_INITIAL_USER_PASSWORD:?KC_INITIAL_USER_PASSWORD is required when KC_INITIAL_USER is set}"
    args=(-s "username=$KC_INITIAL_USER" -s enabled=true)
    if [ -n "${KC_INITIAL_USER_EMAIL:-}" ]; then
      args+=(-s "email=$KC_INITIAL_USER_EMAIL" -s emailVerified=true)
    fi
    kc create users -r "$REALM" "${args[@]}"
    # Temporary: Keycloak forces a password change at first login.
    kc set-password -r "$REALM" --username "$KC_INITIAL_USER" \
      --new-password "$KC_INITIAL_USER_PASSWORD" --temporary
    echo "bootstrap: created user $KC_INITIAL_USER (temporary password, change on first login)"
  fi
fi

echo "bootstrap: done"
