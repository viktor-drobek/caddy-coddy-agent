---
name: caddy-coddy
version: 1.0.3
description: >
  Run when the user invokes /caddy-coddy (with plan, build, validate, deploy, verify or ops), or asks to
  expose a Coddy server (coddy serve) on a public HTTPS address with real user logins. Plans the
  architecture with the user, renders a Caddy + Keycloak + oauth2-proxy stack from templates into a
  project directory, validates it, deploys it with docker compose to the edge host of the user's choice
  over ssh, tests every access path end to end, records the Coddy version, and then provides the tools
  for users, tokens and service clients. Needs the user's answers about hosts and the public name.
---

# caddy-coddy: a public, authenticated edge for a Coddy server

You build and operate this, on hosts the user names:

```
internet ── https://<public_host> ──► Caddy :443 (edge host, host network)
                                         ├── /auth/*    → Keycloak (realm "coddy": users, login page)
                                         ├── /oauth2/*  → oauth2-proxy (OIDC client, session cookie)
                                         └── /*  forward_auth → oauth2-proxy, then reverse_proxy → coddy serve
                                                Authorization := "Bearer <CODDY_API_TOKEN>"
```

Browsers log in at Keycloak and get a session cookie; scripts and services present a Keycloak
token (password grant on the public client `coddy-cli`, client_credentials on a machine client).
Caddy verifies every request through oauth2-proxy and forwards it to `coddy serve` with Coddy's
own `httpserver.auth_token`. Nobody but the proxy ever holds Coddy's token, and Coddy's own
sign-in screen is never shown behind the proxy.

## Phases

The first word after `/caddy-coddy` picks the phase. Without one, read `caddy-coddy.yml` in the
project directory (if it exists) and tell the user which phase comes next. Never run a later phase
before the earlier ones passed.

| Phase | What happens | Read first | Run |
|---|---|---|---|
| `plan` | Ask the questions, agree the architecture with the user, write `caddy-coddy.yml`, run the preflight | `references/plan.md` | `scripts/manifest.py init ...`, `scripts/preflight.sh` |
| `build` | Render the templates into the project directory, review the result, validate | `references/build.md` | `scripts/render.py --check --diff`, `scripts/render.py`, `scripts/validate.sh` |
| `validate` | Re-run the validators alone (after hand edits) | `references/build.md` | `scripts/validate.sh` |
| `deploy` | First run creates `.env` on the edge; rsync, `docker compose up -d`, Keycloak bootstrap, health probes | `references/deploy.md` | `scripts/deploy.sh` |
| `verify` | End-to-end smoke test of every access path; `--record` stores the Coddy version in the manifest | `references/verify.md` | `scripts/verify.sh --record` |
| `ops` | Users, passwords, tokens, service clients, Coddy token rotation, logs, theme | `references/operations.md` | the project's own tools (`add-user.sh`, `add-service.sh`, ...) |

Every script takes the project directory as its last argument (default: the current directory)
and finds the skill's own files relative to itself. Locate this skill's directory once (the folder
holding this `SKILL.md`; `coddy skills list` prints the search roots, typically
`~/.coddy/skills/caddy-coddy`, `~/.agents/skills/caddy-coddy` or
`<project>/.coddy/skills/caddy-coddy`) and call the scripts by that path, for example
`bash ~/.coddy/skills/caddy-coddy/scripts/preflight.sh .`.

## The plan questions (ask these, in one message, in the user's language)

`references/plan.md` explains each one; when you cannot read files or run commands (plan mode,
a dry run, denied permissions), ask them from here and stop after the architecture summary.

1. Where does `coddy serve` run, on which address and port does it listen (`httpserver.host` /
   `httpserver.port`, default `0.0.0.0:12345`), and is `httpserver.auth_token` set?
2. Which host is the edge (Caddy, Keycloak, oauth2-proxy): the same machine or another one? It
   needs Linux, Docker with the compose plugin, ssh key login, passwordless sudo, ports 80/443
   open to the internet, about 1.5 GB of free RAM.
3. The public DNS name (its record must point at the edge or a NAT forwarding 80/443 to it);
   TLS comes from Let's Encrypt through Caddy automatically.
4. The first user's username (created with a temporary password) and optional email.
5. The project directory here (default: current directory) and on the edge (default
   `/opt/caddy-coddy`).
6. Is this machine the Coddy host? Otherwise the user exports `CODDY_API_TOKEN` for the tools.

Then summarise the architecture with their names in it and wait for agreement before writing
`caddy-coddy.yml` (`scripts/manifest.py init ...`) and running `scripts/preflight.sh`.

## Ground rules

1. **Hosts come from the user.** There is no default edge, Coddy host or domain. Everything about
   *where* lives in `caddy-coddy.yml`: ask, do not assume, and echo the plan back before writing it.
2. **Validation first.** State the observable outcome (which request gets 302, 401, 200), run the
   validators, then change, then deploy, then verify. Never deploy a project that failed `validate`.
3. **Secrets never enter the conversation.** Do not read `.env` on the edge, do not print tokens,
   client secrets or password hashes. The only secret shown to the user is a freshly generated
   *temporary* password or a new client secret, once, by the tool that created it.
4. **Keep the security contract** (`references/security-contract.md`) when touching `Caddyfile`,
   `oauth2-proxy.toml` or anything under `keycloak/`. It lists what breaks silently.
5. **Confirm before**: the first deploy to a host, anything that deletes (users, clients, realms,
   volumes, `.env`), and a change of `public_host` after Keycloak imported the realm.
6. **Generated files are generated.** Fix behaviour in this skill's templates, not in a rendered
   copy; site-only customisations go under `keep:` in the manifest. English in every file; answer
   the user in their language. Commit messages describe the change and carry no tool signatures.
7. **Report** at the end of each phase: what changed (files), what was validated (commands and
   results), what was deployed (`docker compose ps` summary), what was verified (PASS/FAIL counts
   and the Coddy version), and what comes next.

## Compatibility

The templates and the smoke checks were last proven end to end against the Coddy version recorded
in this skill's `manifest.yml` (`tested_coddy_version`). Each site records its own pass in
`caddy-coddy.yml` (`coddy_version`, `verified_at`). After a Coddy upgrade run `verify --record`
again; a failing check is information about the new version, so report it rather than deleting
the check.
