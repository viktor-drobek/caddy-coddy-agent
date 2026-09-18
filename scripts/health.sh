#!/usr/bin/env bash
# Quick health check of a deployed stack, run on the edge over ssh: container
# health from docker compose, then the edge's own view of the site (Caddy on
# 127.0.0.1 with the real host name): page load 302, XHR 401, OIDC discovery
# 200, admin console 302. Exit 1 when anything FAILed.
#
#   health.sh [project-dir]
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cc_project "${1:-.}"

fails=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf 'PASS  %s (%s)\n' "$1" "$3"; else printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "${3:-nothing}"; fails=$((fails + 1)); fi
}
probe() { # probe <curl args...> -> http code, resolved on the edge itself
  edge "curl -s --resolve '$CC_PUBLIC_HOST:443:127.0.0.1' -o /dev/null --max-time 10 -w '%{http_code}' $*" 2>/dev/null
}

echo "== containers on $CC_EDGE_SSH ($CC_EDGE_DIR)"
status=$(edge "cd '$CC_EDGE_DIR' && sudo -n docker compose ps --format '{{.Name}} {{.Status}}'" 2>&1) || { echo "FAIL  docker compose ps: $status"; fails=$((fails + 1)); status=; }
if [ -n "$status" ]; then
  printf '%s\n' "$status" | sed 's/^/      /'
  unhealthy=$(grep -v '(healthy)' <<<"$status" || true)
  if [ -z "$unhealthy" ]; then echo "PASS  all containers healthy"; else echo "FAIL  not healthy: $(tr '\n' ';' <<<"$unhealthy")"; fails=$((fails + 1)); fi
fi

echo "== $CC_PUBLIC_URL as seen from the edge"
check "page load without session -> 302" 302 "$(probe -H "'Accept: text/html'" "'$CC_PUBLIC_URL/'")"
check "XHR without session -> 401" 401 "$(probe -H "'Accept: application/json'" "'$CC_PUBLIC_URL/coddy/sessions'")"
check "realm coddy discovery -> 200" 200 "$(probe "'$CC_PUBLIC_URL/auth/realms/coddy/.well-known/openid-configuration'")"
check "keycloak admin console anonymous -> 302" 302 "$(probe -H "'Accept: text/html'" "'$CC_PUBLIC_URL/auth/admin/master/console/'")"

echo
if [ "$fails" -gt 0 ]; then echo "RESULT: $fails FAIL"; exit 1; fi
echo "RESULT: healthy"
