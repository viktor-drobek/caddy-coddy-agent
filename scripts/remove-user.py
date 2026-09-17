#!/usr/bin/env python3
"""
remove-user.py — Remove a user from Keycloak realm "coddy".

Usage:
    python3 remove-user.py <username>
"""
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: {} <username>".format(sys.argv[0]), file=sys.stderr)
        sys.exit(2)

    username = sys.argv[1]

    ssh_cmd = (
        f"set -euo pipefail; cd /opt/caddy-coddy; " + \
        f"sudo docker compose exec -T keycloak bash -c \"" + \
        f"user=\\\$(/opt/keycloak/bin/kcadm.sh get users -r coddy -q username={username} -q exact=true --fields id | sed -n 's/.*\"id\" : \"\\(.*\\)\".*/\\1/p') && " + \
        f"[ -n \\\"\\$user\\\" ] && /opt/keycloak/bin/kcadm.sh delete users/\\\$user -r coddy || echo 'User not found'\""
    )

    print(f"Removing user {username} from realm coddy...")
    subprocess.run(["ssh", "huron@192.168.135.10", ssh_cmd], check=True)
    print(f"User {username} removed.")

if __name__ == "__main__":
    main()
