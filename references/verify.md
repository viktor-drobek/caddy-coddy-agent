# Phase 4: verify (end to end)

Goal: every access path proven against the live stack, and the Coddy version recorded.

```bash
bash "$CC/scripts/verify.sh" --record <project>    # full run, then write coddy_version and verified_at
bash "$CC/scripts/verify.sh" --no-cli <project>    # skip the one check that calls a model
```

`verify.sh` runs the project's `tests/smoke.sh`, which copies `tests/smoke-remote.sh` to the edge
and runs it there against Caddy on `127.0.0.1` with the real host name and SNI, so it works behind
NAT. It creates a throwaway Keycloak user and deletes it at the end. The checks, printed as `PASS`
or `FAIL` lines:

- **anonymous**: page load → 302 to `/oauth2/start`; XHR and EventSource → 401 (never a
  redirect); a junk bearer token → 401; the Keycloak admin console, admin API and master realm →
  302; realm `coddy` discovery → 200 with the right issuer;
- **browser login**: the themed login page, temporary password → forced change, callback lands on
  `/` with 200 and the Coddy UI, `/coddy/auth/me` authenticated through the cookie,
  `/coddy/sessions` 200, SSE `/coddy/events` streams, the admin console opens with the Coddy
  cookie, sign-out ends the session;
- **Swarm Relay** (when `CODDY_SWARM_TOKEN` is set): anonymous absolute and prefixed relay paths
  return 401; the browser cookie reaches `/swarm/info`, `/swarm-relay/swarm/info` and the relay
  host's `/swarm-relay/v1/models`; aggregated sessions have no per-node `warnings` such as
  `swarm-ml: 401 Unauthorized`;
- **service**: a `coddy-service` client_credentials token with audience `coddy-web`, authenticated
  at `/coddy/auth/me`, `/coddy/sessions` 200;
- **person**: a `coddy-cli` password-grant token with a 7-day lifetime, `/coddy/sessions` 200,
  `/v1/models` lists models, `/openapi.json` reports the Coddy version;
- **CLI** (unless `--no-cli`): `coddy cli --remote <public_url>` answers with a Keycloak token and
  is refused with a wrong one. This needs a Linux `coddy` binary of the edge's architecture on
  this machine (it is copied over and run in a container on the edge); `verify.sh` skips it
  otherwise and says so.

`--record` writes `coddy_version` and `verified_at` into `caddy-coddy.yml` only after successful
staging, a zero SSH exit status, the remote `SMOKE_COMPLETE` marker, and no failed checks.
Interrupted or incomplete runs fail without changing the manifest. After a green run,
commit that change. Without `--record`, a version that differs from the recorded one is reported.

## After a Coddy upgrade

Run `verify` again. A failing check is information about the new Coddy version (a changed page
title, a renamed endpoint): report it as such, look at what changed, and adjust the template or the
check deliberately. Do not delete the check.

## Quick health without the full test

`bash "$CC/scripts/health.sh" <project>`: container health from `docker compose ps`, page-load
302, XHR 401, OIDC discovery 200, admin console 302. Use it after a redeploy or when someone
reports a problem.
