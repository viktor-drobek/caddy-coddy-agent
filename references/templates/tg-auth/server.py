#!/usr/bin/env python3
"""tg-auth: Telegram Mini App sign-in for the caddy-coddy edge.

A Telegram Mini App receives `initData`, a query string signed by Telegram with
the bot's token. This service verifies that signature, checks the Telegram user
id against an allow list, and issues its own signed session cookie. Caddy then
asks `/tg/auth/verify` on every request that carries the cookie, the same way it
asks oauth2-proxy for Keycloak sessions, and proxies to Coddy with Coddy's own
API token. Standard library only; runs in the plain python image.

Environment (from the edge's .env through docker-compose.yml):
  TG_BOT_TOKEN            token of the bot the Mini App belongs to; empty disables sign-in
  TG_ALLOWED_USER_IDS     comma-separated Telegram user ids that may sign in; empty admits nobody
  TG_AUTH_COOKIE_SECRET   random secret that signs the session cookie
  TG_SESSION_HOURS        cookie lifetime (default 168)
  TG_INITDATA_MAX_AGE     seconds an initData stays acceptable after its auth_date (default 3600)
  TG_LISTEN               host:port (default 0.0.0.0:4181)

Routes (all under /tg/, which Caddy proxies here):
  GET  /tg/               landing page: reads initData inside Telegram, posts it to /tg/auth/login
  POST /tg/auth/login     body = initData -> 200 + Set-Cookie, 401 bad or stale signature,
                          403 user not allowed, 503 sign-in disabled
  GET  /tg/auth/verify    Caddy's auth check: 202 + X-Auth-Request-* for a valid cookie, else 401
                          (Caddy answers 404 to the internet for this path)
  GET  /tg/logout         clears the cookie, redirects to /tg/
  GET  /tg/healthz        200
"""
import base64
import hashlib
import hmac
import html
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, parse_qsl, urlsplit

BOT_TOKEN = os.environ.get("TG_BOT_TOKEN", "").strip()
ALLOWED = {u.strip() for u in os.environ.get("TG_ALLOWED_USER_IDS", "").split(",") if u.strip()}
COOKIE_SECRET = os.environ.get("TG_AUTH_COOKIE_SECRET", "").encode()
SESSION_SECONDS = int(float(os.environ.get("TG_SESSION_HOURS", "168")) * 3600)
INITDATA_MAX_AGE = int(os.environ.get("TG_INITDATA_MAX_AGE", "3600"))
LISTEN = os.environ.get("TG_LISTEN", "0.0.0.0:4181")
COOKIE = "_coddy_tg"
ENABLED = bool(BOT_TOKEN) and bool(COOKIE_SECRET)

LANDING = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Coddy in Telegram</title>
<script src="https://telegram.org/js/telegram-web-app.js"></script>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0f1115;color:#e6e6e6;font:16px/1.5 system-ui,sans-serif}
main{max-width:22rem;padding:2rem;text-align:center}h1{font-size:1.25rem;margin:0 0 .5rem}p{margin:.5rem 0;color:#b8b8b8}a{color:#8ab4f8}
</style></head><body><main>
<h1>Coddy</h1><p id="msg">Signing in with Telegram…</p><p id="alt" hidden><a href="/">Sign in with a username and password instead</a></p>
<script>
(function(){
  var msg=document.getElementById('msg'),alt=document.getElementById('alt');
  var tg=window.Telegram&&window.Telegram.WebApp,data=tg&&tg.initData;
  var q=new URLSearchParams(location.search),rd=q.get('rd')||'/';
  if(!/^\\/(?!\\/)/.test(rd))rd='/';
  function fail(t){msg.textContent=t;alt.hidden=false;}
  if(!data){fail('Open this page from the Telegram Mini App to sign in with your Telegram account.');return;}
  try{tg.ready();tg.expand();}catch(e){}
  fetch('/tg/auth/login',{method:'POST',headers:{'Content-Type':'text/plain'},body:data,credentials:'same-origin'})
    .then(function(r){if(r.ok){location.replace(rd);return;}
      if(r.status===403){fail('Your Telegram account is not on the allow list of this Coddy server.');}
      else if(r.status===503){fail('Telegram sign-in is not enabled on this server.');}
      else{fail('Telegram sign-in failed (HTTP '+r.status+'). Reopen the Mini App and try again.');}})
    .catch(function(){fail('Telegram sign-in failed: network error.');});
})();
</script></main></body></html>
"""


def b64e(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def b64d(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def verify_init_data(init_data: str):
    """Return (status, user dict). status: 200 ok, 401 bad/stale signature, 403 not allowed."""
    pairs = parse_qsl(init_data, keep_blank_values=True)
    data = dict(pairs)
    given = data.pop("hash", None)
    if not given or "auth_date" not in data or "user" not in data:
        return 401, None
    check = "\n".join(f"{k}={v}" for k, v in sorted(data.items()))
    secret = hmac.new(b"WebAppData", BOT_TOKEN.encode(), hashlib.sha256).digest()
    expected = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, given):
        return 401, None
    try:
        auth_date = int(data["auth_date"])
        user = json.loads(data["user"])
        uid = int(user["id"])
    except (ValueError, KeyError, TypeError):
        return 401, None
    if abs(time.time() - auth_date) > INITDATA_MAX_AGE:
        return 401, None
    if str(uid) not in ALLOWED:
        return 403, {"id": uid}
    return 200, {"id": uid, "username": user.get("username") or f"tg-{uid}"}


def make_cookie(user: dict) -> str:
    payload = b64e(json.dumps({"id": user["id"], "u": user["username"], "exp": int(time.time()) + SESSION_SECONDS},
                              separators=(",", ":")).encode())
    sig = hmac.new(COOKIE_SECRET, payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def read_cookie(value: str):
    """Return the session dict for a valid, unexpired cookie, else None."""
    if not value or "." not in value:
        return None
    payload, _, sig = value.rpartition(".")
    expected = hmac.new(COOKIE_SECRET, payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, sig):
        return None
    try:
        session = json.loads(b64d(payload))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(session, dict) or session.get("exp", 0) < time.time():
        return None
    return session


def cookie_header(value: str, max_age: int) -> str:
    return f"{COOKIE}={value}; Path=/; Max-Age={max_age}; Secure; HttpOnly; SameSite=Lax"


class Handler(BaseHTTPRequestHandler):
    server_version = "tg-auth"

    def log_message(self, fmt, *args):  # one line per request, no cookie values
        print(f'{self.address_string()} "{self.command} {self.path.split("?")[0]}" {args[1] if len(args) > 1 else ""}', flush=True)

    def cookie(self):
        jar = {}
        for part in self.headers.get("Cookie", "").split(";"):
            name, _, val = part.strip().partition("=")
            if name:
                jar[name] = val
        return jar.get(COOKIE, "")

    def reply(self, status, body=b"", content_type="text/plain; charset=utf-8", headers=()):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/tg/healthz":
            return self.reply(200, b"ok\n")
        if path in ("/tg", "/tg/"):
            if not ENABLED:
                return self.reply(404, b"Telegram sign-in is not enabled on this server.\n")
            return self.reply(200, LANDING.encode(), "text/html; charset=utf-8")
        if path == "/tg/auth/verify":
            session = read_cookie(self.cookie()) if ENABLED else None
            if not session or str(session.get("id")) not in ALLOWED:
                return self.reply(401, b"", headers=[("WWW-Authenticate", "Telegram")])
            return self.reply(202, b"", headers=[
                ("X-Auth-Request-User", f"tg:{session['id']}"),
                ("X-Auth-Request-Preferred-Username", str(session.get("u") or f"tg-{session['id']}")),
            ])
        if path == "/tg/logout":
            return self.reply(302, b"", headers=[("Location", "/tg/"), ("Set-Cookie", cookie_header("", 0))])
        return self.reply(404, b"not found\n")

    do_HEAD = do_GET

    def do_POST(self):
        path = urlsplit(self.path).path
        if path != "/tg/auth/login":
            return self.reply(404, b"not found\n")
        if not ENABLED:
            return self.reply(503, b"Telegram sign-in is not enabled on this server.\n")
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > 16384:
            return self.reply(413, b"initData too large\n")
        body = self.rfile.read(length).decode("utf-8", "replace")
        # Accept the raw initData, or a form/query wrapper with an initData field.
        init_data = body
        if "hash=" not in body:
            init_data = (parse_qs(body).get("initData") or [""])[0]
        status, user = verify_init_data(init_data)
        if status == 401:
            return self.reply(401, b"initData signature invalid or stale\n")
        if status == 403:
            return self.reply(403, f"Telegram user {user['id']} is not allowed\n".encode())
        payload = json.dumps({"ok": True, "user": user["id"], "username": user["username"]}).encode()
        return self.reply(200, payload, "application/json",
                          headers=[("Set-Cookie", cookie_header(make_cookie(user), SESSION_SECONDS))])


def main():
    host, _, port = LISTEN.rpartition(":")
    server = ThreadingHTTPServer((host or "0.0.0.0", int(port)), Handler)
    state = f"enabled, {len(ALLOWED)} allowed user(s)" if ENABLED else "disabled (TG_BOT_TOKEN or TG_AUTH_COOKIE_SECRET unset)"
    print(f"tg-auth listening on {LISTEN}: Telegram sign-in {state}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
