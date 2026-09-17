# Skill: RPA Gen Rules for caddy-coddy

## Description
Generate and validate Coddy agent rule files (`.claude/rules`, `.cursor/rules`, `.codex/`) from the canonical AGENTS.md.

## Trigger
`rpa-gen-rules`

## Steps
1. Read `AGENTS.md` in the caddy-coddy repo
2. Parse section headers and rules
3. Generate `.claude/rules/<topic>.md` files
4. Mirror to `.cursor/rules/<topic>.mdc` files
5. Update `.codex/rules.md` index if topics changed
6. Run `validate.sh` to confirm the repo is still clean

## Maintenance
- If a rule file is updated, this skill must regenerate its mirror in every agent tree
- Do not change content; only adapt frontmatter and links
