# Skill: RPA Init for caddy-coddy

## Description
Initialize the Coddy agent for work with the caddy-coddy infrastructure repository.

## Trigger
`rpa-init`

## Steps
1. Verify agent is running in the correct workspace (caddy-coddy repo)
2. Run `validate.sh` to confirm all configs are sane
3. Check SSH connectivity to superset (`192.168.135.10`)
4. Report reachable backends (Keycloak, oauth2-proxy, Caddy)
5. Load any persisted session notes from `memory/rpa/`

## Guards
- Must not run deploy if validation fails
- Must not attempt remote operations if SSH is unavailable
- Must verify `.env` is present on superset before checking secrets
