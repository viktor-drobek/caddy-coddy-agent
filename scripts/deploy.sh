#!/usr/bin/env bash
# Deploy a rendered caddy-coddy project: validate, make sure the edge has an
# .env (the first deploy generates one), run the project's own ./deploy.sh
# (rsync, docker compose up -d, Keycloak bootstrap), then the health probes.
#
#   deploy.sh [--skip-validate] [project-dir]
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALIDATE=1
if [ "${1:-}" = "--skip-validate" ]; then VALIDATE=0; shift; fi
cc_project "${1:-.}"
cd "$PROJECT"
[ -x ./deploy.sh ] || die "no executable deploy.sh in $PROJECT; run the build phase first"

if [ "$VALIDATE" = 1 ]; then
  bash "$SKILL_DIR/scripts/validate.sh" "$PROJECT" || die "validation failed; fix the configuration before deploying"
fi
bash "$SKILL_DIR/scripts/init-env.sh" "$PROJECT"

log "deploying $PROJECT to $CC_EDGE_SSH:$CC_EDGE_DIR"
TARGET_HOST=$CC_EDGE_SSH TARGET_DIR=$CC_EDGE_DIR ./deploy.sh

bash "$SKILL_DIR/scripts/health.sh" "$PROJECT"
