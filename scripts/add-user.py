#!/usr/bin/env python3
"""
add-user.py — Create a user in Keycloak realm "coddy" with a temporary password.

Usage:
    python3 add-user.py <username> <email>

Reads environment variables from the caddy-coddy .env on superset.
You must be able to SSH to superset as huron.
"""
import subprocess
import sys
import os


def main():
    if len(sys.argv) < 3:
        print("usage: {} <username> <email>".format(sys.argv[0]), file=sys.stderr)
        sys.exit(2)

    username = sys.argv[1]
    email = sys.argv[2]
    password = "temporary-password-change-at-first-login"

    env_vars = [
        "KC_ADMIN_USER",
        "KC_ADMIN_PASSWORD",
        "KC_INITIAL_USER_PASSWORD",
        "CODDY_WEB_CLIENT_SECRET",
        "CODDY_SERVICE_CLIENT_SECRET",
    ]

    # Pull vars from superset .env (export-friendly)
    env_block = subprocess.check_output(
        ["ssh", "huron@192.168.135.10",
         "cd /opt/caddy-coddy && sed -n 's/=/=/' .env"],
        text=True
    )
    env = {}
    for line in env_block.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            env[k] = v

    for v in env_vars:
        if v not in env or not env[v]:
            print(f"Missing env var {v} in /opt/caddy-coddy/.env", file=sys.stderr)
            sys.exit(1)

    admin = env.get("KC_ADMIN_USER", "admin")
    admin_pw = env["KC_ADMIN_PASSWORD"]
    user_pw = env.get("KC_INITIAL_USER_PASSWORD", password)

    ssh_cmd = (
        f"set -euo pipefail; cd /opt/caddy-coddy; " + \
        f"sudo docker compose exec -T keycloak bash -c \"" + \
        f"/opt/keycloak/bin/kcadm.sh config credentials \\"\\"\\"" + \
        f" --server http://127.0.0.1:8080/auth --realm master --user {admin} --password {admin_pw} >/dev/null && " + \
        f"/opt/keycloak/bin/kcadm.sh create users -r coddy -s username={username} -s email={email} -s enabled=true && " + \
        f"user_id=\\\$(/opt/keycloak/bin/kcadm.sh get users -r coddy -q username={username} -q exact=true --fields id | sed -n 's/.*\"id\" : \"\\(.*\\)\".*/\\1/p') && " + \
        f"/opt/keycloak/bin/kcadm.sh update users/\\\$user_id/reset-password -r coddy -s type=password -s value='{user_pw}' -s temporary=true\""
    )

    print(f"Creating user {username} in realm coddy...")
    subprocess.run(["ssh", "huron@192.168.135.10", ssh_cmd], check=True)
    print(f"User {username} created with temporary password.")

if __name__ == "__main__":
    main()
