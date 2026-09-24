# Changelog

All notable changes to the caddy-coddy agent. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/): a new major version means rendered
projects need manual changes, minor adds phases, tools or manifest keys, patch
fixes behaviour. Each release is a `vX.Y.Z` tag with a GitHub release built by
the `Release` workflow; install a specific one with
`coddy skills add viktor-drobek/caddy-coddy-agent@vX.Y.Z`.

## [1.1.0] - 2026-09-24

### Added

- **Telegram Mini App sign-in.** New service `tg-auth` (`tg-auth/server.py`,
  standard-library Python in the plain `python:3.12-alpine` image, loopback
  port 4181): verifies Telegram's signed `initData` with the bot token
  (`TG_BOT_TOKEN`), admits only the Telegram user ids in
  `TG_ALLOWED_USER_IDS`, issues the signed `_coddy_tg` cookie and answers
  Caddy's `/tg/auth/verify`. Caddy serves the landing page at `/tg/` and
  checks requests carrying the cookie at tg-auth instead of oauth2-proxy, with
  the same Coddy token swap. Empty token or list admits nobody; `initData`
  older than an hour is rejected; the verify endpoint is not public.
- Manifest key `telegram_user_ids` (`--telegram-user-ids`), env keys
  `TG_AUTH_BACKEND`, `TG_BOT_TOKEN`, `TG_ALLOWED_USER_IDS`,
  `TG_AUTH_COOKIE_SECRET`; `init-env.sh` takes the bot token from
  `$TG_BOT_TOKEN` or `gateways.telegram.token` of the local Coddy config.
- `init-env.sh` upgrades an existing `.env`: keys the env contract gained
  since are appended (secrets generated), existing keys are never touched.
- Smoke test: 13 Telegram checks (signed `initData` of an allowed user, the
  cookie through to Coddy, a user not on the list, tampered and stale
  `initData`, stale cookie on page loads and XHR, logout, verify not public);
  skipped when the feature is off. Regression tests for the Telegram routes.
- Plan question 7 and documentation for the feature.

### Changed

- `deploy.sh` restarts `tg-auth` when its code changed.

## [1.0.4] - 2026-09-18

Six review findings on first installs, redeploys and verification, from the
pull request "Fix bootstrap credentials, proxy sessions and deployment
verification", rebased onto 1.0.3. Proven on the reference deployment: fresh
redeploy (Caddy recreated, clients enabled by bootstrap) and the full smoke test,
32 of 32 checks, against Coddy 1.1.53.

### Fixed

- Caddyfile: the auth check is an expanded `reverse_proxy` instead of
  `forward_auth`. It copies every `Set-Cookie` of a successful `/oauth2/auth`
  answer to the browser (refreshed and split session cookies, cookie deletion
  on the login redirect), and strips caller-supplied `X-Auth-Request-*`
  headers before setting the ones oauth2-proxy returned, so a missing claim
  (a service account's email) can no longer be spoofed by the caller. Token
  isolation, request bodies and the cookie-only admin-console check are kept.
- Realm import: `coddy-web` and `coddy-service` are imported disabled and
  without a placeholder secret; `bootstrap.sh` installs the real secret and
  enables the client in one update, so a fresh site cannot issue tokens with a
  shared placeholder before bootstrap ran.
- `deploy.sh`: a changed `Caddyfile` recreates the Caddy container. rsync
  replaces the file's inode and the single-file bind mount kept serving the
  old routes; active connections are interrupted briefly.
- `tests/smoke.sh`: `--record` writes the manifest only after successful
  staging, a zero ssh exit status, the remote `SMOKE_COMPLETE` marker and no
  failed checks; `smoke-remote.sh` exits non-zero on any failure.
- `validate.sh`: compose and Caddy validation are mandatory; no local Docker
  and no reachable edge is a FAIL, not a SKIP.
- `add-service.sh` refuses `--rotate coddy-service`: bootstrap owns that
  secret (`CODDY_SERVICE_CLIENT_SECRET` in `.env`).

### Added

- `tests/regression.py`: 19 checks with command stubs (deploy, bootstrap,
  smoke, validate, add-service) and, with `CADDY_BIN`, the rendered proxy
  against loopback HTTP stubs. Part of `make check` and of CI, which takes the
  Caddy binary from the `caddy:2` image.

## [1.0.3] - 2026-09-18

Tested well on Coddy 1.1.49 with the neuraldeep.ru models **qwen3.8-27b** and
**kimi-k2.6**: fresh sessions, plan mode, the skill's plan questions asked
verbatim with the right defaults and nothing written; the existing-site state
reported correctly from `caddy-coddy.yml`. Recorded as `tested_models` in
`manifest.yml`.

### Added

- Versioning: `manifest.yml` is the single source of the version, mirrored in
  the `SKILL.md` frontmatter and checked by `make check`; `make bump`,
  `make release`, this changelog.
- CI (`.github/workflows/ci.yml`): on every push and pull request runs
  `make check`, shellcheck, and `docker compose config` plus `caddy validate`
  on a fresh render of the example manifest.
- Release workflow (`.github/workflows/release.yml`): a `v*` tag whose version
  matches `manifest.yml` and has a changelog section becomes a GitHub release
  with those notes and a `caddy-coddy-<version>.tar.gz` archive.

### Changed

- `SKILL.md`: without a phase word, read `caddy-coddy.yml` with the file-read
  tool (a model whose shell was denied asked the plan questions instead).

## [1.0.2] - 2026-09-18

### Changed

- `SKILL.md` carries the six plan questions with their defaults, so a model
  without shell or file access (plan mode, a dry run, denied permissions) asks
  the right questions and stops after the architecture summary.

## [1.0.1] - 2026-09-18

### Fixed

- `deploy.sh` template: the theme branch's `docker compose exec` attached stdin
  and swallowed the rest of the remote script on a first deploy, so the
  Keycloak bootstrap never ran. Redirected from `/dev/null`.
- `realm-coddy.json` template: the explicit `requiredActions` list suppressed
  Keycloak's default required actions on import, so `UPDATE_PASSWORD` was
  missing and temporary passwords were never forced to change. The list is
  gone; `bootstrap.sh` registers the default actions on realms that lack them.

## [1.0.0] - 2026-09-18

### Added

- The skill `/caddy-coddy` with the phases plan, build, validate, deploy,
  verify and ops; one reference page per phase and the security contract.
- Templates of the whole stack (Caddy, Keycloak, oauth2-proxy, deploy and
  operator tools, end-to-end smoke test) rendered from a flat site manifest.
- Tools: `manifest.py`, `render.py`, `preflight.sh`, `validate.sh`,
  `init-env.sh`, `deploy.sh`, `verify.sh`, `health.sh`; new operator tools
  `remove-user.sh`, `list-users.sh`, `add-service.sh`.
- `manifest.yml` with the Coddy version the templates were last proven against.
