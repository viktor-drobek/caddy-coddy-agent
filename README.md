# Caddy Coddy Agent

Coddy agent for managing the `caddy-coddy` infrastructure stack on **superset**.

This repository is designed as a **git submodule** inside the main `caddy-coddy` repo, under `tools/caddy-coddy-agent`.

## What it does

- **Validate** — `scripts/validate.sh` checks all configs before deploy (bash -n, jq, caddy validate, docker compose config)
- **Deploy** — `scripts/deploy.sh` wraps `./deploy.sh` from the main repo with pre-flight checks
- **Smoke test** — `scripts/smoke.sh` runs full E2E against `https://meet.2050.su`
- **User management** — `scripts/add-user.py` and `scripts/remove-user.py` for Keycloak realm `coddy`
- **Token sync** — `scripts/sync-token.py` syncs `httpserver.auth_token` from ml to superset
- **Health** — `workflows/health-check.yml` defines automated health probes

## Structure

```
.
├── README.md                 # This file
├── agent.yml                 # Coddy agent configuration (skills, workflows)
├── scripts/                  # Bash + Python tools
│   ├── validate.sh           # Pre-deploy validation suite
│   ├── deploy.sh             # Deploy with safety checks
│   ├── smoke.sh              # E2E smoke tests
│   ├── add-user.py           # Create Keycloak user
│   ├── remove-user.py        # Remove Keycloak user
│   └── sync-token.py         # Sync Coddy API token
├── skills/                   # Coddy agent skill definitions
│   ├── rap-init.md           # RPA initialization skill
│   └── rpa-gen-rules.md      # Rule generation skill
└── workflows/                # Workflow definitions
    ├── deploy.yml
    └── health-check.yml
```

## Usage (as submodule)

```bash
# From the main caddy-coddy repo
cd tools/caddy-coddy-agent

# Validate everything
./scripts/validate.sh ../../

# Deploy
cd ../..
./tools/caddy-coddy-agent/scripts/deploy.sh

# Add a user
python3 ./tools/caddy-coddy-agent/scripts/add-user.py alice alice@example.com

# Sync token from ml
python3 ./tools/caddy-coddy-agent/scripts/sync-token.py
```

## Design Principles

1. **Fail fast** — validation runs before any deploy
2. **Idempotent** — every script safe to run multiple times
3. **No secrets in repo** — reads from the main repo's `.env` on superset
4. **Layered** — validation → deploy → smoke test, in that order
