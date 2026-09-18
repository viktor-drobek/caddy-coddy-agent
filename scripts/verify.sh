#!/usr/bin/env bash
# Run the project's end-to-end smoke test (tests/smoke.sh) against the deployed
# stack. With --record it writes the Coddy version it passed against into the
# site manifest (coddy_version, verified_at). The `coddy cli --remote` check
# needs a Linux coddy binary of the edge's architecture on this machine; it is
# skipped automatically when there is none (or with --no-cli).
#
#   verify.sh [--record] [--no-cli] [project-dir]
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

args=()
dir=.
for a in "$@"; do
  case $a in
    --record|--no-cli) args+=("$a") ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) dir=$a ;;
  esac
done
cc_project "$dir"
cd "$PROJECT"
[ -x tests/smoke.sh ] || die "no tests/smoke.sh in $PROJECT; run the build phase first"

if ! printf '%s\n' "${args[@]+"${args[@]}"}" | grep -qx -- --no-cli; then
  bin=${CODDY_BIN:-$(command -v coddy 2>/dev/null || echo "$HOME/.local/bin/coddy")}
  edge_arch=$(edge uname -m 2>/dev/null || echo unknown)
  if [ ! -x "$bin" ] || [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != "$edge_arch" ]; then
    log "skipping the 'coddy cli --remote' check: it needs a Linux/$edge_arch coddy binary here (this machine: $(uname -s)/$(uname -m), binary: $bin)"
    args+=(--no-cli)
  fi
fi

TARGET_HOST=$CC_EDGE_SSH TARGET_DIR=$CC_EDGE_DIR tests/smoke.sh "${args[@]+"${args[@]}"}"
