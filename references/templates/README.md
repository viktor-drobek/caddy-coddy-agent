# caddy-coddy

Internet access to the Coddy server on **@@CODDY_HOST_NAME@@** through Caddy on **@@EDGE_NAME@@**,
with **Keycloak** as the identity provider.

```
                internet
                    │ @@PUBLIC_URL@@
        ┌───────────▼───────────┐   @@EDGE_NAME@@ (@@EDGE_HOST@@)
        │ Caddy :443 (host net) │
        │  /auth/*   ──────────────► Keycloak :8080 (+ Postgres)   realm "coddy"
        │  /oauth2/* ──────────────► oauth2-proxy :4180
        │  /tg/*     ──────────────► tg-auth :4181 (Telegram Mini App sign-in)
        │  /*  forward_auth ───────► oauth2-proxy /oauth2/auth
        │      then reverse_proxy, Authorization := "Bearer CODDY_API_TOKEN"
        └───────────┬───────────┘
                    │
        ┌───────────▼───────────┐   @@CODDY_HOST_NAME@@ (@@CODDY_BACKEND_HOST@@)
        │ coddy serve :@@CODDY_BACKEND_PORT@@    │   httpserver.auth_token = CODDY_API_TOKEN
        └───────────────────────┘
```

## Who gets in

| Caller | Presents | Checked by | Coddy receives |
| --- | --- | --- | --- |
| Browser | oauth2-proxy session cookie, obtained by logging in at Keycloak with username + password | oauth2-proxy (`/oauth2/auth`) | `Authorization: Bearer <CODDY_API_TOKEN>` |
| Service | `Authorization: Bearer <Keycloak access token>` from the OAuth2 client_credentials grant (client `coddy-service`) | oauth2-proxy verifies the JWT: signature (Keycloak JWKS), issuer `@@PUBLIC_URL@@/auth/realms/coddy`, audience `coddy-web` | `Authorization: Bearer <CODDY_API_TOKEN>` |
| Person from a script / CLI | `Authorization: Bearer <Keycloak access token>` from the password grant on the public client `coddy-cli` (7-day token) | same JWT checks | `Authorization: Bearer <CODDY_API_TOKEN>` |
| Telegram Mini App | `_coddy_tg` cookie, issued after Telegram's signed `initData` was verified and the Telegram user id found in `TG_ALLOWED_USER_IDS` | tg-auth (`/tg/auth/verify`) | `Authorization: Bearer <CODDY_API_TOKEN>` |

Coddy's own sign-in screen is never shown through the proxy: with the bearer
token present, `GET /coddy/auth/me` reports `authenticated: true`. Coddy's
password login stays enabled for direct access to `:@@CODDY_BACKEND_PORT@@` on its own host.

**Two kinds of token, never mixed up.** People and services only ever hold
*Keycloak* tokens (browser session, `coddy-cli` password grant, `coddy-service`
client credentials). *Coddy's* own API token (`httpserver.auth_token`, copied
into `.env` as `CODDY_API_TOKEN`) exists only in Coddy's config on @@CODDY_HOST_NAME@@ and in
Caddy's environment on @@EDGE_NAME@@; Caddy replaces the incoming Keycloak token with
it on every proxied request. Nobody needs to know it to use Coddy. When it
changes in Coddy's config, `./sync-coddy-token.sh` copies it to the proxy.

Only page loads (`Accept: text/html`) without a valid cookie are redirected to
`/oauth2/start` and on to the Keycloak login page. The UI's own XHR/SSE calls
and any request with an invalid or expired bearer token get a plain `401`.
(Redirecting XHR too made several parallel `/oauth2/start` calls overwrite the
login state cookie, and the callback then failed with a PKCE mismatch, shown
by oauth2-proxy as a 500 "Proceed" page.)

The login may stay open for up to an hour (Keycloak `accessCodeLifespanLogin`);
oauth2-proxy keeps one login-state cookie per started login for 2 hours
(`cookie_csrf_per_request`, `cookie_csrf_expire`). With the defaults (one
shared cookie, 15 minutes) a slow first login ended in
"Unable to find a valid CSRF token".

The login page is the Keycloak `coddy` theme (`keycloak/themes/coddy`): a plain
dark card with Coddy branding and no vendor branding.

## Files

| Path | Purpose |
| --- | --- |
| `caddy-coddy.yml` | Site manifest: the hosts and addresses this project was rendered for, and the Coddy version it last passed the smoke test against. Read by the caddy-coddy agent (`/caddy-coddy`) |
| `Caddyfile` | Routing, forward_auth, header rewrite |
| `docker-compose.yml` | caddy, keycloak, keycloak-db, oauth2-proxy (all on @@EDGE_NAME@@) |
| `.env.example` | Every address and secret the stack needs; the real `.env` lives only on @@EDGE_NAME@@ |
| `keycloak/import/realm-coddy.json` | Realm `coddy`, clients `coddy-web` (browser login), `coddy-service` (example machine client with the audience mapper) and `coddy-cli`. Imported on first start. |
| `keycloak/bootstrap.sh` | Idempotent: client secrets from `.env`, `coddy-cli` client, login theme, VERIFY_PROFILE off, first user with a temporary password |
| `keycloak/client-coddy-cli.json` | Public client for people's API tokens (password grant), created by `bootstrap.sh` when missing |
| `keycloak/themes/coddy/` | Login theme (parent `keycloak.v2` + `coddy.css`, messages, favicon) |
| `add-user.sh` | Create a Coddy user in realm `coddy` with a temporary password, or reset one |
| `remove-user.sh` | Delete a user from realm `coddy` |
| `list-users.sh` | List the users of realm `coddy` |
| `add-service.sh` | Create a machine client (client_credentials) with the `coddy-web` audience mapper, or rotate its secret |
| `coddy-login.sh` | For people: Keycloak username/password -> Keycloak token exported for `coddy cli --remote` and API clients |
| `sync-coddy-token.sh` | For the operator: copy Coddy's `httpserver.auth_token` from its config on @@CODDY_HOST_NAME@@ into the proxy `.env` and restart Caddy |
| `tests/smoke.sh` | End-to-end test of every access path; `--record` writes the Coddy version it passed against into `caddy-coddy.yml` |
| `oauth2-proxy/oauth2-proxy.toml` | OIDC client settings, bearer-token acceptance, cookie |
| `tg-auth/server.py` | Telegram Mini App sign-in: verifies Telegram's signed `initData`, allow list of Telegram user ids, `_coddy_tg` session cookie, Caddy's `/tg/auth/verify` |
| `deploy.sh` | rsync to @@EDGE_NAME@@ `@@EDGE_DIR@@`, `docker compose up -d`, run bootstrap |

## Deploy

From this checkout, on any machine with ssh access to @@EDGE_NAME@@:

```sh
./deploy.sh
```

First time only: `@@EDGE_DIR@@/.env` must exist on @@EDGE_NAME@@. The caddy-coddy
agent creates it (`/caddy-coddy deploy` runs `init-env.sh`, which fills
`.env.example` with generated secrets); by hand, copy `.env.example` and fill
it in: `CODDY_API_TOKEN` is `httpserver.auth_token` from
`@@CODDY_HOST_NAME@@:~/.coddy/config.yaml`, every other secret is random
(`openssl rand -hex 32`).

Keycloak takes about a minute to start; `deploy.sh` waits for its health check
before running `bootstrap.sh`. Confidential clients are imported disabled, with
no shared placeholder secret; bootstrap enables each one together with its real
secret. The Caddy volume `caddy-coddy_caddy_data` keeps
the Let's Encrypt certificate across redeploys.

A changed `Caddyfile` recreates Caddy so its single-file bind mount sees the new
file and the new routes take effect. This briefly interrupts active connections.
The auth handler forwards refreshed session cookies, including split cookies,
to the browser on successful requests.

## Adding a user

Users live in Keycloak realm **coddy**. Two ways:

**Script (from this checkout):**

```sh
./add-user.sh alice alice@example.com
```

It prints a temporary password once; Keycloak forces a new password at the
first sign-in at `@@PUBLIC_URL@@/`. `TEMP_PASSWORD='...' ./add-user.sh alice`
uses a password of your choice, and `./add-user.sh --reset alice` issues a new
temporary password to an existing user. `./remove-user.sh alice` deletes a
user, `./list-users.sh` lists them.

**Admin console:** `@@PUBLIC_URL@@/auth/admin/` (you must already be
signed in to Coddy in that browser; then use `KC_ADMIN_USER` / `KC_ADMIN_PASSWORD`
from `.env`). In the realm dropdown at the top left switch from **master** to
**coddy** *before* creating the user (*Users → Add user*, then *Credentials →
Set password*, leave *Temporary* on). A user created in the `master` realm is a
Keycloak administrator account and **cannot sign in to Coddy**.

Users change their own password at `@@PUBLIC_URL@@/auth/realms/coddy/account/`.

Logout: `@@PUBLIC_URL@@/oauth2/sign_out?rd=@@PUBLIC_URL@@/auth/realms/coddy/protocol/openid-connect/logout?client_id=coddy-web%26post_logout_redirect_uri=@@PUBLIC_URL@@/`
clears the proxy session at once (the next page load asks for a login again),
then lands on a Keycloak page asking to confirm the logout; confirming ends the
Keycloak SSO session too. Without that confirmation the next login is silent
(Keycloak still remembers the user).

## Telegram Mini App

Coddy can be opened as a Telegram Mini App by the people listed in
`TG_ALLOWED_USER_IDS`, without a Keycloak account: Telegram signs the app's
`initData` with the bot's token, `tg-auth` verifies that signature, checks the
user id against the list and sets the `_coddy_tg` cookie; from then on Caddy
checks every request at `tg-auth` instead of oauth2-proxy and forwards it to
Coddy with the same `CODDY_API_TOKEN` swap. Coddy sees `X-Forwarded-User` set
to the Telegram username.

Setup:

1. `.env` on @@EDGE_NAME@@: `TG_BOT_TOKEN` (the bot the Mini App belongs to; the
   caddy-coddy agent copies it from `gateways.telegram.token` of the local Coddy
   config when it creates `.env`), `TG_ALLOWED_USER_IDS` (numeric Telegram user
   ids, comma-separated; `@userinfobot` tells you yours), `TG_AUTH_COOKIE_SECRET`
   (`openssl rand -hex 32`). Then `./deploy.sh`.
2. In [@BotFather](https://t.me/BotFather): *Bot Settings → Menu Button* (or
   `/newapp`) with the URL `@@PUBLIC_URL@@/tg/`.
3. Open the bot's menu button in Telegram: the landing page signs in and lands
   on the Coddy UI. Sessions last 7 days; `@@PUBLIC_URL@@/tg/logout` ends one.

Rules: an empty `TG_BOT_TOKEN` turns the whole path off (`/tg/` answers 404),
an empty list admits nobody, `initData` older than an hour is rejected, and the
`_coddy_tg` cookie takes precedence over a Keycloak session in the same
browser (a stale one sends page loads back to `/tg/`, where Telegram signs in
again; outside Telegram the page offers the username/password login). To
remove a person, take the id out of the list and redeploy; to end every
Telegram session at once, rotate `TG_AUTH_COOKIE_SECRET`.

## Is the Keycloak admin API reachable from the internet?

No. `/auth/admin/*` (console and admin REST API) and `/auth/realms/master/*`
are behind the same `forward_auth` as Coddy: without a Coddy session cookie
Caddy redirects to the login page, and API calls get 401. Keycloak's own
master-realm credentials are still required after that. Everything under
`/auth/realms/coddy/*` (login pages, token endpoint, account console) stays
public because the login flow needs it. Rate limiting of failed logins is
Keycloak's brute-force protection (10 failures, growing lock-out up to 15 min).

## API access from the CLI (people)

A person authenticates to **Keycloak** with their Coddy username and password
and gets a Keycloak access token (public client `coddy-cli`, valid 7 days). That
Keycloak token is what goes into `coddy cli --remote`, `curl` and OpenAI
clients. Caddy verifies it and forwards the request to Coddy with Coddy's own
token; the person never sees or needs Coddy's token.

```sh
eval "$(./coddy-login.sh alice)"        # asks for the Keycloak password; exports CODDY_REMOTE_TOKEN, OPENAI_BASE_URL, OPENAI_API_KEY
coddy cli --remote @@PUBLIC_URL@@
```

The same by hand (`KC_TOKEN` is the Keycloak token):

```sh
read -rs -p 'Keycloak password: ' KC_PASSWORD; echo
KC_TOKEN=$(curl -s -X POST @@PUBLIC_URL@@/auth/realms/coddy/protocol/openid-connect/token \
  -d grant_type=password -d client_id=coddy-cli -d scope=openid \
  -d username=alice --data-urlencode "password=$KC_PASSWORD" | jq -r .access_token)

curl -H "Authorization: Bearer $KC_TOKEN" @@PUBLIC_URL@@/coddy/auth/me   # authenticated: true
curl -H "Authorization: Bearer $KC_TOKEN" @@PUBLIC_URL@@/coddy/sessions
curl -H "Authorization: Bearer $KC_TOKEN" @@PUBLIC_URL@@/v1/models     # OpenAI-compatible API
```

A user whose temporary password has not been changed yet gets
"Account is not fully set up": sign in once at `@@PUBLIC_URL@@/` first.

Any OpenAI-compatible client works with base URL `@@PUBLIC_URL@@/v1` and
the Keycloak token as the API key; Coddy's modes (`agent`, `plan`, `ask`, ...)
are the model names:

```sh
export OPENAI_BASE_URL=@@PUBLIC_URL@@/v1 OPENAI_API_KEY=$KC_TOKEN
python - <<'EOF'
from openai import OpenAI
c = OpenAI()
print(len(c.models.list().data), "models")
r = c.chat.completions.create(model="ask", messages=[{"role": "user", "content": "Reply with the single word: pong"}])
print(r.choices[0].message.content)
EOF
```

### Coddy CLI against the remote server

The Coddy CLI can drive the server behind Caddy instead of a local one with
`--remote`. Pass the **Keycloak** token as `--remote-token` or
`CODDY_REMOTE_TOKEN` (`coddy-login.sh` exports it):

```sh
# interactive console on the remote server
export CODDY_REMOTE_TOKEN=$KC_TOKEN
coddy cli --remote @@PUBLIC_URL@@

# one-shot prompt, plain output (good for scripts)
coddy cli --remote @@PUBLIC_URL@@ --remote-token "$KC_TOKEN" --plain --prompt "Reply with the single word: pong"
# -> pong

# pick an existing remote session (interactive picker; needs a real terminal)
coddy cli --remote @@PUBLIC_URL@@ --resume
```

Always use the `https://` URL form. A bare `host:port` (`@@PUBLIC_HOST@@:443`)
means plain HTTP and fails with "Client sent an HTTP request to an HTTPS server".
A missing or expired token gives:

```
session/new: remote coddy @@PUBLIC_URL@@: unauthorized (check --remote-token or CODDY_REMOTE_TOKEN)
```

`--remote` also accepts a name from `httpserver.remotes` in the local
`~/.coddy/config.yaml`, so the URL does not have to be typed each time (the
token is never stored there):

```yaml
httpserver:
  remotes:
    - name: meet
      url: @@PUBLIC_URL@@
```

```sh
CODDY_REMOTE_TOKEN=$KC_TOKEN coddy cli --remote meet
```

In a local Coddy web UI the same Keycloak token can be pasted as the token of a
remote environment pointing at `@@PUBLIC_URL@@` (Coddy keeps it
client-side). When the token expires, `401` / "unauthorized" comes back: run
`coddy-login.sh` again.

## API access for services (OAuth2 client_credentials)

```sh
SVC_TOKEN=$(curl -s -X POST @@PUBLIC_URL@@/auth/realms/coddy/protocol/openid-connect/token \
  -d grant_type=client_credentials -d client_id=coddy-service \
  -d client_secret="$CODDY_SERVICE_CLIENT_SECRET" | jq -r .access_token)   # a Keycloak token

curl -H "Authorization: Bearer $SVC_TOKEN" @@PUBLIC_URL@@/coddy/sessions
```

Service tokens live 15 minutes (`accessTokenLifespan` in the realm; `coddy-cli`
overrides it to 7 days). To add a new service, run `./add-service.sh <client-id> [name]`:
it creates a client in realm `coddy` with *Client authentication* on, *Service
accounts roles* on and a **Mapper → Audience** with *Included Client Audience*
`coddy-web`, and prints the client secret once (`--rotate` issues a new one).
The managed `coddy-service` client is excluded: rotate `CODDY_SERVICE_CLIENT_SECRET`
in the edge's `.env` and redeploy, since bootstrap owns that client's secret.
The same can be done in the admin console by copying `coddy-service` from
`keycloak/import/realm-coddy.json`. Without that mapper oauth2-proxy rejects the
token (`aud` check).

## Operations

```sh
ssh @@EDGE_SSH@@
cd @@EDGE_DIR@@
sudo docker compose ps
sudo docker compose logs -f caddy oauth2-proxy keycloak
sudo docker compose exec -T keycloak bash -s < keycloak/bootstrap.sh   # re-apply secrets / first user
```

- `realm-coddy.json` is only imported when realm `coddy` does not exist yet.
  Later changes go through the admin console (or delete the realm and redeploy).
- Rotating `CODDY_WEB_CLIENT_SECRET` / `CODDY_SERVICE_CLIENT_SECRET`: edit
  `.env`, run `deploy.sh` (recreates oauth2-proxy and re-runs bootstrap).
- Coddy's token changed (rotated in `httpserver.auth_token`, or set anew after
  a Coddy upgrade): restart `coddy serve` on @@CODDY_HOST_NAME@@, then run `./sync-coddy-token.sh`
  there. It reads the token from Coddy's config (or `CODDY_HTTP_TOKEN`), checks
  Coddy accepts it, writes `CODDY_API_TOKEN` into the proxy `.env` on @@EDGE_NAME@@,
  restarts Caddy and verifies `/coddy/auth/me` with a Keycloak service token.
- Login page styling: edit `keycloak/themes/coddy/login/resources/css/coddy.css`
  (or `messages/messages_en.properties` for texts) and run `deploy.sh`. When
  theme files changed it clears Keycloak's on-disk gzip cache
  (`data/tmp/kc-gzip-cache`, which otherwise keeps serving the old CSS through
  Caddy) and restarts Keycloak. Browsers cache theme assets for 1 hour.

## Testing, and re-testing on a new Coddy release

```sh
tests/smoke.sh            # every access path, PASS/FAIL per check
tests/smoke.sh --record   # ...and pin the Coddy version it passed against in caddy-coddy.yml
tests/smoke.sh --no-cli   # skip the one check that calls a model (coddy cli --remote)
```

Run from the checkout you deploy from. The checks execute on @@EDGE_NAME@@ against Caddy with the
real hostname and a throwaway Keycloak user (deleted at the end): anonymous
redirect vs 401, admin-console gating, the themed login with a temporary
password and forced change, cookie session incl. SSE, `coddy-service`
client-credentials token, `coddy-cli` password-grant token, `/v1/models`,
`coddy cli --remote` with a Keycloak token and with a wrong one (this last
check needs a Linux `coddy` binary of the edge's architecture on the machine
running the test).

Failed staging, a nonzero SSH exit, or a missing remote `SMOKE_COMPLETE` marker
fails the run. `--record` never updates the manifest for an interrupted or failed run.

The Coddy version behind the proxy is read from `/openapi.json` and compared
with `coddy_version` in `caddy-coddy.yml`, the version of the last recorded
pass. After a Coddy release: run `tests/smoke.sh`, and when it is green,
`--record` and commit the manifest.

## Provenance

This project was rendered by the **caddy-coddy** agent (a Coddy skill,
`/caddy-coddy`) from its templates and the answers in `caddy-coddy.yml`. To
change a host, an address or the first user, edit `caddy-coddy.yml`, run
`/caddy-coddy build` (or the agent's `render.py`) and redeploy. Hand edits to
rendered files are overwritten by the next build unless the file is listed
under `keep:` in the manifest; changes to the stack's behaviour (routing,
tokens, cookies) belong in the agent's templates so every site gets them.
