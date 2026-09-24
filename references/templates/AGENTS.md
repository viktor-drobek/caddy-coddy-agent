# AGENTS.md

Agent brief for this **caddy-coddy** site: a Caddy edge + Keycloak IAM + oauth2-proxy that expose
the Coddy server on **@@CODDY_HOST_NAME@@** at `@@PUBLIC_URL@@`, running on **@@EDGE_NAME@@**.

This project was rendered by the caddy-coddy agent (Coddy skill `/caddy-coddy`) from the answers
in `caddy-coddy.yml`. Fix stack behaviour in the agent's templates and re-render; changes for
this site only go into files listed under `keep:` in the manifest.

## What this repository is

Infrastructure as code, not an application: there is no unit-test suite. Correctness is **config
validation plus a successful deploy and smoke test**: `bash -n`, `jq .`,
`docker compose config -q`, `caddy validate`, `./deploy.sh`, `tests/smoke.sh`. Treat them as the
project's tests and run them after every change (`/caddy-coddy validate`, `deploy`, `verify`).

| Path | What it is |
| --- | --- |
| `caddy-coddy.yml` | Site manifest: hosts, addresses, first user, `keep:` list, and the Coddy version of the last smoke-test pass |
| `Caddyfile` | Edge routing: `/auth/*` → Keycloak, `/oauth2/*` → oauth2-proxy, `/swarm/*` → the optional Swarm Relay with its client token, `/*` → `forward_auth` + reverse proxy to Coddy with the Authorization header swapped to Coddy's own token |
| `docker-compose.yml` | Five services on @@EDGE_NAME@@: `caddy` (host network, `:443`), `keycloak` + `keycloak-db`, `oauth2-proxy`, `tg-auth`; Keycloak, oauth2-proxy and tg-auth publish on `127.0.0.1` only |
| `.env.example` | Every address and secret; the real `.env` lives only on @@EDGE_NAME@@ (`@@EDGE_DIR@@/.env`) and is never committed |
| `keycloak/import/realm-coddy.json` | Realm `coddy` with clients `coddy-web`, `coddy-service`, `coddy-cli`; imported only when the realm does not exist yet |
| `keycloak/bootstrap.sh` | Idempotent post-start configuration: client secrets from `.env`, `coddy-cli` if missing, `VERIFY_PROFILE` off, theme, first user |
| `keycloak/themes/coddy/` | Login theme |
| `oauth2-proxy/oauth2-proxy.toml` | OIDC client `coddy-web`, cookie, bearer-token acceptance |
| `tg-auth/server.py` | Telegram Mini App sign-in: verifies Telegram's signed `initData` with `TG_BOT_TOKEN`, admits `TG_ALLOWED_USER_IDS`, issues the `_coddy_tg` cookie, answers Caddy's `/tg/auth/verify` |
| `deploy.sh` | rsync to `@@EDGE_SSH@@:@@EDGE_DIR@@`, `docker compose up -d`, wait for health, bootstrap |
| `add-user.sh`, `remove-user.sh`, `list-users.sh` | Users of realm `coddy` (temporary passwords, forced change) |
| `add-service.sh` | Machine clients with the `coddy-web` audience mapper |
| `coddy-login.sh` | A person's Keycloak token for `coddy cli --remote` and API clients |
| `sync-coddy-token.sh` | Copy Coddy's `httpserver.auth_token` into the proxy `.env` (run on @@CODDY_HOST_NAME@@) |
| `tests/smoke.sh` | End-to-end test of every access path; `--record` writes `coddy_version` into the manifest |

Coddy runs on @@CODDY_HOST_NAME@@ (`@@CODDY_BACKEND@@` as seen from the edge); everything else
runs on @@EDGE_NAME@@. Deploy from any checkout with ssh access to `@@EDGE_SSH@@`.

## The security contract (do not drift)

1. Clients never learn Coddy's token; Coddy never sees Keycloak tokens (Caddy's `header_up
   Authorization`; oauth2-proxy's `pass_authorization_header = false`).
2. Only `Accept: text/html` page loads without a session are redirected to `/oauth2/start`;
   XHR, SSE and bad bearer tokens get a plain `401`, never a redirect.
3. oauth2-proxy verifies the issuer `@@PUBLIC_URL@@/auth/realms/coddy` and the audience
   `coddy-web`; machine clients need the audience mapper.
4. Secrets stay out of the repository: `.env` is ignored and never rsynced; compose fails fast on
   `${VAR:?}`; the realm file carries no secrets.
5. Users live in realm `coddy`; a `master` user cannot sign in to Coddy.
6. `/auth/admin/*` and `/auth/realms/master/*` are behind `forward_auth`; only
   `/auth/realms/coddy/*` is public.
7. `deploy.sh` waits for Keycloak's readiness probe before bootstrap and retries while the realm
   imports.
8. Telegram sign-in admits only verified `initData` (HMAC with the bot token, at most an hour
   old) of a user in `TG_ALLOWED_USER_IDS`; an empty token or list admits nobody, and the
   `/tg/auth/verify` endpoint is never public.
9. Swarm credentials stay isolated: Caddy sends `CODDY_SWARM_TOKEN` only to
   `SWARM_RELAY_BACKEND` for `/swarm/*`, while `/swarm-relay/coddy/*` and
   `/swarm-relay/v1/*` use `CODDY_API_TOKEN` and the ordinary Coddy backend. Every node's
   `swarm.join[].token` must equal its own `httpserver.auth_token`; otherwise the node remains
   visible but fan-out responses contain `<node>: 401 Unauthorized` warnings.

## Working on the stack

Build from the layer that depends on nothing upward: the `.env` contract → Keycloak state
(`realm-coddy.json`, `bootstrap.sh`) → oauth2-proxy → Caddy → deployment and operations. A Caddy
route to a backend that compose does not define is a broken stack. For every change: state the
observable outcome (which request gets 302, 401, 200), validate, change the smallest layer,
deploy, verify with `curl` or `tests/smoke.sh`, report. English in files, with comments that
explain *why*; the user's language in chat; no secrets in files, logs or chat.
