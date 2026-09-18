#!/usr/bin/env bash
# Runs on @@EDGE_NAME@@ (copied to /tmp/coddy-smoke by tests/smoke.sh). Prints PASS/FAIL lines and
# "CODDY_VERSION x.y.z". Env: TARGET_DIR, WITH_CLI.
set -uo pipefail
cd "$TARGET_DIR" || exit 1
set -a; . ./.env || exit 1; set +a
HOST=${PUBLIC_HOST:-@@PUBLIC_HOST@@}
URL=${PUBLIC_URL:-https://$HOST}
R="--resolve $HOST:443:127.0.0.1"
KC="$KC_HOSTNAME/realms/coddy/protocol/openid-connect"

failures=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ -- $2}"; failures=$((failures + 1)); }
expect() { # expect <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}
contains() { # contains <name> <needle> <haystack>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing '$2' in: $(printf '%s' "$3" | head -c 160)" ;; esac
}
code() { curl -s $R -o /dev/null -w '%{http_code}' "$@"; }
redirect() { curl -s $R -o /dev/null -w '%{redirect_url}' "$@"; }
jsonfield() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(d'"$1"')' 2>/dev/null; }

U="smoketest-$RANDOM"; PW=$(openssl rand -base64 18 | tr -d /+=); NEWPW=$(openssl rand -base64 18 | tr -d /+=)
J=$(mktemp); TMP=$(mktemp -d)
cleanup() {
  sudo docker compose exec -T -e U="$U" keycloak bash -c 'id=$(/opt/keycloak/bin/kcadm.sh get users -r coddy -q username=$U -q exact=true --fields id --format csv --noquotes | head -n1); [ -n "$id" ] && /opt/keycloak/bin/kcadm.sh delete users/$id -r coddy' >/dev/null 2>&1 </dev/null
  rm -rf "$J" "$TMP"; sudo rm -rf /tmp/coddy-smoke
}
trap cleanup EXIT

# kcadm session for the admin (bootstrap's may have expired)
sudo docker compose exec -T -e A="$KC_ADMIN_USER" -e P="$KC_ADMIN_PASSWORD" keycloak bash -c \
  '/opt/keycloak/bin/kcadm.sh config credentials --server http://127.0.0.1:8080/auth --realm master --user "$A" --password "$P"' >/dev/null 2>&1 </dev/null
if sudo docker compose exec -T -e U="$U" -e PW="$PW" keycloak bash -c \
  '/opt/keycloak/bin/kcadm.sh create users -r coddy -s username=$U -s enabled=true >/dev/null && /opt/keycloak/bin/kcadm.sh set-password -r coddy --username $U --new-password "$PW" --temporary' >/dev/null 2>&1 </dev/null; then
  pass "keycloak: create throwaway user with temporary password"
else
  fail "keycloak: create throwaway user"; exit 1
fi

echo "== anonymous"
expect "page load without session -> 302" 302 "$(code -H 'Accept: text/html' $URL/)"
contains "page load redirects to /oauth2/start" "/oauth2/start?rd=" "$(redirect -H 'Accept: text/html' $URL/)"
expect "XHR without session -> 401 (no redirect)" 401 "$(code -H 'Accept: application/json' $URL/coddy/sessions)"
expect "EventSource without session -> 401" 401 "$(code -H 'Accept: text/event-stream' $URL/coddy/events)"
expect "junk bearer -> 401" 401 "$(code -H 'Authorization: Bearer junk' $URL/coddy/sessions)"
expect "keycloak admin console anonymous -> 302" 302 "$(code -H 'Accept: text/html' $URL/auth/admin/master/console/)"
expect "keycloak admin API anonymous -> 302" 302 "$(code -H 'Accept: application/json' $URL/auth/admin/realms)"
expect "master realm anonymous -> 302" 302 "$(code $URL/auth/realms/master/.well-known/openid-configuration)"
expect "coddy realm discovery public -> 200" 200 "$(code $URL/auth/realms/coddy/.well-known/openid-configuration)"
expect "OIDC issuer" "$KC_HOSTNAME/realms/coddy" "$(curl -s $R $URL/auth/realms/coddy/.well-known/openid-configuration | jsonfield '["issuer"]')"

echo "== browser login (Keycloak form, temporary password, forced change)"
C="curl -s $R -b $J -c $J -H Accept:text/html"
$C -L $URL/ -o $TMP/login.html
contains "login page uses the coddy theme" "login/coddy/css/coddy.css" "$(cat $TMP/login.html)"
contains "login page title" "<title>Sign in to Coddy</title>" "$(cat $TMP/login.html)"
A=$(grep -o 'action="[^"]*"' $TMP/login.html | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
$C -L -o $TMP/step2.html --data-urlencode "username=$U" --data-urlencode "password=$PW" "$A"
contains "temporary password -> Keycloak asks for a new one" "password-new" "$(cat $TMP/step2.html)"
A2=$(grep -o 'action="[^"]*"' $TMP/step2.html | head -1 | sed 's/^action="//; s/"$//; s/&amp;/\&/g')
$C -L -o $TMP/root.html -w '%{http_code} %{url_effective}' --data-urlencode "password-new=$NEWPW" --data-urlencode "password-confirm=$NEWPW" "$A2" > $TMP/final
contains "callback lands on / with 200" "200 $URL/" "$(cat $TMP/final)"
contains "Coddy web UI served" "<title>Coddy Agent</title>" "$(cat $TMP/root.html)"
contains "/coddy/auth/me authenticated via cookie" '"authenticated":true' "$($C -H 'Accept: application/json' $URL/coddy/auth/me)"
expect "/coddy/sessions via cookie -> 200" 200 "$($C -o /dev/null -w '%{http_code}' -H 'Accept: application/json' $URL/coddy/sessions)"
contains "SSE /coddy/events streams" "coddy.events_ready" "$(timeout 5 $C -N -H 'Accept: text/event-stream' $URL/coddy/events 2>/dev/null | head -c 300)"
expect "keycloak admin console with Coddy cookie -> 200" 200 "$($C -o /dev/null -w '%{http_code}' $URL/auth/admin/master/console/)"
$C -o /dev/null "$URL/oauth2/sign_out?rd=$URL/"
expect "after sign_out page load -> 302 again" 302 "$($C -o /dev/null -w '%{http_code}' $URL/)"

echo "== service: client_credentials (coddy-service)"
ST=$(curl -s $R -X POST $KC/token -d grant_type=client_credentials -d client_id=coddy-service -d client_secret="$CODDY_SERVICE_CLIENT_SECRET" | jsonfield '.get("access_token","")')
if [ -n "$ST" ]; then pass "service token issued"; else fail "service token issued"; fi
P=$(printf '%s' "$ST" | cut -d. -f2); AUD=$(printf '%s' "$P" | python3 -c 'import sys,json,base64; p=sys.stdin.read(); print(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))).get("aud"))' 2>/dev/null)
contains "service token audience includes coddy-web" "coddy-web" "$AUD"
contains "service token -> /coddy/auth/me authenticated" '"authenticated":true' "$(curl -s $R -H "Authorization: Bearer $ST" $URL/coddy/auth/me)"
expect "service token -> /coddy/sessions 200" 200 "$(code -H "Authorization: Bearer $ST" $URL/coddy/sessions)"

echo "== person: password grant (coddy-cli)"
T=$(curl -s $R -X POST $KC/token -d grant_type=password -d client_id=coddy-cli -d scope=openid -d username="$U" --data-urlencode "password=$NEWPW")
CT=$(printf '%s' "$T" | jsonfield '.get("access_token","")')
if [ -n "$CT" ]; then pass "coddy-cli token issued"; else fail "coddy-cli token issued" "$T"; fi
expect "coddy-cli token lifetime 7 days" 604800 "$(printf '%s' "$T" | jsonfield '.get("expires_in")')"
expect "coddy-cli token -> /coddy/sessions 200" 200 "$(code -H "Authorization: Bearer $CT" $URL/coddy/sessions)"
MODELS=$(curl -s $R -H "Authorization: Bearer $CT" $URL/v1/models | jsonfield '.get("data",[]).__len__()')
if [ "${MODELS:-0}" -gt 0 ] 2>/dev/null; then pass "/v1/models lists $MODELS models"; else fail "/v1/models" "$MODELS"; fi
VER=$(curl -s $R -H "Authorization: Bearer $CT" $URL/openapi.json | jsonfield '["info"]["version"]')
if [ -n "$VER" ]; then pass "openapi.json reports coddy version $VER"; echo "CODDY_VERSION $VER"; else fail "openapi.json version"; fi

if [ "$WITH_CLI" = 1 ]; then
  echo "== coddy cli --remote (inside a container, @@PUBLIC_HOST@@ -> this host)"
  OUT=$(timeout 180 sudo docker run --rm --pull missing --add-host "$HOST:host-gateway" -v /tmp/coddy-smoke:/coddybin:ro -w /tmp \
        -e CODDY_REMOTE_TOKEN="$CT" python:3.12-alpine /coddybin/coddy cli --remote "$URL" --plain --prompt "Reply with exactly the single word: pong" 2>&1 </dev/null)
  contains "coddy cli --remote with a Keycloak token answers" "pong" "$OUT"
  OUT=$(timeout 60 sudo docker run --rm --pull missing --add-host "$HOST:host-gateway" -v /tmp/coddy-smoke:/coddybin:ro -w /tmp \
        python:3.12-alpine /coddybin/coddy cli --remote "$URL" --remote-token wrong --plain --prompt hi 2>&1 </dev/null)
  contains "coddy cli --remote with a wrong token is refused" "unauthorized" "$OUT"
fi

# The wrapper records a version only after a successful exit and this marker.
[ "$failures" -eq 0 ] || exit 1
echo "SMOKE_COMPLETE"
