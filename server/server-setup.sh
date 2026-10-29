#!/usr/bin/env bash
# Burrow server setup: one command on a fresh Ubuntu/Debian (or Fedora/Rocky/Alma) VPS.
#   curl -fsSL <raw url of this file> | sudo bash
#   or:  sudo bash server-setup.sh
# Installs WireGuard + wstunnel, enables NAT/forwarding, opens port 443, starts everything on boot,
# then prints a connection code to paste into Burrow. Safe to re-run (keeps existing keys and secret).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo bash server-setup.sh"; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

WG_IF=wg0; WG_PORT=51820; SUBNET=10.66.66; WS_PORT=443; ENROLL_PORT=51822; NGINX_LOCAL_PORT=8443
# Where wstunnel listens. Default: wss://0.0.0.0:443 (it owns port 443).
# Behind nginx/Caddy: run  WS_BIND=ws://127.0.0.1:PORT bash server-setup.sh  once; it is remembered for re-runs.
mkdir -p /etc/burrow
WS_BIND=${WS_BIND:-$(cat /etc/burrow/ws-bind 2>/dev/null || true)}
WS_BIND=${WS_BIND:-wss://0.0.0.0:$WS_PORT}

# ---- packages ----
say "Installing packages"
if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq wireguard wireguard-tools iptables curl ca-certificates openssl iproute2 python3 >/dev/null
elif command -v dnf >/dev/null; then
  dnf install -y -q wireguard-tools iptables curl ca-certificates openssl iproute python3 >/dev/null
else
  echo "Unsupported system: need apt (Ubuntu/Debian) or dnf (Fedora/RHEL)."; exit 1
fi
modprobe wireguard 2>/dev/null || true

# ---- if wstunnel will own port 443, nothing else may be using it ----
# nginx already on 443 (e.g. a website): put wstunnel behind it automatically instead of giving up.
BEHIND_NGINX=0
if [ "$WS_BIND" = "wss://0.0.0.0:$WS_PORT" ] && ss -ltnpH "sport = :$WS_PORT" 2>/dev/null | grep -q . \
   && ! ss -ltnpH "sport = :$WS_PORT" | grep -q wstunnel; then
  if ss -ltnpH "sport = :$WS_PORT" | grep -q nginx && [ -d /etc/nginx ]; then
    echo "nginx is using port $WS_PORT: wstunnel will run behind it on 127.0.0.1:$NGINX_LOCAL_PORT"
    WS_BIND=ws://127.0.0.1:$NGINX_LOCAL_PORT
  else
    echo "Port $WS_PORT is used by another program:"
    ss -ltnpH "sport = :$WS_PORT" | sed -E 's/^/  /'
    echo "Nothing was changed. If wstunnel should sit behind it, re-run with the local port your proxy forwards to:"
    echo "  WS_BIND=ws://127.0.0.1:PORT bash server-setup.sh"
    exit 1
  fi
fi
case "$WS_BIND" in ws://127.0.0.1:*) command -v nginx >/dev/null && [ -d /etc/nginx ] && BEHIND_NGINX=1;; esac
echo "$WS_BIND" > /etc/burrow/ws-bind

# ---- back up any existing config before changing anything ----
BK=/root/burrow-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK"; chmod 700 "$BK"
cp -a /etc/wireguard /etc/wstunnel /etc/systemd/system/wstunnel.service "$BK"/ 2>/dev/null || true
echo "Backed up existing config to $BK"

# ---- wstunnel ----
say "Installing wstunnel"
case "$(uname -m)" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "Unsupported CPU $(uname -m)"; exit 1;; esac
URL=$(curl -fsSL https://api.github.com/repos/erebe/wstunnel/releases/latest \
  | grep -oE "https://[^\"]+/wstunnel_[0-9.]+_linux_${A}\.tar\.gz" | head -1)
[ -n "$URL" ] || { echo "Could not find a wstunnel download"; exit 1; }
TMP=$(mktemp -d); curl -fsSL "$URL" | tar -xz -C "$TMP"
install -m 755 "$TMP/wstunnel" /usr/local/bin/wstunnel; rm -rf "$TMP"
/usr/local/bin/wstunnel --version

# ---- secret path prefix (acts as the password for the tunnel) ----
mkdir -p /etc/wstunnel
if [ -s /etc/wstunnel/wstunnel.env ]; then
  # An older setup may have used another variable name: keep its secret, but store it as PREFIX=...
  OLD=$(head -n1 /etc/wstunnel/wstunnel.env | cut -d= -f2- | tr -d '"'"'"' \r')
  [ -n "$OLD" ] && printf 'PREFIX=%s\n' "$OLD" > /etc/wstunnel/wstunnel.env
fi
if [ ! -s /etc/wstunnel/wstunnel.env ]; then
  printf 'PREFIX=%s\n' "$(openssl rand -hex 16)" > /etc/wstunnel/wstunnel.env
fi
chmod 600 /etc/wstunnel/wstunnel.env

# ---- enrollment token (lets the Burrow app register each device with its own key) ----
mkdir -p /etc/burrow /var/lib/burrow; chmod 700 /etc/burrow /var/lib/burrow
[ -s /etc/burrow/enroll.token ] || openssl rand -hex 16 > /etc/burrow/enroll.token
chmod 600 /etc/burrow/enroll.token

cat > /etc/systemd/system/wstunnel.service <<UNIT
[Unit]
Description=wstunnel server for Burrow
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/wstunnel/wstunnel.env
ExecStart=/usr/local/bin/wstunnel server --restrict-to 127.0.0.1:${WG_PORT} --restrict-to 127.0.0.1:${ENROLL_PORT} --restrict-http-upgrade-path-prefix \${PREFIX} ${WS_BIND}
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

# ---- WireGuard ----
say "Configuring WireGuard"
mkdir -p /etc/wireguard; umask 077
OUT=$(ip -4 route show default | awk '{print $5; exit}')
[ -n "$OUT" ] || { echo "No default network interface found"; exit 1; }
if [ ! -f /etc/wireguard/$WG_IF.conf ]; then
  cat > /etc/wireguard/$WG_IF.conf <<WG
[Interface]
Address = ${SUBNET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = $(wg genkey)
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -I FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s ${SUBNET}.0/24 -o ${OUT} -j MASQUERADE; iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s ${SUBNET}.0/24 -o ${OUT} -j MASQUERADE; iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
WG
fi
chmod 600 /etc/wireguard/$WG_IF.conf
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-burrow.conf
sysctl -q -p /etc/sysctl.d/99-burrow.conf

# ---- firewall: only ADD rules, never enable or lock anything ----
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow ${WS_PORT}/tcp >/dev/null; fi
if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
  firewall-cmd -q --permanent --add-port=${WS_PORT}/tcp; firewall-cmd -q --reload
fi

# ---- helper command for adding devices ----
cat > /usr/local/bin/burrow-add-client <<'ADDCLIENT'
#!/usr/bin/env bash
# Run on the VPS as root.
#   sudo burrow-add-client                 -> creates a NEW client key on the server, prints a ready-to-paste code
#   sudo burrow-add-client <public_key>    -> registers a key you already have (Burrow > Settings shows it)
set -euo pipefail
IF=${IF:-wg0}
[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)"; exit 1; }
PRIV=""
if [ -z "${1:-}" ]; then
  PRIV=$(wg genkey); PUB=$(printf '%s' "$PRIV" | wg pubkey)
else
  PUB="$1"
  [[ $PUB =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "That doesn't look like a WireGuard public key"; exit 1; }
fi
CONF=/etc/wireguard/$IF.conf
PREFIX=$(cut -d= -f2 /etc/wstunnel/wstunnel.env)
SRVPUB=$(wg show "$IF" public-key)
IP4=$(curl -4fsS https://ifconfig.me || curl -4fsS https://api.ipify.org)
BASE=$(ip -4 -o addr show "$IF" | awk '{print $4}' | cut -d/ -f1 | cut -d. -f1-3)
ADDR=$(wg show "$IF" allowed-ips | awk -v k="$PUB" '$1==k{print $2}' | cut -d/ -f1)
if [ -z "$ADDR" ]; then
  USED=$( { wg show "$IF" allowed-ips; ip -4 -o addr show "$IF"; } | grep -oE "${BASE//./\\.}\.[0-9]+" || true)
  for n in $(seq 2 254); do grep -qx "$BASE.$n" <<<"$USED" || { ADDR="$BASE.$n"; break; }; done
  [ -n "$ADDR" ] || { echo "No free addresses left"; exit 1; }
  wg set "$IF" peer "$PUB" allowed-ips "$ADDR/32"
  grep -q "$PUB" "$CONF" || printf '\n[Peer]\n# burrow\nPublicKey = %s\nAllowedIPs = %s/32\n' "$PUB" "$ADDR" >> "$CONF"
fi
if [ -n "$PRIV" ]; then
  CODE=$(printf '{"ip":"%s","pub":"%s","prefix":"%s","addr":"%s/32","priv":"%s"}' "$IP4" "$SRVPUB" "$PREFIX" "$ADDR" "$PRIV" | base64 -w0)
  echo; echo "Paste this into Burrow > Settings > Connection code, click Import, then Save."
  echo "(It contains this device's private key - treat it like a password.)"
else
  CODE=$(printf '{"ip":"%s","pub":"%s","prefix":"%s","addr":"%s/32"}' "$IP4" "$SRVPUB" "$PREFIX" "$ADDR" | base64 -w0)
  echo; echo "Paste this into Burrow > Settings > Connection code, click Import, then Save."
fi
echo; echo "$CODE"; echo
ADDCLIENT
chmod 755 /usr/local/bin/burrow-add-client

# ---- device enrollment service + admin tool (listens on localhost only; reached through wstunnel) ----
cat > /usr/local/bin/burrow-admin <<'ADMINPY'
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
ADMINPY
chmod 755 /usr/local/bin/burrow-admin
cat > /etc/systemd/system/burrow-enroll.service <<'UNIT2'
[Unit]
Description=Burrow device enrollment (localhost only)
After=wg-quick@wg0.service

[Service]
ExecStart=/usr/local/bin/burrow-admin serve
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT2

# ---- start everything (and on every reboot) ----
say "Starting services"
systemctl daemon-reload
systemctl enable --now wg-quick@$WG_IF >/dev/null 2>&1 || systemctl restart wg-quick@$WG_IF
systemctl enable wstunnel burrow-enroll >/dev/null 2>&1
systemctl restart wstunnel burrow-enroll
sleep 2
systemctl is-active --quiet wg-quick@$WG_IF || { echo "WireGuard failed to start:"; journalctl -u wg-quick@$WG_IF -n 15 --no-pager; exit 1; }
systemctl is-active --quiet burrow-enroll || { echo "enrollment service failed to start:"; journalctl -u burrow-enroll -n 15 --no-pager; exit 1; }
systemctl is-active --quiet wstunnel || { echo "wstunnel failed to start:"; journalctl -u wstunnel -n 15 --no-pager; exit 1; }

# ---- behind nginx: forward only the secret path to wstunnel, leave every website untouched ----
if [ "$BEHIND_NGINX" = 1 ]; then
  say "Connecting nginx to wstunnel"
  LPORT=${WS_BIND##*:}
  PREFIX=$(cut -d= -f2 /etc/wstunnel/wstunnel.env)
  mkdir -p /etc/nginx/snippets
  cat > /etc/nginx/snippets/burrow.conf <<NGX
# Burrow: WebSocket tunnel (managed by server-setup.sh)
location /${PREFIX}/ {
    proxy_pass http://127.0.0.1:${LPORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_buffering off;
    proxy_read_timeout 1d;
    proxy_send_timeout 1d;
}
NGX
  chmod 600 /etc/nginx/snippets/burrow.conf
  # include it in every server block that listens on 443 (the app connects by IP, so the default site must have it)
  FILES=$(grep -RlE '^[[:space:]]*listen[[:space:]]+([^;]*:)?443([^0-9]|$)' /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/nginx/nginx.conf 2>/dev/null | sort -u || true)
  [ -n "$FILES" ] || { echo "Could not find an nginx site listening on 443"; exit 1; }
  NBK=$BK/nginx; mkdir -p "$NBK"
  : > "$NBK/manifest"; i=0
  for f in $FILES; do
    real=$(readlink -f "$f")
    grep -q 'snippets/burrow.conf' "$real" && continue
    i=$((i+1)); cp -a "$real" "$NBK/$i"; printf '%s\t%s\n' "$i" "$real" >> "$NBK/manifest"
    # add the include once per server block, right after its first "listen ... 443" line
    awk '/^[[:space:]]*server[[:space:]]*\{/ {inc=0}
         {print}
         /^[[:space:]]*listen[[:space:]]+([^;]*:)?443([^0-9]|$)/ && !inc {print "    include /etc/nginx/snippets/burrow.conf;"; inc=1}' \
      "$real" > "$real.burrow" && cat "$real.burrow" > "$real" && rm -f "$real.burrow"
  done
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
  else
    echo "nginx rejected the change, restoring the original config:"; nginx -t || true
    while IFS=$'\t' read -r n path; do cat "$NBK/$n" > "$path"; done < "$NBK/manifest"
    exit 1
  fi
fi

# ---- self-test: the tunnel endpoint must answer as wstunnel, not as a web page ----
PREFIX=$(cut -d= -f2 /etc/wstunnel/wstunnel.env)
CODE=$(curl -sk --http1.1 --max-time 8 -o /dev/null -w '%{http_code}' -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://127.0.0.1:$WS_PORT/$PREFIX/events" || true)
if [ "$CODE" = 404 ] || [ "$CODE" = 000 ]; then
  echo "WARNING: port $WS_PORT does not reach wstunnel (HTTP $CODE). Burrow will not be able to connect."
else
  echo "Tunnel endpoint OK (HTTP $CODE from wstunnel)"
fi

say "Server is ready"
echo "NOTE: if your VPS provider has its own firewall (AWS, Oracle, Hetzner, etc.), allow inbound TCP $WS_PORT there too."
echo "Manage devices:  sudo burrow-admin list | revoke <device> | rotate | code"
if [ -n "${1:-}" ]; then
  /usr/local/bin/burrow-add-client "$1"      # optional: register one specific public key
else
  /usr/local/bin/burrow-admin code
fi
