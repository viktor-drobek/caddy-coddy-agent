#!/usr/bin/env python3
"""Local regression checks; no SSH, Docker daemon or live site is used.

Run: python3 tests/regression.py
Set CADDY_BIN to also exercise the rendered proxy with local HTTP stubs.
"""
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SiteFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="caddy-coddy-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.site = self.base / "site"
        self.site.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        self.run_script("python3", ROOT / "scripts/manifest.py", "-f",
                        self.site / "caddy-coddy.yml", "init", "--public-host",
                        "review.example.com", "--edge-ssh", "unused-test-host",
                        "--coddy-backend", "127.0.0.1:18080", check=True)
        self.run_script("python3", ROOT / "scripts/render.py", self.site, check=True)

    def run_script(self, *args, check=False):
        return subprocess.run([str(a) for a in args], env=self.env, cwd=self.site,
                              capture_output=True, text=True, timeout=30, check=check)

    def mock(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)
        return path


class ScriptTest(SiteFixture):
    def smoke(self, output, status=0, staging_status=0):
        self.mock("scp", f"exit {staging_status}")
        self.mock("ssh", '''case "$*" in
  *smoke-remote.sh*) printf '%s\\n' "$SMOKE_OUTPUT"; exit "$SMOKE_STATUS" ;;
  *) exit 0 ;;
esac''')
        self.env.update(SMOKE_OUTPUT=output, SMOKE_STATUS=str(status))
        before = (self.site / "caddy-coddy.yml").read_bytes()
        result = self.run_script("bash", self.site / "tests/smoke.sh", "--no-cli", "--record")
        return result, before, (self.site / "caddy-coddy.yml").read_bytes()

    def test_smoke_rejects_transport_failure(self):
        result, before, after = self.smoke("PASS partial\nCODDY_VERSION 1.2.3\nSMOKE_COMPLETE", 255)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(before, after)

    def test_smoke_rejects_incomplete_output(self):
        result, before, after = self.smoke("PASS partial\nCODDY_VERSION 1.2.3")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(before, after)

    def test_smoke_rejects_failed_check(self):
        result, before, after = self.smoke("PASS first\nFAIL second\nCODDY_VERSION 1.2.3\nSMOKE_COMPLETE")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(before, after)

    def test_smoke_rejects_staging_failure(self):
        result, before, after = self.smoke("PASS old run\nCODDY_VERSION 1.2.3\nSMOKE_COMPLETE", staging_status=1)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(before, after)

    def test_smoke_records_completed_run(self):
        result, _, after = self.smoke("PASS all checks\nCODDY_VERSION 1.2.3\nSMOKE_COMPLETE")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(b"coddy_version: 1.2.3", after)

    def test_remote_smoke_exits_nonzero_when_checks_fail(self):
        (self.site / ".env").write_text(
            "KC_HOSTNAME=https://review.example.com/auth\nKC_ADMIN_USER=test\n"
            "KC_ADMIN_PASSWORD=test\nCODDY_SERVICE_CLIENT_SECRET=test\n")
        self.mock("curl", "exit 0")
        self.mock("sudo", "exit 0")
        self.env.update(TARGET_DIR=str(self.site), WITH_CLI="0")
        result = self.run_script("bash", self.site / "tests/smoke-remote.sh")
        self.assertIn("FAIL ", result.stdout)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SMOKE_COMPLETE", result.stdout)

    def test_validation_requires_docker_or_edge(self):
        self.mock("docker", "exit 127")
        self.mock("ssh", "exit 255")
        result = self.run_script("bash", ROOT / "scripts/validate.sh", self.site)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_validation_rejects_failed_remote_staging(self):
        self.mock("docker", "exit 127")
        self.mock("ssh", "exit 0")
        self.mock("rsync", "exit 1")
        result = self.run_script("bash", ROOT / "scripts/validate.sh", self.site)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_managed_service_cannot_be_rotated_independently(self):
        marker = self.base / "ssh-called"
        self.mock("ssh", f"touch '{marker}'; exit 0")
        self.env["CLIENT_SECRET"] = "test-only-secret"
        result = self.run_script("bash", self.site / "add-service.sh", "--rotate", "coddy-service")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(marker.exists())
        self.assertIn("CODDY_SERVICE_CLIENT_SECRET", result.stderr)

    def test_custom_service_rotation_remains_available(self):
        self.mock("ssh", "cat >/dev/null; exit 0")
        self.env["CLIENT_SECRET"] = "test-only-secret"
        result = self.run_script("bash", self.site / "add-service.sh", "--rotate", "reporting-bot")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_imported_confidential_clients_are_disabled_without_secrets(self):
        realm = json.loads((self.site / "keycloak/import/realm-coddy.json").read_text())
        for client in realm["clients"]:
            if not client["publicClient"]:
                with self.subTest(client=client["clientId"]):
                    self.assertFalse(client["enabled"])
                    self.assertNotIn("secret", client)

    def deploy_trace(self, changes):
        edge = self.base / "edge"
        edge.mkdir()
        (edge / ".env").touch()
        (edge / "keycloak").mkdir()
        (edge / "keycloak/bootstrap.sh").write_text("# stub bootstrap\n")
        trace = self.base / "docker-trace"
        self.env.update(TARGET_DIR=str(edge), REVIEW_TRACE=str(trace), RSYNC_CHANGES=changes)
        self.mock("rsync", "printf '%s\\n' \"$RSYNC_CHANGES\"")
        self.mock("ssh", 'shift; exec bash -c "$*"')
        self.mock("sudo", '''printf '%s\\n' "$*" >> "$REVIEW_TRACE"
if [[ "$*" == *"docker inspect"* ]]; then echo healthy; fi
exit 0''')
        result = self.run_script("bash", self.site / "deploy.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return trace.read_text()

    def test_caddyfile_update_recreates_single_file_mount(self):
        trace = self.deploy_trace(">f.st...... Caddyfile")
        self.assertRegex(trace, r"compose up .*--force-recreate.* caddy")

    def test_unchanged_deploy_does_not_recreate_caddy(self):
        self.assertNotIn("--force-recreate", self.deploy_trace(""))

    def test_bootstrap_installs_secret_and_enables_client_together(self):
        trace = self.base / "kcadm-trace"
        self.env.update(REVIEW_TRACE=str(trace), KC_BOOTSTRAP_ADMIN_USERNAME="admin",
                        KC_BOOTSTRAP_ADMIN_PASSWORD="test-admin", CODDY_WEB_CLIENT_SECRET="test-web",
                        CODDY_SERVICE_CLIENT_SECRET="test-service", KC_INITIAL_USER="")
        kcadm = self.mock("kcadm", '''printf '%s\\n' "$*" >> "$REVIEW_TRACE"
case "$*" in
  'get clients '*) echo test-client-id ;;
  'get authentication/required-actions '*) printf 'UPDATE_PASSWORD\\nUPDATE_PROFILE\\nCONFIGURE_TOTP\\nVERIFY_EMAIL\\n' ;;
esac''')
        # Substitute only the external tool path; execute the complete bootstrap.
        bootstrap = self.base / "bootstrap.sh"
        bootstrap.write_text((self.site / "keycloak/bootstrap.sh").read_text().replace(
            "/opt/keycloak/bin/kcadm.sh", str(kcadm)))
        result = self.run_script("bash", bootstrap)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for secret in ("test-web", "test-service"):
            updates = [line for line in trace.read_text().splitlines() if f"secret={secret}" in line]
            self.assertEqual(len(updates), 1)
            self.assertIn("enabled=true", updates[0])


@unittest.skipUnless(os.environ.get("CADDY_BIN"), "set CADDY_BIN for real proxy checks")
class ProxyTest(SiteFixture):
    def setUp(self):
        super().setUp()
        self.requests = []
        requests = self.requests

        class Stub(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                requests.append((self.path, self.command, dict(self.headers)))
                if self.path == "/tg/auth/verify":
                    good = "_coddy_tg=valid" in self.headers.get("Cookie", "")
                    self.send_response(202 if good else 401)
                    if good:
                        self.send_header("X-Auth-Request-User", "tg:42")
                        self.send_header("X-Auth-Request-Preferred-Username", "tguser")
                    self.end_headers()
                elif self.path == "/oauth2/auth":
                    good = self.headers.get("Cookie") == "session=valid" or self.headers.get("Authorization") == "Bearer valid"
                    self.send_response(202 if good else 401)
                    self.send_header("Set-Cookie", "session=refreshed; Path=/" if good else "session=; Max-Age=0; Path=/")
                    if good:
                        self.send_header("Set-Cookie", "session_1=second-part; Path=/")
                        self.send_header("X-Auth-Request-Preferred-Username", "alice")
                    self.end_headers()
                else:
                    size = int(self.headers.get("Content-Length", "0"))
                    body = self.rfile.read(size).decode()
                    self.send_response(200)
                    self.send_header("Set-Cookie", "app=own-cookie; Path=/")
                    self.end_headers()
                    self.wfile.write(json.dumps({"method": self.command, "body": body,
                                                "headers": dict(self.headers)}).encode())

            do_POST = do_GET

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        config = self.site / "Caddyfile"
        config.write_text("{\n\tadmin off\n\tauto_https off\n}\n" + config.read_text().replace(
            "https://review.example.com", f"http://127.0.0.1:{self.port}"))
        self.env.update(CODDY_BACKEND=f"127.0.0.1:{server.server_port}",
                        KEYCLOAK_BACKEND=f"127.0.0.1:{server.server_port}",
                        OAUTH2_PROXY_BACKEND=f"127.0.0.1:{server.server_port}", TG_AUTH_BACKEND=f"127.0.0.1:{server.server_port}",
                        CODDY_API_TOKEN="test-coddy-token",
                        XDG_CONFIG_HOME=str(self.base), XDG_DATA_HOME=str(self.base))
        log = (self.base / "caddy.log").open("w+")
        self.addCleanup(log.close)
        self.caddy = subprocess.Popen([os.environ["CADDY_BIN"], "run", "--config", str(config),
                                       "--adapter", "caddyfile"], env=self.env, stdout=log, stderr=log)
        self.addCleanup(self.stop_caddy)
        for _ in range(100):
            if self.caddy.poll() is not None:
                log.seek(0)
                self.fail(log.read())
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.05)
        self.fail("Caddy did not start")

    def stop_caddy(self):
        self.caddy.terminate()
        self.caddy.wait(timeout=5)

    def request(self, path, headers=None, method="GET", body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.getheaders(), response.read()
        finally:
            connection.close()

    def test_authentication_and_split_cookie_refresh(self):
        for path in ("/", "/coddy/sessions", "/auth/admin/master/console/"):
            with self.subTest(path=path):
                status, headers, _ = self.request(path, {"Cookie": "session=valid", "Accept": "text/html"})
                self.assertEqual(status, 200)
                cookies = [value for key, value in headers if key.lower() == "set-cookie"]
                self.assertEqual(cookies, ["session=refreshed; Path=/", "session_1=second-part; Path=/",
                                           "app=own-cookie; Path=/"])

    def test_anonymous_page_api_and_bad_bearer(self):
        for path, headers, expected in (
                ("/", {"Accept": "text/html"}, 302),
                ("/coddy/sessions", {}, 401),
                ("/coddy/events", {"Accept": "text/event-stream"}, 401),
                ("/", {"Accept": "text/html", "Authorization": "Bearer junk"}, 401),
                ("/auth/admin/master/console/", {"Accept": "text/html"}, 302)):
            with self.subTest(path=path, headers=headers):
                status, response_headers, _ = self.request(path, headers)
                self.assertEqual(status, expected)
                self.assertIn(("Set-Cookie", "session=; Max-Age=0; Path=/"), response_headers)

    def test_post_body_and_token_isolation(self):
        status, _, body = self.request("/coddy/sessions", {"Authorization": "Bearer valid"}, "POST", "payload")
        self.assertEqual(status, 200)
        upstream = json.loads(body)
        self.assertEqual(upstream["method"], "POST")
        self.assertEqual(upstream["body"], "payload")
        self.assertEqual(upstream["headers"]["Authorization"], "Bearer test-coddy-token")
        self.assertEqual(upstream["headers"]["X-Forwarded-User"], "alice")
        self.assertNotIn("Set-Cookie", upstream["headers"])
        self.assertEqual(self.requests[-2][1], "GET")
        self.assertEqual(self.requests[-2][2]["X-Forwarded-Method"], "POST")
        self.assertEqual(self.requests[-2][2]["X-Forwarded-Uri"], "/coddy/sessions")

    def test_missing_identity_claim_cannot_be_spoofed(self):
        status, _, body = self.request("/coddy/sessions", {
            "Authorization": "Bearer valid", "X-Auth-Request-User": "mallory",
            "X-Auth-Request-Preferred-Username": "mallory", "X-Auth-Request-Email": "mallory@example.com"})
        self.assertEqual(status, 200)
        upstream = json.loads(body)["headers"]
        self.assertEqual(upstream["X-Forwarded-User"], "alice")
        self.assertNotIn("X-Auth-Request-User", upstream)
        self.assertNotIn("X-Auth-Request-Email", upstream)

    def test_admin_checks_cookie_and_preserves_master_bearer(self):
        status, _, body = self.request("/auth/admin/realms", {
            "Cookie": "session=valid", "Authorization": "Bearer master-token"})
        self.assertEqual(status, 200)
        self.assertNotIn("Authorization", self.requests[-2][2])
        self.assertEqual(json.loads(body)["headers"]["Authorization"], "Bearer master-token")

    def test_telegram_cookie_session(self):
        status, _, body = self.request("/coddy/sessions", {"Cookie": "_coddy_tg=valid", "Authorization": "Bearer mallory",
                                                            "X-Auth-Request-User": "mallory"})
        self.assertEqual(status, 200)
        upstream = json.loads(body)["headers"]
        self.assertEqual(upstream["Authorization"], "Bearer test-coddy-token")
        self.assertEqual(upstream["X-Forwarded-User"], "tguser")
        self.assertEqual(upstream["X-Auth-Request-User"], "tg:42")
        self.assertNotIn("X-Auth-Request-Email", upstream)

    def test_telegram_cookie_precedes_and_fails_closed(self):
        status, headers, _ = self.request("/", {"Cookie": "_coddy_tg=stale; session=valid", "Accept": "text/html"})
        self.assertEqual(status, 302)
        self.assertTrue(dict(headers)["Location"].startswith("/tg/?rd="))
        status, _, _ = self.request("/coddy/sessions", {"Cookie": "_coddy_tg=stale"})
        self.assertEqual(status, 401)

    def test_telegram_endpoints(self):
        self.assertEqual(self.request("/tg/auth/verify", {"Cookie": "_coddy_tg=valid"})[0], 404)
        status, _, body = self.request("/tg/")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["method"], "GET")


class TgAuthTest(unittest.TestCase):
    """tg-auth (references/templates/tg-auth/server.py) on a loopback port with real signed initData."""
    TOKEN = "123456:TEST-BOT-TOKEN"

    def start(self, **env_overrides):
        env = dict(os.environ, TG_BOT_TOKEN=self.TOKEN, TG_ALLOWED_USER_IDS="42,7", TG_AUTH_COOKIE_SECRET="s3cret",
                   TG_LISTEN="127.0.0.1:0")
        env.update(env_overrides)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env["TG_LISTEN"] = f"127.0.0.1:{port}"
        log = tempfile.TemporaryFile(mode="w+")
        self.addCleanup(log.close)
        proc = subprocess.Popen(["python3", str(ROOT / "references/templates/tg-auth/server.py")], env=env,
                                stdout=log, stderr=log)
        self.addCleanup(proc.wait, timeout=5)
        self.addCleanup(proc.terminate)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    return port
            except OSError:
                time.sleep(0.05)
        log.seek(0)
        self.fail(log.read())

    def init_data(self, uid, skew=0, broken=False):
        import hashlib, hmac, urllib.parse
        fields = {"user": json.dumps({"id": uid, "first_name": "T", "username": "tgtester"}, separators=(",", ":")),
                  "auth_date": str(int(time.time()) - skew), "query_id": "q"}
        check = "\n".join(f"{k}={v}" for k, v in sorted(fields.items()))
        secret = hmac.new(b"WebAppData", self.TOKEN.encode(), hashlib.sha256).digest()
        fields["hash"] = "0" * 64 if broken else hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
        return urllib.parse.urlencode(fields)

    def call(self, port, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_login_verify_and_refusals(self):
        port = self.start()
        self.assertEqual(self.call(port, "GET", "/tg/healthz")[0], 200)
        self.assertIn(b"telegram-web-app.js", self.call(port, "GET", "/tg/")[2])
        status, headers, body = self.call(port, "POST", "/tg/auth/login", self.init_data(42))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["username"], "tgtester")
        cookie = headers["Set-Cookie"].split(";")[0]
        self.assertTrue(cookie.startswith("_coddy_tg="))
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        status, headers, _ = self.call(port, "GET", "/tg/auth/verify", headers={"Cookie": cookie})
        self.assertEqual(status, 202)
        self.assertEqual(headers["X-Auth-Request-User"], "tg:42")
        self.assertEqual(headers["X-Auth-Request-Preferred-Username"], "tgtester")
        self.assertEqual(self.call(port, "GET", "/tg/auth/verify", headers={"Cookie": cookie + "x"})[0], 401)
        self.assertEqual(self.call(port, "GET", "/tg/auth/verify")[0], 401)
        self.assertEqual(self.call(port, "POST", "/tg/auth/login", self.init_data(99))[0], 403)
        self.assertEqual(self.call(port, "POST", "/tg/auth/login", self.init_data(42, broken=True))[0], 401)
        self.assertEqual(self.call(port, "POST", "/tg/auth/login", self.init_data(42, skew=7200))[0], 401)
        status, headers, _ = self.call(port, "GET", "/tg/logout")
        self.assertEqual(status, 302)
        self.assertIn("Max-Age=0", headers["Set-Cookie"])

    def test_disabled_without_bot_token(self):
        port = self.start(TG_BOT_TOKEN="")
        self.assertEqual(self.call(port, "GET", "/tg/")[0], 404)
        self.assertEqual(self.call(port, "POST", "/tg/auth/login", self.init_data(42))[0], 503)
        self.assertEqual(self.call(port, "GET", "/tg/auth/verify", headers={"Cookie": "_coddy_tg=x.y"})[0], 401)


if __name__ == "__main__":
    unittest.main(verbosity=2)
