# The security contract (do not drift)

Nine invariants make the stack work. Each has been broken by a plausible edit before; keep them
when changing `Caddyfile`, `oauth2-proxy/oauth2-proxy.toml`, `docker-compose.yml` or anything
under `keycloak/`.

1. **Clients never learn Coddy's token; Coddy never sees Keycloak tokens.** Caddy replaces the
   caller's `Authorization` with `Bearer <CODDY_API_TOKEN>` (`header_up` in the `coddy_upstream`
   block). oauth2-proxy keeps `pass_authorization_header = false` and `pass_access_token = false`.
   Never add `copy_headers Authorization`.
2. **Page loads versus API calls.** Only requests with `Accept: text/html` and no valid session
   get a `302` to `/oauth2/start`. XHR, SSE and any bad or expired bearer token get a plain `401`.
   Redirecting XHR too made parallel `/oauth2/start` calls overwrite the login-state cookie, and
   the callback failed with a PKCE mismatch (oauth2-proxy's 500 "Proceed" page).
3. **Issuer and audience.** oauth2-proxy verifies the issuer `<public_url>/auth/realms/coddy` and
   the audience `coddy-web`; every machine client needs the `coddy-web` audience mapper.
   `skip_oidc_discovery = true` with back-channel URLs at `http://keycloak:8080/...` lets
   oauth2-proxy start before Caddy and never depend on its own public name; `KC_HOSTNAME` pins the
   public issuer.
4. **Secrets stay out of the repository.** `.env` is git-ignored and excluded from rsync; compose
   fails fast on an unset required secret (`${VAR:?}`). The realm imports confidential clients
   disabled, without secrets. Bootstrap installs each real secret from `.env` and enables its
   client in the same update, so a failed first bootstrap leaves it unusable.
5. **Users live in realm `coddy`.** A user in `master` is a Keycloak admin and cannot sign in to
   Coddy. Every tool here creates users in `coddy`.
6. **The admin API is not public.** `/auth/admin/*` and `/auth/realms/master/*` sit behind
   `forward_auth` (session cookie only; `header_up -Authorization` because the console sends its
   own master-realm token). Only `/auth/realms/coddy/*` (login, token endpoint, account console,
   theme assets) is public.
7. **Keycloak health gating.** `deploy.sh` waits for the management-port readiness probe before
   bootstrap, then retries bootstrap while Keycloak still imports the realm; oauth2-proxy has
   `depends_on: condition: service_healthy`. Keep the health checks and the wait loop.
8. **Telegram sign-in fails closed.** `tg-auth` accepts an `initData` only with a valid HMAC
   made from `TG_BOT_TOKEN`, an `auth_date` at most an hour old and a user id listed in
   `TG_ALLOWED_USER_IDS`; an empty token or list admits nobody. Its cookie is signed with
   `TG_AUTH_COOKIE_SECRET`, `/tg/auth/verify` answers 404 to the internet, identity headers come
   only from the verify response, and the Coddy token swap applies as for every other caller.
9. **Swarm credentials stay in their own lanes.** `/swarm-relay/swarm/*` (with the prefix
   removed) and absolute `/swarm/*` go to `SWARM_RELAY_BACKEND` only after oauth2-proxy accepts
   the browser session; Caddy removes any caller `Authorization` and sends
   `Bearer <CODDY_SWARM_TOKEN>`. `/swarm-relay/coddy/*` and `/swarm-relay/v1/*` instead go to
   `CODDY_BACKEND` with `CODDY_API_TOKEN`, because they describe the relay host's own Coddy API.
   The relay client token must never reach Coddy, and Coddy's HTTP token must never be used as the
   relay client token. Inside the swarm, every `swarm.join[].token` must match that node's own
   `httpserver.auth_token`; a mismatch leaves the node visible but degrades fan-out responses with
   `<node>: 401 Unauthorized` warnings.

Also load-bearing:

- The expanded `forward_auth` handler copies every `Set-Cookie` response header to the browser,
  including split cookies and cookie deletion on redirects. Without this, the browser keeps
  stale tokens after oauth2-proxy's five-minute refresh.
- `cookie_csrf_per_request = true`, `cookie_csrf_expire = "2h"` and Keycloak's
  `accessCodeLifespanLogin = 3600`: a slow first login, password change included, must not end in
  "Unable to find a valid CSRF token".
- `flush_interval -1` and zero read/write timeouts on the Coddy upstream: Coddy streams over SSE.
- Keycloak and oauth2-proxy publish on `127.0.0.1` only; Caddy is the single public surface.
- `VERIFY_PROFILE` is disabled so an account created with only a username is not blocked at the
  first login.
- Nothing here prints a secret: not the tools, not the logs, not the agent.
