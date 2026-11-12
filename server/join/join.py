#!/usr/bin/env python3
"""Join endpoint: POST /join {"user","code","pubkey"} installs an SSH key for a team member.

Python 3 standard library only. Listens on 127.0.0.1 (Caddy proxies /join to it).
Runs as root in production because it writes ~user/.ssh/authorized_keys. Codes are never logged.

Env overrides (for testing): HACK_TEAM_FILE, HACK_CODES_FILE, HACK_HOME_BASE, HACK_JOIN_HOST,
HACK_JOIN_PORT, HACK_JOIN_NO_CHOWN=1 (skip chown when not root).
"""
import hmac
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
TEAM_FILE = os.environ.get("HACK_TEAM_FILE", os.path.join(HERE, "..", "team.txt"))
CODES_FILE = os.environ.get("HACK_CODES_FILE", "/etc/hack/codes")
HOME_BASE = os.environ.get("HACK_HOME_BASE", "/home")
HOST = os.environ.get("HACK_JOIN_HOST", "127.0.0.1")
PORT = int(os.environ.get("HACK_JOIN_PORT", "8792"))
NO_CHOWN = os.environ.get("HACK_JOIN_NO_CHOWN") == "1"

MAX_BODY = 8 * 1024
MAX_KEYS = 10
MAX_FAILS = 10
FAIL_WINDOW = 600

KEY_RE = re.compile(
    r"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)"
    r"|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)"
    r" ([A-Za-z0-9+/]+={0,2})(?: ([\x21-\x7e ]{0,100}))?$"
)
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")

HELP = (
    "hackathon-vps join endpoint.\n"
    'POST /join with JSON {"user": "...", "code": "xxxx-xxxx-xxxx", "pubkey": "ssh-ed25519 AAAA..."}\n'
    "Normally you do not call this by hand: run connect.sh / connect.ps1 from the repo.\n"
)

fails = {}  # ip -> [timestamps]
lock = threading.Lock()


def team_users():
    users = set()
    try:
        with open(TEAM_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                name = line.split(None, 1)[0]
                if NAME_RE.match(name):
                    users.add(name)
    except OSError:
        pass
    return users


def code_for(user):
    try:
        with open(CODES_FILE, encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and parts[0] == user:
                    return parts[1]
    except OSError:
        pass
    return None


def too_many_fails(ip):
    now = time.time()
    with lock:
        recent = [t for t in fails.get(ip, []) if now - t < FAIL_WINDOW]
        fails[ip] = recent
        return len(recent) >= MAX_FAILS


def record_fail(ip):
    with lock:
        fails.setdefault(ip, []).append(time.time())


def valid_pubkey(pubkey):
    """Return the one-line public key if it is valid, else None."""
    if not isinstance(pubkey, str) or len(pubkey) > 2000:
        return None
    line = pubkey.strip()
    if not KEY_RE.match(line):
        return None
    with tempfile.NamedTemporaryFile("w", suffix=".pub", delete=False) as tmp:
        tmp.write(line + "\n")
        path = tmp.name
    try:
        r = subprocess.run(["ssh-keygen", "-l", "-f", path], capture_output=True, timeout=10, check=False)
        if r.returncode != 0:
            return None
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return line


def add_key(user, line):
    """Append the key to ~user/.ssh/authorized_keys. Returns (added, error)."""
    blob = line.split()[1]
    ssh_dir = os.path.join(HOME_BASE, user, ".ssh")
    ak = os.path.join(ssh_dir, "authorized_keys")
    uid = gid = None
    if not NO_CHOWN:
        import pwd

        pw = pwd.getpwnam(user)
        uid, gid = pw.pw_uid, pw.pw_gid
    with lock:
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        existing = []
        if os.path.exists(ak):
            with open(ak, encoding="utf-8", errors="replace") as f:
                existing = [ln.rstrip("\r\n") for ln in f if ln.strip()]
        for ln in existing:
            parts = ln.split()
            if len(parts) >= 2 and parts[1] == blob:
                return False, None
        if sum(1 for ln in existing if not ln.lstrip().startswith("#")) >= MAX_KEYS:
            return False, "too many keys for this user"
        with open(ak, "w", encoding="utf-8", newline="\n") as f:
            f.write("".join(ln + "\n" for ln in existing) + line + "\n")
        if not NO_CHOWN:
            os.chown(ssh_dir, uid, gid)
            os.chown(ak, uid, gid)
        os.chmod(ssh_dir, 0o700)
        os.chmod(ak, 0o600)
    return True, None


class Handler(BaseHTTPRequestHandler):
    server_version = "hack-join"
    protocol_version = "HTTP/1.0"

    def client_ip(self):
        first = self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
        return first or self.client_address[0]

    def send(self, status, body, ctype="application/json"):
        text = json.dumps(body) + "\n" if ctype == "application/json" else body
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def note(self, ip, user, outcome):
        print(f"join ip={ip} user={user!r} result={outcome}", flush=True)

    def is_join(self):
        return self.path.split("?")[0].rstrip("/") == "/join"

    def do_GET(self):
        if self.is_join():
            self.send(200, HELP, "text/plain")
        else:
            self.send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        ip = self.client_ip()
        if not self.is_join():
            return self.send(404, {"ok": False, "error": "not found"})
        if too_many_fails(ip):
            self.note(ip, "-", "rate-limited")
            return self.send(429, {"ok": False, "error": "too many failed attempts, wait 10 minutes"})
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            length = -1
        if length < 0 or length > MAX_BODY:
            record_fail(ip)
            self.note(ip, "-", "bad-length")
            return self.send(400, {"ok": False, "error": "bad or too large body"})
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
            user, code, pubkey = body["user"], body["code"], body["pubkey"]
            if not all(isinstance(x, str) for x in (user, code, pubkey)):
                raise ValueError
        except (ValueError, KeyError, TypeError, UnicodeDecodeError):
            record_fail(ip)
            self.note(ip, "-", "bad-json")
            return self.send(400, {"ok": False, "error": "expected JSON with user, code, pubkey"})

        user = user.strip().lower()
        expected = code_for(user) if user in team_users() else None
        ok = hmac.compare_digest(code.strip().lower().encode(), (expected or "x" * 14).encode())
        if expected is None or not ok:
            record_fail(ip)
            self.note(ip, user[:32], "forbidden")
            return self.send(403, {"ok": False, "error": "unknown user or wrong code"})

        line = valid_pubkey(pubkey)
        if line is None:
            record_fail(ip)
            self.note(ip, user, "bad-key")
            return self.send(400, {"ok": False, "error": "invalid public key"})
        try:
            added, err = add_key(user, line)
        except Exception as exc:  # keep serving, tell the caller
            self.note(ip, user, "error " + type(exc).__name__)
            return self.send(500, {"ok": False, "error": "could not install key"})
        if err:
            self.note(ip, user, "key-limit")
            return self.send(400, {"ok": False, "error": err})
        self.note(ip, user, "added" if added else "already-present")
        return self.send(200, {"ok": True, "user": user, "added": added})

    def log_message(self, fmt, *args):
        pass


def main():
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print(f"hack-join listening on {HOST}:{PORT}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
