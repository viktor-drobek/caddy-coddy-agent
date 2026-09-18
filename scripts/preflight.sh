#!/usr/bin/env bash
# Preflight for a caddy-coddy site (plan phase): the manifest, the tools on this
# machine, ssh and passwordless sudo on the edge, docker compose there, ports
# 80/443, DNS against the edge's addresses, whether the edge reaches coddy serve
# with bearer auth enabled, and the state of <edge_dir>/.env.
# Prints PASS / WARN / FAIL lines and exits 1 when anything FAILed.
#
#   preflight.sh [project-dir]        # project-dir holds caddy-coddy.yml (default: .)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cc_project "${1:-.}"

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

echo "== manifest $MANIFEST"
if out=$(python3 "$SKILL_DIR/scripts/manifest.py" -f "$MANIFEST" check 2>&1); then
  pass "valid: $CC_PUBLIC_URL -> edge $CC_EDGE_SSH:$CC_EDGE_DIR -> coddy $CC_CODDY_BACKEND"
else
  fail "$out"
fi

echo "== tools on this machine"
for t in ssh rsync curl python3 openssl; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t"; else fail "$t is missing"; fi
done
command -v jq >/dev/null 2>&1 && pass "jq (optional)" || warn "jq not found; JSON checks fall back to python3"
command -v docker >/dev/null 2>&1 && pass "docker (optional)" || warn "docker not found here; compose/Caddy validation runs on the edge instead"
command -v coddy >/dev/null 2>&1 && pass "coddy binary (optional)" || warn "coddy binary not on PATH; the 'coddy cli --remote' smoke check is skipped unless CODDY_BIN is set"

echo "== edge $CC_EDGE_SSH"
if edge true 2>/dev/null; then
  pass "ssh works non-interactively"
else
  fail "ssh $CC_EDGE_SSH does not work non-interactively (BatchMode): set up a key and an ~/.ssh/config entry"
  echo "RESULT: $fails FAIL (cannot continue without ssh)"
  exit 1
fi
if edge 'sudo -n true' 2>/dev/null; then pass "passwordless sudo"; else fail "sudo -n fails on the edge; deploy.sh runs 'sudo docker compose'"; fi
for t in docker rsync curl openssl; do
  if edge "command -v $t >/dev/null 2>&1"; then pass "$t on edge"; else fail "$t is missing on the edge"; fi
done
if v=$(edge 'sudo -n docker compose version 2>/dev/null'); then pass "$v"; else fail "docker compose plugin is missing on the edge"; fi

listeners=$(edge 'sudo -n ss -Hltnp 2>/dev/null | grep -E "[]:.](80|443) "' 2>/dev/null || true)
if [ -z "$listeners" ]; then
  pass "ports 80 and 443 are free on the edge"
elif grep -qE 'caddy|docker' <<<"$listeners"; then
  pass "ports 80/443 are held by caddy/docker on the edge (existing deployment)"
else
  fail "ports 80/443 are used by another process on the edge: $(tr -s ' \n' ' ' <<<"$listeners" | head -c 200)"
fi

echo "== dns and addresses"
resolved=$(python3 -c 'import socket, sys; print(" ".join(sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1], None)})))' "$CC_PUBLIC_HOST" 2>/dev/null || true)
if [ -z "$resolved" ]; then
  fail "$CC_PUBLIC_HOST does not resolve: create the DNS record pointing at the edge's public address"
else
  edge_addrs=$(edge "ip -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" 2>/dev/null || true)
  hit=0
  for ip in $resolved; do grep -qx "$ip" <<<"$edge_addrs" && hit=1; done
  if [ "$hit" = 1 ]; then
    pass "$CC_PUBLIC_HOST -> $resolved (an address of the edge)"
  else
    warn "$CC_PUBLIC_HOST -> $resolved is not an address of the edge ($(tr '\n' ' ' <<<"$edge_addrs")); fine behind NAT when 80/443 are forwarded to it"
  fi
fi

echo "== coddy serve at $CC_CODDY_BACKEND, as seen from the edge"
answer=$(edge "curl -s --max-time 5 -w '\n%{http_code}' 'http://$CC_CODDY_BACKEND/coddy/auth/me'" 2>/dev/null || true)
code=${answer##*$'\n'}
body=${answer%$'\n'*}
case "$code" in
  200)
    pass "reachable (HTTP 200 from /coddy/auth/me)"
    case "$body" in
      *'"auth_required":true'*) pass "bearer auth is on (httpserver.auth_token set); the proxy will use it as CODDY_API_TOKEN" ;;
      *) warn "coddy answers without bearer auth: set httpserver.auth_token in its config.yaml, otherwise anyone reaching $CC_CODDY_BACKEND can use it" ;;
    esac ;;
  ''|000) fail "no answer from http://$CC_CODDY_BACKEND (is coddy serve listening on an address the edge can reach? httpserver.host: 0.0.0.0)" ;;
  *) warn "unexpected HTTP $code from http://$CC_CODDY_BACKEND/coddy/auth/me" ;;
esac

echo "== $CC_EDGE_DIR on the edge"
if edge "test -d '$CC_EDGE_DIR'" 2>/dev/null; then
  if edge "test -w '$CC_EDGE_DIR'" 2>/dev/null; then pass "exists and is writable by the ssh user"; else warn "exists but is not writable by the ssh user; deploy chowns it"; fi
  if edge "test -f '$CC_EDGE_DIR/.env'" 2>/dev/null; then pass ".env is present (existing deployment)"; else warn "no .env yet: the first deploy generates it"; fi
else
  warn "does not exist yet: the first deploy creates it"
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "RESULT: $fails FAIL"
  exit 1
fi
echo "RESULT: preflight passed"
