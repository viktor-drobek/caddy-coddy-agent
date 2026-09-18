# caddy-coddy agent

A [Coddy](https://coddy.dev) skill, `/caddy-coddy`, that puts a Coddy server behind a public HTTPS
address with real logins: **Caddy** (TLS, routing) + **Keycloak** (users, realm `coddy`, login
page) + **oauth2-proxy** (OIDC client, session cookie, bearer-token check), deployed with Docker
Compose to a host you choose, over ssh. Browsers log in at Keycloak; scripts and services use
Keycloak tokens; Coddy's own API token never leaves the proxy.

```
internet ── https://<public_host> ──► Caddy :443 (edge host)
                                         ├── /auth/*    → Keycloak
                                         ├── /oauth2/*  → oauth2-proxy
                                         └── /*  forward_auth → oauth2-proxy → reverse_proxy → coddy serve
                                                Authorization := "Bearer <CODDY_API_TOKEN>"
```

## Install

Any of these makes `/caddy-coddy` available in Coddy:

```bash
coddy skills add viktor-drobek/caddy-coddy-agent        # into ~/.coddy/skills/caddy-coddy
npx skills add viktor-drobek/caddy-coddy-agent          # into ~/.agents/skills (skills.sh CLI)
git clone https://github.com/viktor-drobek/caddy-coddy-agent ~/.coddy/skills/caddy-coddy
```

Or vendor it into a project as a git submodule and link it into the project's skills folder, which
Coddy reads with the highest priority:

```bash
git submodule add https://github.com/viktor-drobek/caddy-coddy-agent tools/caddy-coddy-agent
mkdir -p .coddy/skills && ln -s ../../tools/caddy-coddy-agent .coddy/skills/caddy-coddy
```

Requirements on the machine running Coddy: `bash`, `ssh`, `rsync`, `curl`, `python3`, `openssl`;
optional `jq`, `docker` (local validation) and a Linux `coddy` binary (the CLI smoke check). On the
edge host: Linux, Docker with the compose plugin, ssh key login, passwordless sudo, ports 80 and
443 reachable from the internet. `coddy serve` must have `httpserver.auth_token` set.

## Lifecycle

| Command | Phase |
|---|---|
| `/caddy-coddy plan` | Questions, architecture agreed with you, `caddy-coddy.yml` written, preflight (ssh, sudo, docker, DNS, ports, Coddy reachability) |
| `/caddy-coddy build` | Templates rendered into the project directory; `bash -n`, JSON, `docker compose config`, `caddy validate` |
| `/caddy-coddy deploy` | First run creates `.env` on the edge with generated secrets; rsync, `docker compose up -d`, Keycloak bootstrap, health probes |
| `/caddy-coddy verify` | End-to-end smoke test of every access path (anonymous, browser login, service token, CLI token, `coddy cli --remote`); `--record` stores the Coddy version in the manifest |
| `/caddy-coddy ops` | Users, passwords, tokens, service clients, Coddy token rotation, logs, theme |

The scripts behind the phases work without Coddy too:

```bash
CC=~/.coddy/skills/caddy-coddy
python3 "$CC/scripts/manifest.py" init --public-host meet.example.com --edge-ssh ops@edge.example.com \
        --coddy-backend 10.0.0.5:12345 --initial-user alice
bash    "$CC/scripts/preflight.sh"
python3 "$CC/scripts/render.py" --check --diff && python3 "$CC/scripts/render.py"
bash    "$CC/scripts/validate.sh"
bash    "$CC/scripts/deploy.sh"
bash    "$CC/scripts/verify.sh" --record
```

## Layout

```
SKILL.md                  the skill: phases, ground rules, report format
manifest.yml              agent manifest: version, Coddy version the templates were last proven against
scripts/                  lifecycle tooling: manifest.py, render.py, preflight, validate, init-env, deploy, verify, health
references/               one page per phase, the security contract, and templates/
references/templates/     the parameterised stack: Caddyfile, docker-compose.yml, .env.example, keycloak/,
                          oauth2-proxy/, deploy.sh, user and token tools, tests/, README.md, AGENTS.md
examples/caddy-coddy.yml  an example site manifest
```

A rendered project is self-contained: its own `README.md` documents the site with the real names in
it, `deploy.sh` and the tools default to that site's edge, and `tests/smoke.sh` re-tests it after a
Coddy release. The site manifest `caddy-coddy.yml` records the hosts and the Coddy version of the
last passing smoke test; `manifest.yml` here records the Coddy version the templates were last
proven against.

## Versioning and releases

The version lives in `manifest.yml` and is mirrored in the `SKILL.md` frontmatter (Coddy shows it in
`coddy skills list` and uses it to detect updates). Releases are `vX.Y.Z` tags; the `Release`
workflow turns a tag into a GitHub release with that version's `CHANGELOG.md` section as notes and
a source archive. CI runs `make check`, shellcheck and a real `docker compose config` plus
`caddy validate` on a fresh render of the example manifest for every push and pull request.

```bash
make check                  # what CI runs
make bump VERSION=1.1.0     # manifest.yml + SKILL.md, opens a CHANGELOG.md section
make release                # tags v<version>; then: git push origin main v<version>
coddy skills add viktor-drobek/caddy-coddy-agent@v1.0.3   # pin a release
```

## Security contract

Seven invariants the templates encode and the skill refuses to drift from, spelled out in
`references/security-contract.md`. In short: Coddy's token stays in the proxy, only page loads are
redirected to the login, issuer and audience are verified, secrets stay out of git, users live in
realm `coddy`, the Keycloak admin API sits behind the login, and deploys wait for Keycloak's health.

## Local regression checks

```bash
python3 tests/regression.py
CADDY_BIN=/path/to/caddy python3 tests/regression.py
```

The checks use temporary rendered sites and command stubs; they never contact the edge. With
`CADDY_BIN`, they also run Caddy against HTTP stubs bound to loopback to check authentication,
split-cookie refresh, redirects, identity headers and request-body/token isolation. These checks
complement configuration validation and the deployed stack's end-to-end smoke tests.
