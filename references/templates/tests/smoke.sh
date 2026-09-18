#!/usr/bin/env bash
# End-to-end test of the Coddy access stack at @@PUBLIC_HOST@@. Run from the
# checkout you deploy from (any machine with ssh access to @@EDGE_NAME@@):
#
#   tests/smoke.sh            # run every check, compare the Coddy version with the last recorded pass
#   tests/smoke.sh --record   # ...and record the Coddy version and time of this pass in caddy-coddy.yml
#   tests/smoke.sh --no-cli   # skip the `coddy cli --remote` check (the only one that calls a model)
#
# The checks run on @@EDGE_NAME@@ itself: they talk to Caddy on 127.0.0.1 with the
# real Host/SNI, so they work even when the edge cannot reach its own public
# address (NAT). A throwaway Keycloak user is created and deleted afterwards.
# The CLI check copies the local `coddy` binary to the edge and runs it in a
# container there, so it needs a Linux binary of the edge's architecture.
# Exit status 1 when any check fails.
#
# After a Coddy release: rerun, and if everything passes, `--record`.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_HOST=${TARGET_HOST:-@@EDGE_SSH@@}
TARGET_DIR=${TARGET_DIR:-@@EDGE_DIR@@}
MANIFEST=caddy-coddy.yml
RECORD=0; WITH_CLI=1
for a in "$@"; do
  case $a in
    --record) RECORD=1 ;;
    --no-cli) WITH_CLI=0 ;;
    *) echo "usage: $0 [--record] [--no-cli]" >&2; exit 2 ;;
  esac
done

# The remote part is copied as a file (not piped over stdin: docker exec would
# swallow the script) and removes /tmp/coddy-smoke itself when done.
ssh "$TARGET_HOST" 'mkdir -p /tmp/coddy-smoke'
scp -q tests/smoke-remote.sh "$TARGET_HOST:/tmp/coddy-smoke/smoke-remote.sh"
if [ "$WITH_CLI" = 1 ]; then
  CODDY_BIN=${CODDY_BIN:-$(command -v coddy 2>/dev/null || echo "$HOME/.local/bin/coddy")}
  if [ ! -x "$CODDY_BIN" ]; then
    echo "coddy binary not found ($CODDY_BIN); set CODDY_BIN or use --no-cli" >&2
    exit 2
  fi
  scp -q "$CODDY_BIN" "$TARGET_HOST:/tmp/coddy-smoke/coddy"
  echo "local coddy binary: $("$CODDY_BIN" --version 2>/dev/null) ($CODDY_BIN)"
fi

remote_status=0
out=$(ssh "$TARGET_HOST" "$(printf 'TARGET_DIR=%q WITH_CLI=%q bash /tmp/coddy-smoke/smoke-remote.sh' "$TARGET_DIR" "$WITH_CLI")" 2>&1) || remote_status=$?
printf '%s\n' "$out"

# A partial run can contain PASS lines (and even a version) before SSH drops or
# the remote script aborts. Neither is proof that every requested check ran.
if [ "$remote_status" -ne 0 ]; then
  echo "RESULT: remote smoke test failed (exit $remote_status)" >&2
  exit 1
fi
if ! grep -qx 'SMOKE_COMPLETE' <<<"$out"; then
  echo "RESULT: remote smoke test did not complete" >&2
  exit 1
fi

fails=$(grep -c '^FAIL' <<<"$out" || true)
passes=$(grep -c '^PASS' <<<"$out" || true)
version=$(sed -n 's/^CODDY_VERSION //p' <<<"$out" | head -n1)
tested=$(sed -n 's/^coddy_version:[[:space:]]*//p' "$MANIFEST" 2>/dev/null | head -n1 || true)
tested=${tested:-none}

echo
echo "coddy serve version behind the proxy: ${version:-unknown}   last recorded pass: $tested"
if [ "$fails" -gt 0 ] || [ "$passes" -eq 0 ]; then
  echo "RESULT: $fails failed, $passes passed"
  exit 1
fi
if [ "$RECORD" = 1 ] && [ -n "$version" ]; then
  if [ -f "$MANIFEST" ]; then
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for kv in "coddy_version=$version" "verified_at=$now"; do
      k=${kv%%=*}; v=${kv#*=}
      if grep -q "^$k:" "$MANIFEST"; then sed -i "s|^$k:.*|$k: $v|" "$MANIFEST"; else printf '%s: %s\n' "$k" "$v" >> "$MANIFEST"; fi
    done
    echo "recorded coddy $version ($now) in $MANIFEST"
  else
    echo "no $MANIFEST here; nothing recorded"
  fi
elif [ -n "$version" ] && [ "$version" != "$tested" ]; then
  echo "NOTE: coddy $version differs from the last recorded pass ($tested); rerun with --record to pin it"
fi
echo "RESULT: all $passes checks passed"
