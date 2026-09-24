#!/usr/bin/env bash
# First deploy only: create <edge_dir>/.env on the edge from the project's
# .env.example with generated secrets. Does nothing when .env already exists.
#
# Coddy's API token comes from $CODDY_API_TOKEN, else $CODDY_HTTP_TOKEN, else
# httpserver.auth_token in the local Coddy config ($CODDY_CONFIG, default
# ~/.coddy/config.yaml), so run this where coddy serve runs or export the token.
# Secrets travel over ssh stdin only. The one thing printed is the temporary
# password of the initial user, when the manifest names one.
#
#   init-env.sh [project-dir]
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cc_project "${1:-.}"
cd "$PROJECT"
[ -f .env.example ] || die "no .env.example in $PROJECT; run the build phase first"

INIT_PW=
[ -n "$CC_INITIAL_USER" ] && INIT_PW=$(openssl rand -base64 15 | tr -d '/+=')

# Value for a key of .env.example, or failure to keep the example's own value.
value_for() {
  case $1 in
    CODDY_API_TOKEN) printf '%s' "${TOKEN:-}" ;;
    KC_DB_PASSWORD|KC_ADMIN_PASSWORD|CODDY_WEB_CLIENT_SECRET|CODDY_SERVICE_CLIENT_SECRET) openssl rand -hex 32 ;;
    OAUTH2_PROXY_COOKIE_SECRET) openssl rand -base64 32 | tr -- '+/' '-_' ;;
    KC_INITIAL_USER) printf '%s' "$CC_INITIAL_USER" ;;
    KC_INITIAL_USER_PASSWORD) printf '%s' "$INIT_PW" ;;
    TG_AUTH_COOKIE_SECRET) openssl rand -hex 32 ;;
    TG_ALLOWED_USER_IDS) printf '%s' "$CC_TELEGRAM_USER_IDS" ;;
    TG_BOT_TOKEN) printf '%s' "$TG_TOKEN" ;;
    *) return 1 ;;
  esac
}

# Telegram Mini App sign-in (optional): the bot token comes from $TG_BOT_TOKEN,
# else from gateways.telegram.token in the local Coddy config; empty keeps it off.
tg_token_from_config() {
  local cfg=${CODDY_CONFIG:-${CODDY_HOME:-$HOME/.coddy}/config.yaml} t var
  [ -f "$cfg" ] || return 0
  t=$(awk '/^gateways:/{g=1} g && /^  telegram:/{t=1} g && t && /^    token:/{print $2; exit}' "$cfg" | tr -d '"'"'"'"')
  case "$t" in '${'*'}') var=${t#'${'}; var=${var%'}'}; t=${!var:-} ;; esac
  printf '%s' "$t"
}
TG_TOKEN=${TG_BOT_TOKEN:-$(tg_token_from_config)}
if [ -n "$CC_TELEGRAM_USER_IDS" ] && [ -z "$TG_TOKEN" ]; then
  log "manifest lists telegram_user_ids but no bot token was found: export TG_BOT_TOKEN to enable Telegram sign-in (it stays off otherwise)"
fi

ensure_edge_dir
if edge "test -f '$CC_EDGE_DIR/.env'"; then
  # Existing site: append keys the env contract gained since (new features);
  # keys already present are never touched. Secrets are generated here.
  have=$(edge "sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' '$CC_EDGE_DIR/.env'")
  added=
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      [A-Z]*=*)
        key=${line%%=*}
        grep -qx "$key" <<<"$have" && continue
        if new=$(value_for "$key"); then value=$new; else value=${line#*=}; fi
        added+="$key=$value"$'\n' ;;
    esac
  done < .env.example
  if [ -n "$added" ]; then
    printf '%s' "$added" | edge "cat >> '$CC_EDGE_DIR/.env'"
    log "added to $CC_EDGE_SSH:$CC_EDGE_DIR/.env: $(printf '%s' "$added" | sed 's/=.*//' | tr '\n' ' ')"
  else
    log ".env already exists on $CC_EDGE_SSH:$CC_EDGE_DIR and has every key; nothing to do (edit it there to rotate secrets)"
  fi
  exit 0
fi

TOKEN=${CODDY_API_TOKEN:-${CODDY_HTTP_TOKEN:-}}
if [ -z "$TOKEN" ]; then
  CONFIG=${CODDY_CONFIG:-${CODDY_HOME:-$HOME/.coddy}/config.yaml}
  if [ -f "$CONFIG" ]; then
    TOKEN=$(sed -n -E 's/^[[:space:]]+auth_token:[[:space:]]*"?([^"[:space:]#]+)"?.*/\1/p' "$CONFIG" | head -n1)
    case "$TOKEN" in
      '${'*'}') var=${TOKEN#'${'}; var=${var%'}'}; TOKEN=${!var:-} ;;
    esac
  fi
fi
[ -n "$TOKEN" ] || die "Coddy's API token not found: export CODDY_API_TOKEN=<httpserver.auth_token of coddy serve> and run again (or run this on the host where coddy serve runs)"

# Best effort: check the token against coddy when it is reachable from here.
code=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$CC_CODDY_LOCAL_URL/coddy/sessions" || true)
case "$code" in
  200) log "token accepted by coddy at $CC_CODDY_LOCAL_URL" ;;
  401|403) die "coddy at $CC_CODDY_LOCAL_URL rejected the token (HTTP $code); is coddy serve running with the config the token came from?" ;;
  *) log "coddy not reachable from here at $CC_CODDY_LOCAL_URL (HTTP ${code:-000}); the token is not pre-checked" ;;
esac


content=$(while IFS= read -r line || [ -n "$line" ]; do
  case $line in
    [A-Z]*=*)
      key=${line%%=*}
      if new=$(value_for "$key"); then printf '%s=%s\n' "$key" "$new"; else printf '%s\n' "$line"; fi ;;
    *) printf '%s\n' "$line" ;;
  esac
done < .env.example)

printf '%s\n' "$content" | edge "umask 077 && cat > '$CC_EDGE_DIR/.env' && chmod 600 '$CC_EDGE_DIR/.env'"
log "created $CC_EDGE_SSH:$CC_EDGE_DIR/.env (mode 600) with generated secrets"
if [ -n "$INIT_PW" ]; then
  printf '\nInitial user "%s": temporary password (a new one is forced at the first sign-in at %s/):\n\n    %s\n\n' "$CC_INITIAL_USER" "$CC_PUBLIC_URL" "$INIT_PW"
fi
