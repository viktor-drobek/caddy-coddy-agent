#!/usr/bin/env bash
# health-check.sh — Quick health probes against the live stack.
set -euo pipefail

SUPERSET=${SUPERSET_HOST:-huron@192.168.135.10}

probes=(
  "Caddy forward_auth page load:curl -s -o /dev/null -w '%{http_code}' -H 'Accept: text/html' --resolve meet.2050.su:443:127.0.0.1 https://meet.2050.su/; echo"
  "Caddy XHR anon:curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/json' --resolve meet.2050.su:443:127.0.0.1 https://meet.2050.su/coddy/sessions; echo"
  "Keycloak ready:exec 3<>/dev/tcp/127.0.0.1/9000 && printf 'GET /auth/health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3 && grep -q 'status.*UP' <&3 && echo UP"
  "oauth2-proxy ping:wget -qO- http://127.0.0.1:4180/ping"
)

ALL_OK=true
for probe in "${probes[@]}"; do
  name=${probe%%:*}
  cmd=${probe#*:}
  echo -n "Probe: $name ... "
  if ssh "$SUPERSET" "$cmd" 2>/dev/null; then
    echo " OK"
  else
    echo " FAIL"
    ALL_OK=false
  fi
done

$ALL_OK && { echo "All probes passed"; exit 0; } || { echo "Some probes failed"; exit 1; }
