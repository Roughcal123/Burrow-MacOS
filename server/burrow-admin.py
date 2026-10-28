#!/usr/bin/env python3
"""Burrow server admin + device enrollment service.

  burrow-admin serve            run the enrollment service (localhost only; reached through wstunnel)
  burrow-admin code             print the enrollment code to bake into / paste into Burrow
  burrow-admin list             list enrolled devices
  burrow-admin revoke <x>       remove a device by public key, address (10.66.66.5) or name
  burrow-admin rotate           make a new enrollment token (already-enrolled devices keep working)
"""
import base64, hmac, json, os, re, secrets, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

IF = os.environ.get("BURROW_IF", "wg0")
CONF = os.environ.get("BURROW_CONF", f"/etc/wireguard/{IF}.conf")
STATE = os.environ.get("BURROW_STATE", "/var/lib/burrow/devices.json")
TOKEN_FILE = os.environ.get("BURROW_TOKEN_FILE", "/etc/burrow/enroll.token")
ENV_FILE = os.environ.get("BURROW_ENV_FILE", "/etc/wstunnel/wstunnel.env")
PORT = int(os.environ.get("BURROW_ENROLL_PORT", "51822"))
MAX_DEVICES = int(os.environ.get("BURROW_MAX_DEVICES", "250"))
KEY = re.compile(r"^[A-Za-z0-9+/]{43}=$")
LOCK, RECENT = threading.Lock(), []


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout.strip()


def token():
    return open(TOKEN_FILE).read().strip()


def load_state():
    try:
        return json.load(open(STATE))
    except Exception:
        return {}


def save_state(d):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=1)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE)


def conf_remove(pub):
    t = open(CONF).read()
    parts = re.split(r"(?=^\[Peer\]\s*$)", t, flags=re.M)
    keep = [p for p in parts if not (p.startswith("[Peer]") and
            re.search(r"^PublicKey\s*=\s*" + re.escape(pub) + r"\s*$", p, re.M))]
    open(CONF, "w").write("".join(keep))


def enroll(pub, name):
    with LOCK:
        st = load_state()
        if pub in st:  # same device again (reinstall): hand back the same address
            return st[pub]["addr"]
        if len(st) >= MAX_DEVICES:
            raise ValueError("device limit reached")
        now = time.time()
        RECENT[:] = [t for t in RECENT if now - t < 600]
        if len(RECENT) >= 30:
            raise ValueError("too many new devices at once, try again in a few minutes")
        base = re.search(r"^Address\s*=\s*(\d+\.\d+\.\d+)\.\d+/", open(CONF).read(), re.M).group(1)
        used = {v["addr"] for v in st.values()}
        used |= set(re.findall(re.escape(base) + r"\.\d+", sh("wg", "show", IF, "allowed-ips")))
        addr = next((f"{base}.{n}" for n in range(2, 255) if f"{base}.{n}" not in used), None)
        if not addr:
            raise ValueError("no free addresses left")
        sh("wg", "set", IF, "peer", pub, "allowed-ips", addr + "/32")
        with open(CONF, "a") as f:
            f.write(f"\n[Peer]\n# burrow:{name}\nPublicKey = {pub}\nAllowedIPs = {addr}/32\n")
        st[pub] = {"addr": addr, "name": name, "created": int(now)}
        save_state(st)
        RECENT.append(now)
        return addr


class H(BaseHTTPRequestHandler):
    timeout = 10

    def log_message(self, *a):
        pass

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_json(200 if self.path == "/health" else 404, {"ok": self.path == "/health"})

    def do_POST(self):
        if self.path != "/enroll":
            return self.send_json(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if not 0 < n <= 4096:
                raise ValueError
            d = json.loads(self.rfile.read(n))
        except Exception:
            return self.send_json(400, {"error": "bad request"})
        if not hmac.compare_digest(str(d.get("token", "")).encode(), token().encode()):
            time.sleep(1)
            return self.send_json(403, {"error": "bad token"})
        pub = str(d.get("pub", ""))
        if not KEY.match(pub):
            return self.send_json(400, {"error": "bad key"})
        name = re.sub(r"[^A-Za-z0-9._-]", "", str(d.get("name", "device")))[:40] or "device"
        try:
            addr = enroll(pub, name)
            self.send_json(200, {"addr": addr + "/32", "pub": sh("wg", "show", IF, "public-key")})
        except ValueError as e:
            self.send_json(429, {"error": str(e)})
        except Exception:
            self.send_json(500, {"error": "server error"})


def public_ip():
    for url in ("https://ifconfig.me", "https://api.ipify.org"):
        try:
            return sh("curl", "-4fsS", "--max-time", "10", url)
        except Exception:
            pass
    sys.exit("Could not find this server's public IP")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "serve":
        ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
    elif cmd == "code":
        prefix = open(ENV_FILE).read().split("=", 1)[1].strip()
        d = {"ip": public_ip(), "prefix": prefix, "token": token()}
        print("\nEnrollment code (every person who opens Burrow with it gets their own key):\n")
        print(base64.b64encode(json.dumps(d, separators=(",", ":")).encode()).decode(), "\n")
    elif cmd == "list":
        st = load_state()
        for pub, v in sorted(st.items(), key=lambda kv: kv[1]["created"]):
            print(f'{v["addr"]:<14} {v["name"]:<24} {time.strftime("%Y-%m-%d", time.localtime(v["created"]))}  {pub}')
        print(f"{len(st)} device(s)")
    elif cmd == "revoke" and len(sys.argv) > 2:
        x, st = sys.argv[2], load_state()
        hit = [p for p, v in st.items() if x in (p, v["addr"], v["name"])]
        if not hit:
            sys.exit("No such device (see: burrow-admin list)")
        for p in hit:
            subprocess.run(["wg", "set", IF, "peer", p, "remove"])
            conf_remove(p)
            print("Revoked", st.pop(p)["name"], p)
        save_state(st)
    elif cmd == "rotate":
        with open(TOKEN_FILE, "w") as f:
            f.write(secrets.token_hex(16) + "\n")
        os.chmod(TOKEN_FILE, 0o600)
        print("Token rotated. Already-enrolled devices keep working; new installs need the new code:")
        sys.argv[1] = "code"
        main()
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
