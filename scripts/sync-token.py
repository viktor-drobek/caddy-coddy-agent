#!/usr/bin/env python3
"""
sync-token.py — Copy Coddy's httpserver.auth_token from ml to superset's .env
and restart Caddy.

Usage:
    python3 sync-token.py

Reads $HOME/.coddy/config.yaml on ml, extracts auth_token (resolves ${ENV} refs),
validates it against Coddy on localhost:18080, then copies to /opt/caddy-coddy/.env
on superset and restarts Caddy.
"""
import subprocess
import sys
import yaml
import os
import urllib.request

CODDY_HOME = os.path.expanduser("~/.coddy")
CODDY_CONFIG = os.path.join(CODDY_HOME, "config.yaml")
CODDY_LOCAL = "http://127.0.0.1:18080"
TARGET_HOST = os.environ.get("TARGET_HOST", "huron@192.168.135.10")
TARGET_DIR = os.environ.get("TARGET_DIR", "/opt/caddy-coddy")


def extract_token(path: str) -> str:
    with open(path) as f:
        cfg = yaml.safe_load(f)
    token = cfg.get("httpserver", {}).get("auth_token", "")
    if not token:
        print(f"No httpserver.auth_token in {path}", file=sys.stderr)
        sys.exit(1)
    if token.startswith("${") and token.endswith("}"):
        var = token[2:-1]
        token = os.environ.get(var)
        if not token:
            print(f"Token references ${{VAR}}: en_US", file=sys.stderr)
            sys.exit(1)
    return token


def validate_token(token: str) -> bool:
    req = urllib.request.Request(f"{CODDY_LOCAL}/coddy/sessions")
    req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status == 200
    except Exception:
        return False


def sync_to_superset(token: str):
    ssh_cmd = (
        f"set -euo pipefail; cd {TARGET_DIR}; "
        f"current=$(sed -n 's/CODDY_API_TOKEN=//p' .env | head -1); "
        f"if [ \"$current\" = \"{token}\" ]; then "
        f"  echo 'Token already up to date'; "
        f"else "
        f"  cp -p .env \".env.bak.$(date +%s)\"; "
        f"  if grep -q '^CODDY_API_TOKEN=' .env; then "
        f"    sed -i 's/CODDY_API_TOKEN=.*/CODDY_API_TOKEN={token}/' .env; "
        f"  else "
        f"    echo 'CODDY_API_TOKEN={token}' >> .env; "
        f"  fi; "
        f"  chmod 600 .env; "
        f"  sudo docker compose up -d --force-recreate caddy >/dev/null; "
        f"  echo 'Token updated and Caddy restarted'; "
        f"fi"
    )
    subprocess.run(["ssh", TARGET_HOST, ssh_cmd], check=True)


def main():
    if not os.path.exists(CODDY_CONFIG):
        print(f"Config not found: {CODDY_CONFIG}", file=sys.stderr)
        sys.exit(1)

    token = extract_token(CODDY_CONFIG)
    print(f"Token extracted from {CODDY_CONFIG}: ...{token[-8:]}")

    if not validate_token(token):
        print(f"Token rejected by Coddy at {CODDY_LOCAL}", file=sys.stderr)
        sys.exit(1)
    print(f"Token validated against {CODDY_LOCAL}")

    sync_to_superset(token)

if __name__ == "__main__":
    main()
