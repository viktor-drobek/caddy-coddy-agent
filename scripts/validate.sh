#!/usr/bin/env bash
# Validate a rendered caddy-coddy project before it is deployed: shell syntax of
# every script, every JSON file, `docker compose config -q` and `caddy validate`.
# The last two run with a placeholder .env (secrets are not needed to validate),
# using docker on this machine when present and otherwise the edge's docker in a
# scratch directory there, never the live deployment. shellcheck and yamllint run
# when installed. Exit 1 when any check FAILed.
#
#   validate.sh [project-dir]
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cc_project "${1:-.}"
cd "$PROJECT"

passed=0; failed=0; skipped=0
run() { # run <label> <command...>
  local label=$1 out; shift
  if out=$("$@" 2>&1); then
    printf 'PASS  %s\n' "$label"; passed=$((passed + 1))
  else
    printf 'FAIL  %s\n%s\n' "$label" "$(sed 's/^/      /' <<<"$out")"; failed=$((failed + 1))
  fi
}
skip() { printf 'SKIP  %s\n' "$1"; skipped=$((skipped + 1)); }
# Project files only: not the agent checkout, git internals or agent folders.
project_files() { find . \( -path ./.git -o -path ./tools -o -path ./.coddy -o -path ./memory -o -path ./.relay \) -prune -o -type f -name "$1" -print0 | sort -z; }

echo "== shell syntax"
while IFS= read -r -d '' f; do run "bash -n ${f#./}" bash -n "$f"; done < <(project_files '*.sh')

echo "== json"
while IFS= read -r -d '' f; do
  if command -v jq >/dev/null 2>&1; then run "jq ${f#./}" jq . "$f"; else run "json ${f#./}" python3 -m json.tool "$f"; fi
done < <(project_files '*.json')

echo "== docker compose config and caddy validate"
for f in docker-compose.yml Caddyfile .env.example; do
  [ -f "$f" ] || { printf 'FAIL  %s is missing (run the build phase)\n' "$f"; failed=$((failed + 1)); }
done
if [ -f docker-compose.yml ] && [ -f Caddyfile ] && [ -f .env.example ]; then
  # Every variable of .env.example with a harmless value, so ${VAR:?} interpolation
  # and Caddy's {env.*} placeholders resolve.
  placeholder_env() {
    sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' .env.example | while read -r k; do
      case $k in
        CODDY_BACKEND) echo "$k=127.0.0.1:18080" ;;
        KEYCLOAK_BACKEND) echo "$k=127.0.0.1:8080" ;;
        OAUTH2_PROXY_BACKEND) echo "$k=127.0.0.1:4180" ;;
        PUBLIC_URL) echo "$k=$CC_PUBLIC_URL" ;;
        PUBLIC_HOST) echo "$k=$CC_PUBLIC_HOST" ;;
        KC_HOSTNAME) echo "$k=$CC_KC_HOSTNAME" ;;
        KC_ADMIN_USER|KC_INITIAL_USER) echo "$k=admin" ;;
        *) echo "$k=placeholder" ;;
      esac
    done
  }
  caddy_cmd='caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile --envfile /etc/caddy/env'
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    scratch=$(mktemp -d)
    trap 'rm -rf "$scratch"' EXIT
    cp docker-compose.yml Caddyfile .env.example "$scratch"/ && placeholder_env > "$scratch/.env"
    run "docker compose config (local docker)" docker compose --project-directory "$scratch" -f "$scratch/docker-compose.yml" config -q
    run "caddy validate (local docker)" docker run --rm -v "$scratch/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$scratch/.env:/etc/caddy/env:ro" caddy:2 $caddy_cmd
  elif edge true 2>/dev/null; then
    remote="/tmp/caddy-coddy-validate.$$"
    if edge "mkdir -p '$remote'" && rsync -aq docker-compose.yml Caddyfile .env.example "$CC_EDGE_SSH:$remote/" && placeholder_env | edge "cat > '$remote/.env'"; then
      run "docker compose config (on $CC_EDGE_NAME)" edge "cd '$remote' && sudo -n docker compose config -q"
      run "caddy validate (on $CC_EDGE_NAME)" edge "sudo -n docker run --rm -v '$remote/Caddyfile:/etc/caddy/Caddyfile:ro' -v '$remote/.env:/etc/caddy/env:ro' caddy:2 $caddy_cmd"
      edge "rm -rf '$remote'" || true
    else
      skip "compose/caddy: could not stage the files on the edge"
    fi
  else
    skip "compose/caddy: no docker here and the edge is unreachable"
  fi
fi

echo "== optional linters"
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do run "shellcheck ${f#./}" shellcheck -S error "$f"; done < <(project_files '*.sh')
else
  skip "shellcheck (not installed)"
fi
if command -v yamllint >/dev/null 2>&1 && [ -f docker-compose.yml ]; then
  run "yamllint docker-compose.yml" yamllint -d relaxed docker-compose.yml
else
  skip "yamllint (not installed)"
fi

echo
echo "RESULT: $passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
