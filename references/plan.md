# Phase 1: plan the architecture with the user

Goal: a `caddy-coddy.yml` the other phases can trust, and a user who knows what will run where.
Nothing is rendered or deployed in this phase.

## 1. Ask

One message with every open question; skip what the user already said.

1. **Coddy.** On which host does `coddy serve` run, on which address and port does it listen
   (`httpserver.host` / `httpserver.port` in its `config.yaml`, default `0.0.0.0:12345`), and is
   `httpserver.auth_token` set? It must be: Caddy authenticates to Coddy with that token.
2. **Edge.** Which host runs Caddy, Keycloak and oauth2-proxy: the same machine as Coddy, or
   another one? It needs Linux, Docker with the compose plugin, ssh with a key, passwordless `sudo`
   for that ssh user, ports 80 and 443 reachable from the internet, and about 1.5 GB of free RAM
   (Keycloak + Postgres).
3. **Public name.** The DNS name people will type, for example `meet.example.com`. Its A/AAAA
   record must point at the edge's public address, or at a NAT that forwards 80 and 443 to the
   edge. TLS certificates come from Let's Encrypt through Caddy; there are no certificate files.
4. **First user.** The operator's Coddy username (created in Keycloak with a temporary password),
   optionally an email address.
5. **Paths.** The project directory on this machine (default: the current directory) and on the
   edge (default `/opt/caddy-coddy`).
6. **Where the tools run.** Is this machine the Coddy host? `init-env.sh` and
   `sync-coddy-token.sh` read Coddy's token from the local `~/.coddy/config.yaml`; anywhere else
   the user exports `CODDY_API_TOKEN` instead.
7. **Telegram Mini App** (optional). Should Coddy also open as a Telegram Mini App? Then: the
   numeric Telegram user ids allowed in (`@userinfobot` shows one's own), and the bot the Mini App
   belongs to. The bot token is read from `gateways.telegram.token` of the local Coddy config when
   this machine is the Coddy host, otherwise the user exports `TG_BOT_TOKEN`; the Mini App URL to
   set in BotFather is `<public_url>/tg/`.
8. **Swarm Relay** (optional). Does this Coddy host also run a relay? Record its `host:port` as
   seen from the edge (default: the Coddy backend host on port 12346) and confirm that
   `swarm.auth_token` is set. Its value is entered privately as `CODDY_SWARM_TOKEN`; never ask the
   user to paste it into chat.

## 2. Decide and explain

| Situation | `coddy_backend` | Notes |
|---|---|---|
| Coddy and the edge on one host | `127.0.0.1:<port>` | Caddy runs in host network mode, so loopback works and Coddy may keep listening on 127.0.0.1 |
| Two hosts on one LAN | `<coddy LAN address>:<port>` | Coddy must listen on `0.0.0.0` (or that interface) **and** have `auth_token` set, otherwise the LAN can use it without a login |
| Two hosts across the internet | `<coddy address>:<port>` | Edge to Coddy is plain HTTP: acceptable only inside a VPN or WireGuard tunnel. Otherwise run Coddy on the edge host |

Write the plan back in the user's language: the diagram from `SKILL.md` with their names in it,
the table row that applies, and these facts.

- Who gets in: browsers (Keycloak login, session cookie), scripts (`coddy-cli` password grant,
  7-day token), services (client_credentials, 15-minute tokens). Coddy's own login screen is never
  shown behind the proxy.
- The Keycloak admin console and the master realm are reachable only after a Coddy login.
- What the first deploy creates on the edge: `<edge_dir>/.env` with generated secrets (never
  committed), four containers, two Docker volumes (Postgres data, Caddy certificates).
- Time: Keycloak needs about a minute to start; the whole first deploy takes a few minutes.

Wait for agreement or corrections before step 3.

## 3. Write the manifest and run the preflight

```bash
CC=<skill dir>
python3 "$CC/scripts/manifest.py" -f <project>/caddy-coddy.yml init \
  --public-host meet.example.com --edge-ssh ops@edge.example.com --coddy-backend 10.0.0.5:12345 \
  --swarm-relay-backend 10.0.0.5:12346 \
  --edge-name edge --coddy-host-name workstation --initial-user alice \
  --telegram-user-ids 123456789                                            # optional; the rest has defaults
bash "$CC/scripts/preflight.sh" <project>
```

`manifest.py check` prints every resolved value, including the derived host and port fields.
The preflight prints PASS / WARN / FAIL for the manifest, the local tools, ssh and sudo on the edge,
docker compose there, ports 80/443, DNS against the edge's addresses (a WARN is normal behind
NAT), whether the edge reaches `coddy serve` and whether Coddy has bearer auth on, and the state of
`<edge_dir>/.env`. Fix every FAIL with the user before `build`; report the WARNs and what they mean.

## Manifest reference

Flat `key: value` lines; `examples/caddy-coddy.yml` shows a complete file.

| Key | Required | Meaning |
|---|---|---|
| `public_host` | yes | DNS name of the site |
| `public_url` | default `https://<public_host>` | Origin without a path; the OIDC issuer is `<public_url>/auth/realms/coddy` |
| `edge_ssh` | yes | `[user@]host` for ssh; ssh config aliases work |
| `edge_dir` | default `/opt/caddy-coddy` | Project directory on the edge (rsync target, compose project) |
| `edge_name` | default: host part of `edge_ssh` | Short name used in comments and documentation |
| `coddy_backend` | yes | `host:port` of `coddy serve` **as seen from the edge** |
| `swarm_relay_backend` | default `<coddy_backend host>:12346` | optional Swarm Relay `host:port` as seen from the edge |
| `coddy_host_name` | default: host part of `coddy_backend` | Short name used in comments and documentation |
| `coddy_local_url` | default `http://127.0.0.1:<port>` | `coddy serve` as seen from the machine running the tools |
| `initial_user` | default empty | First user of realm `coddy` (temporary password, change forced) |
| `telegram_user_ids` | default empty | Telegram user ids allowed to open Coddy as a Mini App (comma-separated); empty keeps Telegram sign-in off |
| `keep` | default empty | Comma-separated rendered paths that `build` never overwrites once present |
| `agent_version` | written by `init` | Version of this skill that wrote the file |
| `coddy_version`, `verified_at` | written by `verify --record` | Last successful smoke test |

A later change of `public_host` needs care: Keycloak imports the realm once, so the `coddy-web`
client keeps the old redirect URIs. `references/operations.md` has the procedure.
