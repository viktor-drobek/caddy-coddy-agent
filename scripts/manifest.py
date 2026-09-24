#!/usr/bin/env python3
"""Read, write and validate the caddy-coddy site manifest (caddy-coddy.yml).

The manifest is deliberately flat: one `key: value` per line, `#` comments, no
nesting. This script (standard library only) and the shell tools (`sed`) read it
without a YAML library.

    manifest.py [-f FILE] init --public-host HOST --edge-ssh [USER@]HOST --coddy-backend HOST:PORT
                [--public-url URL] [--edge-dir DIR] [--edge-name NAME] [--coddy-host-name NAME]
                [--coddy-local-url URL] [--initial-user USER] [--keep PATHS] [--force]
    manifest.py [-f FILE] check                validate; print every resolved variable
    manifest.py [-f FILE] get KEY [DEFAULT]    print one value (exit 1 when missing and no default)
    manifest.py [-f FILE] set KEY VALUE ...    update or append keys, keeping comments and order
    manifest.py [-f FILE] vars [--shell]       KEY=value lines for render.py, or CC_KEY='value' for bash

FILE defaults to ./caddy-coddy.yml. Derived values (EDGE_HOST, EDGE_USER,
CODDY_BACKEND_HOST, CODDY_BACKEND_PORT, KC_HOSTNAME) are computed, never stored.
"""
from __future__ import annotations

import argparse
import os
import re
import shlex
import sys

DEFAULT_FILE = "caddy-coddy.yml"
LINE_RE = re.compile(r"^([a-z][a-z0-9_]*):[ \t]*(.*?)[ \t]*$")
SKILL_MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "manifest.yml")

# (key, comment written above it by `init`, default). None marks a required key.
# The order is the order `init` writes the file in.
FIELDS = [
    ("agent_version", "Version of the caddy-coddy agent that wrote this file.", ""),
    ("public_host", "Public DNS name of the site; its A/AAAA record points at the edge, or at a NAT that forwards 80/443 to it.", None),
    ("public_url", "Public origin without a path; the OIDC issuer is <public_url>/auth/realms/coddy.", ""),
    ("edge_name", "Short name of the edge host, used in comments and documentation.", ""),
    ("edge_ssh", "ssh target of the edge host ([user@]host or an ssh config alias); needs docker compose and passwordless sudo.", None),
    ("edge_dir", "Directory on the edge that receives the project (rsync target and docker compose project).", "/opt/caddy-coddy"),
    ("coddy_host_name", "Short name of the host running coddy serve, used in comments and documentation.", ""),
    ("coddy_backend", "coddy serve address as seen from the edge (host:port; 127.0.0.1:PORT when both share one host).", None),
    ("coddy_local_url", "coddy serve URL as seen from the machine running the tools (init-env.sh, sync-coddy-token.sh).", ""),
    ("initial_user", "First user of realm coddy, created with a temporary password (empty: none).", ""),
    ("telegram_user_ids", "Telegram user ids allowed to open Coddy as a Telegram Mini App, comma-separated (empty: Telegram sign-in off).", ""),
    ("keep", "Comma-separated rendered paths that build creates once and never overwrites.", ""),
    ("coddy_version", "Coddy version the deployed stack last passed tests/smoke.sh against (written by verify --record).", ""),
    ("verified_at", "UTC time of that pass (written by verify --record).", ""),
]
KNOWN = {key for key, _, _ in FIELDS}
REQUIRED = [key for key, _, default in FIELDS if default is None]
DERIVED = ("EDGE_USER", "EDGE_HOST", "CODDY_BACKEND_HOST", "CODDY_BACKEND_PORT", "KC_HOSTNAME")

HOST_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
SSH_RE = re.compile(r"^([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+$")
BACKEND_RE = re.compile(r"^([A-Za-z0-9._-]+):([0-9]{1,5})$")
URL_RE = re.compile(r"^https?://[^\s/]+$")
USER_RE = re.compile(r"^[A-Za-z0-9._@-]*$")
TG_IDS_RE = re.compile(r"^([0-9]+(,[0-9]+)*)?$")


class ManifestError(Exception):
    pass


def read(path: str):
    """Return (raw lines, {key: value}); raw lines allow `set` to round-trip comments."""
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        raise ManifestError(f"{path}: not found (run the plan phase: manifest.py init ...)") from None
    values: dict[str, str] = {}
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = LINE_RE.match(line)
        if not match:
            raise ManifestError(f"{path}:{number}: expected `key: value`, got {line!r}")
        key, value = match.group(1), match.group(2)
        value = re.sub(r"\s+#.*$", "", value)  # trailing comment
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key in values:
            raise ManifestError(f"{path}:{number}: duplicate key {key}")
        values[key] = value
    return lines, values


def derive(values: dict[str, str]) -> dict[str, str]:
    """Validate, fill defaults and add the derived fields. Raises ManifestError."""
    v = {key: value for key, value in values.items()}
    missing = [key for key in REQUIRED if not v.get(key)]
    if missing:
        raise ManifestError("missing required key(s): " + ", ".join(missing))
    unknown = sorted(set(v) - KNOWN)
    if unknown:
        raise ManifestError("unknown key(s): " + ", ".join(unknown))

    v["public_host"] = v["public_host"].strip().lower().rstrip(".")
    if not HOST_RE.match(v["public_host"]):
        raise ManifestError(f"public_host {v['public_host']!r} is not a DNS name (no scheme, no path)")
    v["public_url"] = (v.get("public_url") or f"https://{v['public_host']}").rstrip("/")
    if not URL_RE.match(v["public_url"]):
        raise ManifestError(f"public_url {v['public_url']!r} must be an origin like https://host (no path)")
    if not v["public_url"].startswith("https://"):
        raise ManifestError("public_url must use https:// (Caddy terminates TLS and the cookies are Secure)")

    if not SSH_RE.match(v["edge_ssh"]):
        raise ManifestError(f"edge_ssh {v['edge_ssh']!r} must look like [user@]host")
    user, _, host = v["edge_ssh"].rpartition("@")
    v["EDGE_USER"], v["EDGE_HOST"] = user, host

    v["edge_dir"] = (v.get("edge_dir") or "/opt/caddy-coddy").rstrip("/") or "/"
    if not v["edge_dir"].startswith("/") or ".." in v["edge_dir"].split("/"):
        raise ManifestError(f"edge_dir {v['edge_dir']!r} must be an absolute path")

    match = BACKEND_RE.match(v["coddy_backend"])
    if not match or not 0 < int(match.group(2)) < 65536:
        raise ManifestError(f"coddy_backend {v['coddy_backend']!r} must be host:port as seen from the edge")
    v["CODDY_BACKEND_HOST"], v["CODDY_BACKEND_PORT"] = match.group(1), match.group(2)

    v["edge_name"] = v.get("edge_name") or host
    v["coddy_host_name"] = v.get("coddy_host_name") or match.group(1)
    v["coddy_local_url"] = (v.get("coddy_local_url") or f"http://127.0.0.1:{match.group(2)}").rstrip("/")
    if not URL_RE.match(v["coddy_local_url"]):
        raise ManifestError(f"coddy_local_url {v['coddy_local_url']!r} must be an origin like http://host:port")

    v["initial_user"] = v.get("initial_user", "").strip()
    if not USER_RE.match(v["initial_user"]):
        raise ManifestError(f"initial_user {v['initial_user']!r}: letters, digits and . _ @ - only")

    v["telegram_user_ids"] = ",".join(p.strip() for p in v.get("telegram_user_ids", "").split(",") if p.strip())
    if not TG_IDS_RE.match(v["telegram_user_ids"]):
        raise ManifestError(f"telegram_user_ids {v['telegram_user_ids']!r}: numeric Telegram user ids separated by commas")
    keep = [p.strip() for p in v.get("keep", "").split(",") if p.strip()]
    for path in keep:
        if path.startswith("/") or ".." in path.split("/"):
            raise ManifestError(f"keep entry {path!r} must be a relative path inside the project")
    v["keep"] = ",".join(keep)

    v["KC_HOSTNAME"] = v["public_url"] + "/auth"
    for key in ("agent_version", "coddy_version", "verified_at"):
        v.setdefault(key, "")
    return v


def render_vars(values: dict[str, str]) -> dict[str, str]:
    """Upper-case variable map for @@NAME@@ substitution in the templates."""
    return {key.upper(): value for key, value in derive(values).items()}


def write(path: str, lines: list[str]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def set_values(lines: list[str], updates: dict[str, str]) -> list[str]:
    out = list(lines)
    for key, value in updates.items():
        for index, line in enumerate(out):
            match = LINE_RE.match(line)
            if match and match.group(1) == key:
                out[index] = f"{key}: {value}".rstrip()
                break
        else:
            out.append(f"{key}: {value}".rstrip())
    return out


def skill_version() -> str:
    try:
        return read(SKILL_MANIFEST)[1].get("version", "")
    except ManifestError:
        return ""


def cmd_init(args) -> int:
    if os.path.exists(args.file) and not args.force:
        raise ManifestError(f"{args.file} exists; use --force to overwrite it, or `set` to change keys")
    given = {
        "agent_version": skill_version(),
        "public_host": args.public_host,
        "public_url": args.public_url or "",
        "edge_name": args.edge_name or "",
        "edge_ssh": args.edge_ssh,
        "edge_dir": args.edge_dir or "",
        "coddy_host_name": args.coddy_host_name or "",
        "coddy_backend": args.coddy_backend,
        "coddy_local_url": args.coddy_local_url or "",
        "initial_user": args.initial_user or "",
        "telegram_user_ids": args.telegram_user_ids or "",
        "keep": args.keep or "",
        "coddy_version": "",
        "verified_at": "",
    }
    resolved = derive(given)
    lines = [
        "# caddy-coddy site manifest: where this stack runs and what it was verified against.",
        "# Written by `/caddy-coddy plan` (manifest.py init); read by build, deploy and verify.",
        "# Flat `key: value` lines only, so shell and Python read it without a YAML library.",
    ]
    for key, comment, _ in FIELDS:
        lines.append(f"# {comment}")
        lines.append(f"{key}: {resolved.get(key, '')}".rstrip())
    write(args.file, lines)
    print(f"wrote {args.file}")
    return print_resolved(resolved)


def print_resolved(resolved: dict[str, str]) -> int:
    for key, _, _ in FIELDS:
        print(f"{key}: {resolved.get(key, '')}".rstrip())
    for key in DERIVED:
        print(f"{key}: {resolved[key]}")
    return 0


def cmd_check(args) -> int:
    _, values = read(args.file)
    print_resolved(derive(values))
    print("OK")
    return 0


def cmd_get(args) -> int:
    _, values = read(args.file)
    if args.key in values and values[args.key] != "":
        print(values[args.key])
        return 0
    if args.default is not None:
        print(args.default)
        return 0
    print(f"{args.file}: {args.key} is not set", file=sys.stderr)
    return 1


def cmd_set(args) -> int:
    if len(args.pairs) % 2:
        raise ManifestError("set needs KEY VALUE pairs")
    lines, values = read(args.file)
    updates = dict(zip(args.pairs[0::2], args.pairs[1::2]))
    for key in updates:
        if key not in KNOWN:
            raise ManifestError(f"unknown key {key}; known: {', '.join(k for k, _, _ in FIELDS)}")
    values.update(updates)
    derive(values)  # reject a value that would make the manifest invalid
    write(args.file, set_values(lines, updates))
    for key, value in updates.items():
        print(f"{key}: {value}")
    return 0


def cmd_vars(args) -> int:
    _, values = read(args.file)
    variables = render_vars(values)
    for key in sorted(variables):
        if args.shell:
            print(f"CC_{key}={shlex.quote(variables[key])}")
        else:
            print(f"{key}={variables[key]}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-f", "--file", default=DEFAULT_FILE, help=f"manifest path (default: ./{DEFAULT_FILE})")
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="write a new manifest")
    p_init.add_argument("--public-host", required=True)
    p_init.add_argument("--edge-ssh", required=True)
    p_init.add_argument("--coddy-backend", required=True)
    for option in ("--public-url", "--edge-dir", "--edge-name", "--coddy-host-name", "--coddy-local-url", "--initial-user", "--telegram-user-ids", "--keep"):
        p_init.add_argument(option)
    p_init.add_argument("--force", action="store_true")
    p_init.set_defaults(func=cmd_init)

    sub.add_parser("check", help="validate and print the resolved values").set_defaults(func=cmd_check)

    p_get = sub.add_parser("get", help="print one value")
    p_get.add_argument("key")
    p_get.add_argument("default", nargs="?")
    p_get.set_defaults(func=cmd_get)

    p_set = sub.add_parser("set", help="update or append keys")
    p_set.add_argument("pairs", nargs="+", metavar="KEY VALUE")
    p_set.set_defaults(func=cmd_set)

    p_vars = sub.add_parser("vars", help="print every variable for rendering")
    p_vars.add_argument("--shell", action="store_true", help="as CC_KEY='value' lines for eval in bash")
    p_vars.set_defaults(func=cmd_vars)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ManifestError as error:
        print(f"manifest: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
