# Phase 3: deploy

Goal: the four containers run healthy on the edge, Keycloak is bootstrapped and the health
probes pass.

```bash
bash "$CC/scripts/deploy.sh" <project>                  # validate, init-env, ./deploy.sh, health
bash "$CC/scripts/deploy.sh" --skip-validate <project>
```

## First deploy

1. Confirm with the user: the edge, the directory, the public name, that ports 80 and 443 are
   open, and that this is the first deploy (a `.env` will be generated).
2. `init-env.sh` creates `<edge_dir>` (sudo, chowned to the ssh user) and `<edge_dir>/.env` from
   `.env.example` with generated secrets (`openssl rand`). Coddy's token comes from
   `$CODDY_API_TOKEN`, `$CODDY_HTTP_TOKEN` or the local `~/.coddy/config.yaml`
   (`httpserver.auth_token`). When none is available the script stops and says so: ask the user
   to export the token as an environment variable; never paste it into the conversation.
3. The project's `deploy.sh` rsyncs the checkout (without `.env`, `.git` and agent folders), runs
   `docker compose pull` and `up -d`, waits for the Keycloak health check (up to five minutes on
   a slow machine), then runs `keycloak/bootstrap.sh` inside the container, retrying while
   Keycloak still imports the realm.
4. The only secret printed is the initial user's temporary password. Hand it to the user; the
   first sign-in at `<public_url>/` forces a new one.
5. Caddy obtains the Let's Encrypt certificate on the first request or shortly after starting;
   `curl` may see a TLS error during the first minute. The certificate lives in the `caddy_data`
   volume and survives redeploys.

## Redeploy

The same command. It is idempotent: unchanged files are not sent again, containers are recreated
only when their configuration changed, and `bootstrap.sh` re-applies secrets and settings without
touching existing users. When theme files changed, `deploy.sh` clears Keycloak's gzip cache and
restarts it; when `oauth2-proxy.toml` changed, it restarts oauth2-proxy.

## Reading the output

A good run prints, in order: rsync changes, `docker compose up`, "waiting for keycloak to become
healthy", "running keycloak bootstrap" with `bootstrap: ...` lines, `docker compose ps` with four
`(healthy)` rows, then the health probes as `PASS` lines.

| Symptom | Cause and fix |
|---|---|
| `missing <edge_dir>/.env` | `init-env.sh` did not run or failed; run `deploy.sh` again and read its message |
| `keycloak is not healthy (starting)` with `ERROR` lines in the log | Usually `KC_DB_PASSWORD` changed after the first start (Postgres keeps the old one in its volume), or too little RAM |
| `bootstrap: client coddy-web not found` | The realm import failed; `docker compose logs keycloak` shows why |
| Page load returns 502 | Caddy cannot reach `coddy_backend`: check that `coddy serve` listens on that address and that the edge's firewall allows it |
| Login works, then a `500 Proceed` page | oauth2-proxy CSRF/PKCE mismatch: only page loads may be redirected to `/oauth2/start`; see the security contract |
| `Unable to find a valid CSRF token` | The login took longer than `cookie_csrf_expire`; the template sets 2 h |
| `sudo: a password is required` | The ssh user has no passwordless sudo on the edge |

Run `verify` next. Everything after that lives in `references/operations.md`.
