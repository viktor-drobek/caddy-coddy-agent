# shellcheck shell=bash
# Shared helpers for the caddy-coddy agent scripts. Source it, do not run it:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   cc_project "${1:-.}"     # sets PROJECT, MANIFEST and every CC_* variable
#
# CC_* variables come from `manifest.py vars --shell`: the manifest keys in
# upper case (CC_PUBLIC_HOST, CC_EDGE_SSH, CC_EDGE_DIR, CC_CODDY_BACKEND, ...)
# plus the derived CC_EDGE_HOST, CC_EDGE_USER, CC_CODDY_BACKEND_HOST,
# CC_CODDY_BACKEND_PORT and CC_KC_HOSTNAME.

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST_NAME=caddy-coddy.yml

log() { printf '[caddy-coddy] %s\n' "$*"; }
die() { printf '[caddy-coddy] error: %s\n' "$*" >&2; exit 1; }

# Resolve the project directory and load its manifest.
cc_project() {
  PROJECT=$(cd "${1:-.}" 2>/dev/null && pwd) || die "no such directory: ${1:-.}"
  MANIFEST=$PROJECT/$MANIFEST_NAME
  [ -f "$MANIFEST" ] || die "no $MANIFEST_NAME in $PROJECT; run the plan phase first (scripts/manifest.py init ...)"
  local vars
  vars=$(python3 "$SKILL_DIR/scripts/manifest.py" -f "$MANIFEST" vars --shell) || die "invalid manifest $MANIFEST"
  eval "$vars"
}

# Run a command on the edge host, non-interactively (a key must be set up).
edge() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$CC_EDGE_SSH" "$@"; }

# Make sure the project directory on the edge exists and belongs to the ssh user
# (rsync in deploy.sh writes there without sudo).
ensure_edge_dir() {
  if edge "test -d '$CC_EDGE_DIR' && test -w '$CC_EDGE_DIR'" 2>/dev/null; then return 0; fi
  log "creating $CC_EDGE_DIR on $CC_EDGE_SSH"
  edge "sudo -n mkdir -p '$CC_EDGE_DIR' && sudo -n chown \"\$(id -un)\" '$CC_EDGE_DIR'" \
    || die "cannot create $CC_EDGE_DIR on $CC_EDGE_SSH (passwordless sudo required)"
}
