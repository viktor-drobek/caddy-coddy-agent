# Phase 5: operate (users, realm, tokens)

The tools live in the rendered project and run from the machine you deploy from. They ssh to the
edge and run `kcadm` inside the Keycloak container with the admin credentials from the edge's
`.env`; they never print those credentials. Users live in realm **`coddy`**. A user in `master` is
a Keycloak administrator and cannot sign in to Coddy.

## People

| Task | Command | Notes |
|---|---|---|
| Create a user | `./add-user.sh alice [alice@example.com]` | Prints a temporary password once; Keycloak forces a new one at the first sign-in at `<public_url>/`. `TEMP_PASSWORD='...' ./add-user.sh alice` chooses it |
| Reset a password | `./add-user.sh --reset alice` | New temporary password |
| Remove a user | `./remove-user.sh alice` | Confirm with the user first. Keycloak sessions end at once; a browser that still holds a proxy cookie is signed out at the next token refresh (within 5 minutes) |
| List users | `./list-users.sh` | username, email, enabled |
| Self-service password change | `<public_url>/auth/realms/coddy/account/` | For the users themselves |
| Log out everywhere | `<public_url>/oauth2/sign_out?rd=<public_url>/auth/realms/coddy/protocol/openid-connect/logout?client_id=coddy-web%26post_logout_redirect_uri=<public_url>/` | Clears the proxy session, then Keycloak asks to confirm ending the SSO session |

Brute-force protection is on: 10 failures, then a growing lock-out of up to 15 minutes.

## Tokens for people (CLI, API, OpenAI clients)

```bash
eval "$(./coddy-login.sh alice)"       # asks the Keycloak password; exports CODDY_REMOTE_TOKEN, OPENAI_BASE_URL, OPENAI_API_KEY
coddy cli --remote <public_url>
./coddy-login.sh alice --raw           # just the token (valid 7 days)
```

The token is a Keycloak access token from the public client `coddy-cli` (password grant); Caddy
swaps it for Coddy's token on every request. A user who has not yet replaced the temporary
password gets "Account is not fully set up": one sign-in in a browser fixes it.

## Service clients (machine to machine)

```bash
./add-service.sh reporting-bot "Nightly report generator"   # creates the client, prints its secret once
./add-service.sh --rotate reporting-bot                       # new secret
SVC_TOKEN=$(curl -s -X POST <public_url>/auth/realms/coddy/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=reporting-bot -d client_secret="$SECRET" | jq -r .access_token)
curl -H "Authorization: Bearer $SVC_TOKEN" <public_url>/coddy/sessions
```

Service tokens live 15 minutes (the realm's `accessTokenLifespan`). Every machine client must
carry the **audience mapper** for `coddy-web`, otherwise oauth2-proxy rejects its tokens (`aud`
check); `add-service.sh` adds it. `coddy-service` is the example client from the realm import; its
secret is `CODDY_SERVICE_CLIENT_SECRET` in `.env`. To rotate this managed client, edit that value
on the edge and redeploy. `add-service.sh` rejects `coddy-service` because bootstrap would
otherwise overwrite the new secret on the next deploy.

## Telegram Mini App

| Task | How |
|---|---|
| Enable | `.env` on the edge: `TG_BOT_TOKEN` (the bot the Mini App belongs to), `TG_ALLOWED_USER_IDS`, `TG_AUTH_COOKIE_SECRET`; `deploy.sh`; then in BotFather set the bot's menu button (or `/newapp`) to `<public_url>/tg/` |
| Allow or remove a person | Edit `TG_ALLOWED_USER_IDS` in the edge's `.env` (and `telegram_user_ids` in the manifest so a re-render agrees), then `deploy.sh`; removal takes effect at the next request |
| Find a Telegram user id | The person asks `@userinfobot`; Coddy's own gateway config lists admins by id |
| End every Telegram session | Rotate `TG_AUTH_COOKIE_SECRET` and redeploy |
| End one session | The person opens `<public_url>/tg/logout` |
| Turn it off | Empty `TG_BOT_TOKEN`, redeploy: `/tg/` answers 404 and existing cookies stop working |

Telegram sessions are separate from Keycloak: no Keycloak user is created, Coddy sees
`X-Forwarded-User: <telegram username>`. The `_coddy_tg` cookie takes precedence over a Keycloak
session in the same browser.

## Coddy's own token

`httpserver.auth_token` is the one secret shared between Coddy and Caddy. When it changes (a
rotation, a Coddy reinstall), on the host running `coddy serve`, after restarting it with the new
token:

```bash
./sync-coddy-token.sh
```

It reads the token from Coddy's config (or `CODDY_HTTP_TOKEN`), checks that Coddy accepts it,
writes `CODDY_API_TOKEN` into the edge's `.env`, restarts Caddy and verifies `/coddy/auth/me`
with a Keycloak service token.

## Swarm relay

When the Coddy host also runs a Swarm Relay, set `CODDY_SWARM_TOKEN` in the edge `.env` to the
relay's `swarm.auth_token`, then redeploy. Authenticated browser traffic may use either the
configured remote prefix `<public_url>/swarm-relay` or the absolute `/swarm/*` paths the UI uses
after it recognises a relay. Caddy discards the caller's `Authorization` header and presents
`CODDY_SWARM_TOKEN` only to `SWARM_RELAY_BACKEND`; `/swarm-relay/coddy/*` and
`/swarm-relay/v1/*` remain on the ordinary Coddy backend with `CODDY_API_TOKEN`.

The three Swarm credentials have different jobs:

| Credential | Purpose |
|---|---|
| `swarm.auth_token` / edge `CODDY_SWARM_TOKEN` | lets a client use the relay |
| `swarm.pairing_tokens` / `swarm.join[].pairing_token` | lets a node register |
| `swarm.join[].token` | lets the relay call that node's HTTP API; it must equal that node's `httpserver.auth_token` |

### `swarm-<host>: 401 Unauthorized` while every relay request is HTTP 200

This is a fan-out warning inside the JSON response, not necessarily a Caddy response status. The
relay and topology endpoints can all return HTTP 200 while their `warnings` array contains, for
example, `swarm-ml: 401 Unauthorized`. The node is registered, but the per-node token handed to
the relay does not authenticate against that node's HTTP API.

Check only status metadata; do not print tokens or session bodies:

```bash
curl -sS -H "Authorization: Bearer $CODDY_SWARM_TOKEN" \
  http://127.0.0.1:12346/swarm/sessions?limit=1 \
  | jq '{warnings, node_more}'
```

For a self-node, a typical configuration is:

```yaml
httpserver:
  auth_token: "${CODDY_HTTP_TOKEN}"
swarm:
  join:
    - url: http://127.0.0.1:12346
      name: swarm-ml
      pairing_token: "${CODDY_SWARM_PAIRING_TOKEN}"
      token: "${CODDY_HTTP_TOKEN}"
```

Both references must resolve to the same non-empty value. A common failure is setting
`CODDY_HTTP_TOKEN` only in a systemd override while config interpolation reads `~/.coddy/.env`:
the HTTP server receives the override, but `swarm.join[].token` is registered with a different or
empty value. Put the same token in the private env source used by the config (`chmod 600`), restart
Coddy so the node re-registers, and verify that `warnings` is empty and the mounted endpoints
`/swarm/nodes/<name>/coddy/auth/me` and `/swarm/nodes/<name>/v1/models` return 200. Compare only
lengths or hashes when diagnosing; never log the credentials themselves.

## Keycloak admin console

`<public_url>/auth/admin/`: first the Coddy login (a session cookie from realm `coddy` is
required), then Keycloak's own `KC_ADMIN_USER` / `KC_ADMIN_PASSWORD` from the edge's `.env`. Switch
the realm selector from **master** to **coddy** before touching users or clients.

## Rotating the stack's secrets

Edit `.env` on the edge (`ssh <edge_ssh>`, then `<edge_dir>/.env`) and run `deploy.sh`: it
recreates oauth2-proxy and re-runs `bootstrap.sh`, which writes the client secrets into Keycloak.
Rotating `KC_DB_PASSWORD` after the first start also needs `ALTER USER` in Postgres (or a fresh
volume). Rotating `OAUTH2_PROXY_COOKIE_SECRET` signs everyone out.

## Changing the public name

Keycloak imported the realm once with the old `public_url` in the `coddy-web` client (root URL,
redirect URI, web origin, post-logout URI). After changing `public_host` in the manifest,
re-rendering and redeploying, update those four fields on client `coddy-web` in the admin console
(realm `coddy`, Clients) and run `verify`. Deleting the realm and redeploying also works, at the
price of every user.

## Logs and status

```bash
bash "$CC/scripts/health.sh" <project>
ssh <edge_ssh> 'cd <edge_dir> && sudo docker compose ps && sudo docker compose logs --tail 100 caddy oauth2-proxy keycloak'
```

Caddy's access log is JSON on stdout; oauth2-proxy logs every `/oauth2/auth` decision.

## Login page styling

Edit `keycloak/themes/coddy/login/resources/css/coddy.css` (or
`messages/messages_en.properties`) in the project and run `deploy.sh`; it clears Keycloak's
on-disk gzip cache and restarts Keycloak. Browsers cache theme assets for 1 hour. A change meant
for every site belongs in the templates; a change for this site only belongs under `keep:`.

## Backups

Two volumes are worth keeping: `caddy-coddy_keycloak_pgdata` (users and clients) and
`caddy-coddy_caddy_data` (certificates, re-issued automatically if lost). `pg_dump` inside the
`keycloak-db` container covers the first.
