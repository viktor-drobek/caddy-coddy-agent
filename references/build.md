# Phase 2: build (render the stack from the templates)

Goal: the project directory holds a complete, validated stack for the hosts in `caddy-coddy.yml`.

## What is rendered

`references/templates/` is a parameterised copy of a working deployment. `render.py` replaces
`@@NAME@@` placeholders (the manifest keys in upper case plus the derived `EDGE_HOST`, `EDGE_USER`,
`CODDY_BACKEND_HOST`, `CODDY_BACKEND_PORT`, `KC_HOSTNAME`), copies binary files verbatim and keeps
the executable bits.

| Rendered path | Layer | Purpose |
|---|---|---|
| `.env.example` | 0, env contract | Every address and secret; `init-env.sh` turns it into `.env` on the edge, which is never committed |
| `keycloak/import/realm-coddy.json`, `keycloak/client-coddy-cli.json` | 1, Keycloak state | Realm `coddy`; clients `coddy-web`, `coddy-service`, `coddy-cli` with the `coddy-web` audience mapper. Imported on the first start only |
| `keycloak/bootstrap.sh` | 1 | Idempotent post-start configuration from `.env`: client secrets, theme, `VERIFY_PROFILE` off, first user |
| `keycloak/themes/coddy/` | 1 | Login theme (dark card, Coddy branding) |
| `oauth2-proxy/oauth2-proxy.toml` | 2, oauth2-proxy | OIDC client settings, bearer-token acceptance, cookie and CSRF settings |
| `tg-auth/server.py` | 2, Telegram sign-in | Verifies Telegram Mini App `initData`, allow list, `_coddy_tg` cookie, `/tg/auth/verify` for Caddy |
| `Caddyfile` | 3, edge | Routing, `forward_auth`, header swap, security headers |
| `docker-compose.yml` | 3 | Five services; only Caddy is public |
| `deploy.sh`, `add-user.sh`, `remove-user.sh`, `list-users.sh`, `add-service.sh`, `coddy-login.sh`, `sync-coddy-token.sh` | 4, operations | Operator tools with the site's addresses as defaults |
| `tests/smoke.sh`, `tests/smoke-remote.sh` | 4 | End-to-end test; `--record` writes `coddy_version` into the manifest |
| `README.md`, `AGENTS.md`, `.gitignore` | documentation | The site's documentation for people and for agents that open the project |

## Steps

```bash
CC=<skill dir>
python3 "$CC/scripts/render.py" --check --diff <project>   # dry run: create / update / keep per file
python3 "$CC/scripts/render.py" <project>                  # write
bash "$CC/scripts/validate.sh" <project>
```

1. Run `--check` first. In a fresh directory everything is `create`. In an existing project, go
   through the `update` diffs with the user: a file they edited by hand is about to be overwritten.
   A fix that every site should get belongs in the templates; a site-only change belongs in a file
   listed under `keep:` in the manifest (`manifest.py set keep "AGENTS.md,keycloak/themes/coddy/login/resources/css/coddy.css"`).
2. Render, then open the rendered `README.md`: it is the site's own documentation with the real
   names in it.
3. Validate. `validate.sh` runs `bash -n` on every script, parses every JSON file, and runs
   `docker compose config -q` and `caddy validate` with a placeholder `.env`, with local Docker when
   present and otherwise with the edge's Docker in a scratch directory there (never the live
   deployment). `shellcheck` and `yamllint` run when installed. Compose and Caddy validation
   are mandatory: an unreachable edge or failed staging is a FAIL when local Docker is
   unavailable. Any FAIL blocks `deploy`.
4. Put the project under version control if it is not (`git init`) and commit the rendered files.
   The rendered `.gitignore` excludes `.env`, backups and agent working directories.
5. Optional: `/rpa-gen-rules` adds agent rules for Cursor, Claude Code and Codex on top of the
   rendered `AGENTS.md`.

## Validators as long-term memory

There is no unit-test suite. Correctness is `validate.sh` green plus `deploy.sh` and
`tests/smoke.sh` passing. Treat them as the project's tests and run them after every change.
