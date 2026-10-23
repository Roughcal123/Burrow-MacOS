"""Burrow - WireGuard over a WebSocket tunnel, supervised. Windows and macOS."""
import sys, os, json, time, subprocess, threading, ipaddress, urllib.request, urllib.error, ssl, re, io, tarfile, base64, filecmp, platform, hmac, hashlib
from pathlib import Path
from PySide6.QtCore import Qt, QTimer, Signal, QObject, QUrl
from PySide6.QtGui import QPainter, QColor, QIcon, QPixmap, QPen, QPainterPath, QAction, QDesktopServices
from PySide6.QtWidgets import (QApplication, QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QPlainTextEdit, QDialog, QFormLayout, QLineEdit, QSystemTrayIcon, QMenu, QMessageBox, QTabWidget)
import keyring

APP = "Burrow"
IS_WIN, IS_MAC = sys.platform == "win32", sys.platform == "darwin"
DATA = (Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / APP if IS_WIN
        else Path.home() / "Library" / "Application Support" / APP)
RES = Path(getattr(sys, "_MEIPASS", Path(__file__).parent)) / "resources"
HELPER_DIR = "/usr/local/libexec/burrow"
HELPER = HELPER_DIR + "/burrow-helper.sh"
EXE = "wstunnel.exe" if IS_WIN else "wstunnel"
PLAT = "windows_amd64" if IS_WIN else ("darwin_arm64" if platform.machine() == "arm64" else "darwin_amd64")
SETTINGS, CONF, WSLOG = DATA / "settings.json", DATA / "Burrow.conf", DATA / "wstunnel.log"
BIN = DATA / "bin"
WG = r"C:\Program Files\WireGuard\wireguard.exe" if IS_WIN else HELPER
WGX = r"C:\Program Files\WireGuard\wg.exe" if IS_WIN else HELPER_DIR + "/wg"
NOWIN = 0x08000000 if IS_WIN else 0
LOCAL_PORT = 51821
AMBER, MOSS, RED, GREY, NIGHT, PANEL = "#F5A623", "#4CAF7A", "#E5594F", "#9AA0A6", "#0F1419", "#2A2118"
VERSION = "1.1.0"
# Admin sign-in is a UI gate only (not real security): only a salted hash is stored in the app.
ADMIN_SALT = bytes.fromhex("3267506b4afbc83983848a4d8a4d4087")
ADMIN_HASH = "5c6f8a886328cce05bc7f29051c2d35e7d5e00eee394598ddcecc7494c24d30c"
DEFAULTS = dict(server_ip="", server_pub="", address="10.66.66.3/32", dns="1.1.1.1", mtu="1380", wg_port="51820")


def run(args, **kw):
    try:
        return subprocess.run(args, capture_output=True, text=True, creationflags=NOWIN, **kw)
    except OSError as e:  # tool missing or not runnable: report it instead of crashing
        return subprocess.CompletedProcess(args, 127, "", str(e))


def load():
    try:
        return {**DEFAULTS, **json.loads(SETTINGS.read_text())}
    except Exception:
        return dict(DEFAULTS)


def ensure_data():
    DATA.mkdir(parents=True, exist_ok=True)
    # keep the folder private (the config holds the private key)
    if IS_WIN:
        run(["icacls", str(DATA), "/inheritance:r", "/grant", "*S-1-5-32-544:(OI)(CI)F", "*S-1-5-18:(OI)(CI)F"])
    else:
        DATA.chmod(0o700)


def save(c):
    ensure_data()
    SETTINGS.write_text(json.dumps(c, indent=2))


def secret(name, value=None):
    if IS_MAC:  # private file instead of the Keychain, so macOS never shows a password prompt
        path = DATA / "secrets.json"
        try:
            d = json.loads(path.read_text())
        except Exception:
            d = {}
        if value is None:
            return d.get(name, "")
        d[name] = value
        ensure_data()
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(d, f)
        os.chmod(path, 0o600)
        return
    if value is None:
        return keyring.get_password(APP, name) or ""
    keyring.set_password(APP, name, value)


def wstunnel_path():
    base = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).parent
    for p in (BIN / EXE, base / EXE, Path(r"C:\Program Files\wstunnel\wstunnel.exe")):
        if p.exists():
            return str(p)
    return None


def http_get(url, timeout=30):
    """Try the bundled CA list first (packaged apps often have none), then the system store
    (which also trusts a school/work network's own certificate if it is installed)."""
    ctxs = []
    try:
        import certifi
        ctxs.append(ssl.create_default_context(cafile=certifi.where()))
    except Exception:
        pass
    ctxs.append(ssl.create_default_context())
    last = None
    for ctx in ctxs:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": APP})
            return urllib.request.urlopen(req, timeout=timeout, context=ctx).read()
        except urllib.error.URLError as e:
            if not isinstance(e.reason, ssl.SSLError):
                raise
            last = e
    raise RuntimeError(f"SSL certificate check failed for {url.split('/')[2]}: {last.reason}")


def install_wstunnel(log):
    rel = json.loads(http_get("https://api.github.com/repos/erebe/wstunnel/releases/latest"))
    ver = rel["tag_name"].lstrip("v")
    name = f"wstunnel_{ver}_{PLAT}.tar.gz"
    url = next(a["browser_download_url"] for a in rel["assets"] if a["name"] == name)
    log(f"Downloading wstunnel {ver}")
    with tarfile.open(fileobj=io.BytesIO(http_get(url, 180)), mode="r:gz") as t:
        m = next(m for m in t.getmembers() if m.name.split("/")[-1] == EXE)
        ensure_data()
        BIN.mkdir(parents=True, exist_ok=True)
        (BIN / EXE).write_bytes(t.extractfile(m).read())
        (BIN / EXE).chmod(0o755)


def install_wireguard(log):
    base = "https://download.wireguard.com/windows-client/"
    vers = re.findall(r"wireguard-amd64-(\d+(?:\.\d+)+)\.msi", http_get(base).decode("utf8", "ignore"))
    ver = max(vers, key=lambda v: tuple(map(int, v.split(".")))) if vers else "0.5.3"
    log(f"Downloading WireGuard {ver}")
    ensure_data()
    msi = DATA / "wireguard.msi"
    msi.write_bytes(http_get(f"{base}wireguard-amd64-{ver}.msi", 180))
    sig = run(["powershell", "-NoProfile", "-Command",
               f"$s=Get-AuthenticodeSignature '{msi}'; $s.Status; $s.SignerCertificate.Subject"]).stdout
    lines = sig.strip().splitlines()
    if not lines or lines[0].strip() != "Valid" or "WireGuard" not in sig:
        msi.unlink(missing_ok=True)
        raise RuntimeError("WireGuard installer failed its signature check")
    log("Installing WireGuard")
    r = run(["msiexec", "/i", str(msi), "/qn", "/norestart"])
    msi.unlink(missing_ok=True)
    if r.returncode not in (0, 3010):
        raise RuntimeError(f"WireGuard install failed (code {r.returncode})")


def install_helper(log):
    """macOS: one admin prompt installs the root-owned helper, WireGuard tools and a sudoers rule."""
    log("Installing the network helper (macOS asks for your password once)")
    sh = RES / "install-helper.sh"
    r = run(["osascript", "-e", f'do shell script "bash \\"{sh}\\" \\"{RES}\\"" with administrator privileges'])
    if r.returncode:
        raise RuntimeError("helper install cancelled or failed: " + r.stderr.strip()[:120])


INSTALL_WG = install_helper if IS_MAC else install_wireguard


def wg_ready():
    if not IS_MAC:
        return Path(WG).exists()
    src = RES / "burrow-helper.sh"
    return (Path(HELPER).exists() and Path(WGX).exists() and (not src.exists() or filecmp.cmp(HELPER, src, shallow=False))
            and run(["sudo", "-n", HELPER, "down"]).returncode == 0)


def component_info(name):
    if name == "WireGuard":
        if not wg_ready():
            return "Not installed"
        if IS_MAC:
            return "Installed (bundled WireGuard tools + network helper)"
        v = run(["powershell", "-NoProfile", "-Command",
                 f"(Get-Item '{WG}').VersionInfo.ProductVersion"]).stdout.strip()
        return f"Installed ({v})"
    exe = wstunnel_path()
    if not exe:
        return "Not installed"
    return f"Installed ({run([exe, '--version']).stdout.strip()}) at {exe}"


def allowed_ips(server_ip):
    """0.0.0.0/0 minus the server, so wstunnel's own connection never loops into the tunnel."""
    nets = ipaddress.ip_network("0.0.0.0/0").address_exclude(ipaddress.ip_network(server_ip + "/32"))
    return ", ".join(str(n) for n in sorted(nets))


def build_conf(c):
    return (f"[Interface]\nPrivateKey = {secret('private_key')}\nAddress = {c['address']}\n"
            f"DNS = {c['dns']}\nMTU = {c['mtu']}\n\n[Peer]\nPublicKey = {c['server_pub']}\n"
            f"AllowedIPs = {allowed_ips(c['server_ip'])}\nEndpoint = 127.0.0.1:{LOCAL_PORT}\n"
            f"PersistentKeepalive = 25\n")


def check_admin(pw):
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), ADMIN_SALT, 200_000)
    return hmac.compare_digest(h.hex(), ADMIN_HASH)


def admin_signed_in():
    try:
        return secret("admin_ok") == "1"
    except Exception:
        return False


def redact(t):
    for v in (secret("prefix"), secret("private_key")):
        if v:
            t = t.replace(v, "xxxx")
    return t


def ws_tail():
    try:
        return WSLOG.read_text(errors="replace")[-8000:]
    except Exception:
        return "(no wstunnel.log yet)"


def make_icon(state="off", size=64):
    col = QColor({"off": GREY, "connecting": AMBER, "on": AMBER, "error": RED}[state])
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    m, w = size * 0.14, size * 0.72
    path = QPainterPath()
    path.moveTo(m, size - m)
    path.lineTo(m, size / 2)
    path.arcTo(m, m, w, w, 180, -180)
    path.lineTo(size - m, size - m)
    path.closeSubpath()
    p.setPen(QPen(col, size * 0.08))
    fill = QColor(col)
    fill.setAlpha(90 if state == "on" else 0)
    p.setBrush(fill)
    p.drawPath(path)
    if state != "off":
        p.setPen(Qt.NoPen)
        p.setBrush(col)
        r = size * 0.09
        p.drawEllipse(int(size / 2 - r), int(size * 0.62 - r), int(2 * r), int(2 * r))
    p.end()
    return pm


class Engine(QObject):
    log = Signal(str)
    state = Signal(str, str)
    exit_ip = Signal(str)
    ready = Signal(bool)

    def __init__(self):
        super().__init__()
        self.proc, self.wslog = None, None
        self.up, self.busy, self.t0 = False, False, 0
        self.last_ip = "-"

    # --- wstunnel ---
    def start_ws(self, c):
        exe = wstunnel_path()
        if not exe:
            self.log.emit("wstunnel.exe not found (put it next to Burrow.exe)")
            return False
        self.stop_ws()
        DATA.mkdir(parents=True, exist_ok=True)
        self.wslog = open(WSLOG, "w")
        self.proc = subprocess.Popen(
            [exe, "client", "--http-upgrade-path-prefix", secret("prefix"), "-L",
             f"udp://127.0.0.1:{LOCAL_PORT}:127.0.0.1:{c['wg_port']}?timeout_sec=0",
             f"wss://{c['server_ip']}:443"],
            stdout=self.wslog, stderr=self.wslog, creationflags=NOWIN)
        time.sleep(1.5)
        ok = self.proc.poll() is None
        self.log.emit("wstunnel started" if ok else "wstunnel exited immediately, see wstunnel.log")
        return ok

    def stop_ws(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
        self.proc = None

    def handshake_age(self):
        name = APP
        if IS_MAC:
            try:
                name = Path("/var/run/burrow.name").read_text().strip()
            except Exception:
                return None
        r = run([WGX, "show", name, "latest-handshakes"])
        try:
            ts = int(r.stdout.split()[-1])
            return time.time() - ts if ts else None
        except Exception:
            return None

    def wg_show(self):
        name = APP
        if IS_MAC:
            try:
                name = Path("/var/run/burrow.name").read_text().strip()
            except Exception:
                return "(tunnel not up)"
        r = run([WGX, "show", name])
        return (r.stdout or r.stderr).strip() or "(no output)"

    # --- first-run setup: download and install what's missing ---
    def ensure_deps(self):
        try:
            if not wg_ready():
                INSTALL_WG(self.log.emit)
            if not wstunnel_path():
                install_wstunnel(self.log.emit)
        except Exception as e:
            self.log.emit(f"Setup failed: {e}")
            return False
        return wg_ready() and bool(wstunnel_path())

    def setup(self):
        def go():
            self.busy = True
            self.state.emit("connecting", "Setting up WireGuard and wstunnel...")
            ok = self.ensure_deps()
            self.busy = False
            self.state.emit("off" if ok else "error", "Ready" if ok else "Setup failed. Check your internet connection and try again")
            self.ready.emit(ok)
        if not self.busy:
            threading.Thread(target=go, daemon=True).start()

    # --- connect / disconnect ---
    def connect_(self):
        if not self.busy:
            threading.Thread(target=self._connect, daemon=True).start()

    def disconnect_(self, wait=False):
        t = threading.Thread(target=self._disconnect, daemon=True)
        t.start()
        if wait:
            t.join(10)

    def _fail(self, msg):
        self.log.emit(msg)
        self._teardown()
        self.state.emit("error", msg)
        self.busy = False

    def plat_up(self, c):
        if IS_MAC:
            r = subprocess.run(["sudo", "-n", HELPER, "up", str(os.getuid()), c["server_ip"],
                                c["address"].split("/")[0], c["dns"], str(c["mtu"])],
                               input=f"{secret('private_key')}\n{c['server_pub']}\n",
                               capture_output=True, text=True)
            return "" if r.returncode == 0 else "Network helper failed: " + (r.stderr or r.stdout).strip()[:120]
        ensure_data()
        CONF.write_text(build_conf(c))
        r = run([WG, "/installtunnelservice", str(CONF)])
        return "" if not r.returncode else "WireGuard refused the config: " + (r.stderr or r.stdout).strip()[:120]

    def _teardown(self):
        if IS_MAC:
            run(["sudo", "-n", HELPER, "down"])
        else:
            run([WG, "/uninstalltunnelservice", APP])
        self.stop_ws()
        CONF.unlink(missing_ok=True)
        self.up = False

    def _connect(self):
        self.busy = True
        c = load()
        if not (c["server_ip"] and c["server_pub"] and secret("private_key") and secret("prefix")):
            return self._fail("Open Settings and fill in the server details first")
        self.state.emit("connecting", "Checking components...")
        if not self.ensure_deps():
            return self._fail("Could not install WireGuard or wstunnel. Check your internet connection")
        self.state.emit("connecting", "Digging in...")
        self._teardown()
        if not self.start_ws(c):
            return self._fail("Could not start wstunnel")
        err = self.plat_up(c)
        if err:
            return self._fail(err)
        for _ in range(25):
            if self.handshake_age() is not None:
                self.up, self.t0, self.busy = True, time.time(), False
                self.log.emit("Handshake complete")
                self.state.emit("on", "Traffic is flowing through your server")
                self._fetch_ip()
                return
            time.sleep(1)
        self._fail("No handshake. Check server details and that the server is reachable")

    def _disconnect(self):
        self.state.emit("connecting", "Surfacing...")
        self._teardown()
        self.busy = False
        self.log.emit("Disconnected")
        self.state.emit("off", "Not connected")

    def _fetch_ip(self):
        try:
            ip = http_get("https://ifconfig.me/ip", 8).decode().strip()
        except Exception:
            ip = "unknown"
        self.last_ip = ip
        self.exit_ip.emit(ip)

    # --- watchdog (called every few seconds) ---
    def watchdog(self):
        if not self.up or self.busy:
            return
        threading.Thread(target=self._watch, daemon=True).start()

    def _watch(self):
        c = load()
        if not self.proc or self.proc.poll() is not None:
            self.log.emit("wstunnel died, restarting")
            self.start_ws(c)
            return
        age = self.handshake_age()
        if age is None or age > 200:
            self.log.emit("Connection went stale, restarting wstunnel")
            self.state.emit("connecting", "Connection lost, retrying")
            self.start_ws(c)
            time.sleep(8)
            if self.handshake_age() is not None:
                self.state.emit("on", "Back underground")
                self._fetch_ip()


class Settings(QDialog):
    installed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Burrow settings")
        self.setMinimumWidth(460)
        c = load()
        self.f = {k: QLineEdit(c[k]) for k in DEFAULTS}
        self.priv, self.prefix = QLineEdit(secret("private_key")), QLineEdit(secret("prefix"))
        self.priv.setEchoMode(QLineEdit.Password)
        self.prefix.setEchoMode(QLineEdit.Password)
        self.pub = QLabel("")
        self.pub.setTextInteractionFlags(Qt.TextSelectableByMouse)
        self.pub.setWordWrap(True)
        self.code = QLineEdit()
        self.code.setPlaceholderText("Paste the code printed by add-client.sh")
        imp = QPushButton("Import code")
        imp.clicked.connect(self.imp)
        form = QFormLayout()
        form.addRow("Connection code", self.code)
        form.addRow("", imp)
        self.comp, self.btns, self.err = {}, {}, {}
        for name in ("WireGuard", "wstunnel"):
            lab, b = QLabel(), QPushButton("Reinstall")
            lab.setWordWrap(True)
            b.clicked.connect(lambda _=False, n=name: self.reinstall(n))
            row = QHBoxLayout()
            row.addWidget(lab, 1)
            row.addWidget(b)
            form.addRow(name, row)
            self.comp[name], self.btns[name] = lab, b
        self.installed.connect(self.refresh_comp)
        self.refresh_comp()
        form.addRow("Server IP", self.f["server_ip"])
        form.addRow("Secret path prefix", self.prefix)
        form.addRow("Server public key", self.f["server_pub"])
        form.addRow("Your private key", self.priv)
        gen = QPushButton("Generate new key pair")
        gen.clicked.connect(self.gen)
        form.addRow("", gen)
        form.addRow("Your public key", self.pub)
        form.addRow("Tunnel address", self.f["address"])
        form.addRow("DNS", self.f["dns"])
        form.addRow("MTU", self.f["mtu"])
        form.addRow("Server WireGuard port", self.f["wg_port"])
        ok = QPushButton("Save")
        ok.setObjectName("primary")
        ok.clicked.connect(self.done_)
        lay = QVBoxLayout(self)
        lay.addLayout(form)
        lay.addWidget(ok)
        if not self.priv.text() and Path(WGX).exists():
            self.gen()
        self.show_pub()

    def show_pub(self):
        k = self.priv.text().strip()
        if k and Path(WGX).exists():
            pub = run([WGX, "pubkey"], input=k).stdout.strip()
            self.pub.setText(f"{pub}\nOn your server run: sudo bash add-client.sh {pub}")

    def refresh_comp(self):
        for n, lab in self.comp.items():
            lab.setText(component_info(n) + (f"\nLast error: {self.err[n]}" if self.err.get(n) else ""))
            lab.setStyleSheet(f"color:{MOSS if lab.text().startswith('Installed') else RED}")
            self.btns[n].setEnabled(True)

    def reinstall(self, name):
        self.btns[name].setEnabled(False)
        self.comp[name].setText("Working...")
        self.err[name] = ""

        def go():
            try:
                (INSTALL_WG if name == "WireGuard" else install_wstunnel)(lambda m: None)
            except Exception as e:
                self.err[name] = str(e)[:150]
            self.installed.emit()
        threading.Thread(target=go, daemon=True).start()

    def imp(self):
        try:
            d = json.loads(base64.b64decode(self.code.text().strip()))
            self.f["server_ip"].setText(d["ip"])
            self.f["server_pub"].setText(d["pub"])
            self.f["address"].setText(d["addr"])
            self.prefix.setText(d["prefix"])
        except Exception:
            QMessageBox.warning(self, APP, "That connection code isn't valid.")

    def gen(self):
        self.priv.setText(run([WGX, "genkey"]).stdout.strip())
        self.show_pub()

    def done_(self):
        save({k: v.text().strip() for k, v in self.f.items()})
        secret("private_key", self.priv.text().strip())
        secret("prefix", self.prefix.text().strip())
        self.accept()


class Account(QDialog):
    def __init__(self, main):
        super().__init__(main)
        self.main, self.fails = main, 0
        self.setWindowTitle("Account")
        self.setMinimumWidth(340)
        lay = QVBoxLayout(self)
        if main.admin:
            lay.addWidget(QLabel("<b>Signed in as admin</b><br>Debug tools are unlocked on this device."))
            dbg = QPushButton("Open Debug menu")
            dbg.setObjectName("primary")
            dbg.clicked.connect(lambda: (self.accept(), main.open_debug()))
            out = QPushButton("Sign out")
            out.clicked.connect(self.sign_out)
            lay.addWidget(dbg)
            lay.addWidget(out)
        else:
            lay.addWidget(QLabel("<b>Admin sign in</b><br>Sign in once to unlock the Debug menu on this device."))
            self.pw = QLineEdit()
            self.pw.setEchoMode(QLineEdit.Password)
            self.pw.setPlaceholderText("Password")
            self.pw.returnPressed.connect(self.sign_in)
            self.msg = QLabel("")
            self.msg.setStyleSheet(f"color:{RED}")
            self.go = QPushButton("Sign in")
            self.go.setObjectName("primary")
            self.go.clicked.connect(self.sign_in)
            for w in (self.pw, self.msg, self.go):
                lay.addWidget(w)

    def sign_in(self):
        if check_admin(self.pw.text()):
            try:
                secret("admin_ok", "1")  # one-time login: remembered until you sign out
            except Exception:
                pass
            self.main.set_admin(True)
            self.accept()
            self.main.open_debug()
        else:
            self.fails += 1
            self.msg.setText("Wrong password")
            self.pw.clear()
            self.go.setEnabled(False)
            QTimer.singleShot(min(self.fails, 5) * 1000, lambda: self.go.setEnabled(True))

    def sign_out(self):
        try:
            secret("admin_ok", "")
        except Exception:
            pass
        self.main.set_admin(False)
        self.accept()


class Debug(QDialog):
    def __init__(self, main):
        super().__init__(main)
        self.main, self.eng, self.comp = main, main.eng, None
        self.setWindowTitle("Burrow debug")
        self.resize(640, 520)
        self.tabs, self.box = QTabWidget(), {}
        for n in ("Status", "Log", "wstunnel.log"):
            b = QPlainTextEdit()
            b.setReadOnly(True)
            self.tabs.addTab(b, n)
            self.box[n] = b
        row = QHBoxLayout()
        for label, fn in (("Refresh", self.full_refresh), ("Check exit IP", self.check_ip),
                          ("Restart wstunnel", self.restart_ws), ("Copy report", self.copy),
                          ("Open data folder", self.folder)):
            b = QPushButton(label)
            b.clicked.connect(lambda _=False, f=fn: f())
            row.addWidget(b)
        lay = QVBoxLayout(self)
        lay.addLayout(row)
        lay.addWidget(self.tabs)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh)
        self.timer.start(3000)
        self.refresh()

    def status_text(self):
        e, m, c = self.eng, self.main, load()
        if self.comp is None:
            self.comp = [component_info("WireGuard"), component_info("wstunnel")]
        age = e.handshake_age() if e.up else None
        run_ = e.proc is not None and e.proc.poll() is None
        lines = [
            f"Burrow {VERSION} on {platform.platform()} ({platform.machine()})",
            f"State: {m.st}   Connected: {e.up}   Uptime: {int(time.time() - e.t0) if e.up else 0}s",
            f"Exit IP: {e.last_ip}",
            f"Handshake age: {'%.0fs' % age if age is not None else 'none'}",
            f"wstunnel: {'running, pid %s' % e.proc.pid if run_ else 'not running'}",
            "", "Components:", f"  WireGuard: {self.comp[0]}", f"  wstunnel: {self.comp[1]}",
            "", "Settings:",
            f"  server_ip={c['server_ip']} address={c['address']} dns={c['dns']} mtu={c['mtu']} wg_port={c['wg_port']}",
            f"  server key: {'set' if c['server_pub'] else 'missing'}   "
            f"private key: {'set' if secret('private_key') else 'missing'}   "
            f"prefix: {'set' if secret('prefix') else 'missing'}",
            "", f"Data folder: {DATA}", "", "wg show:", e.wg_show()]
        return redact("\n".join(lines))

    def put(self, name, text):
        b = self.box[name]
        sb = b.verticalScrollBar()
        pos, at_end = sb.value(), sb.value() >= sb.maximum() - 2
        if b.toPlainText() != text:
            b.setPlainText(text)
            sb.setValue(sb.maximum() if at_end else pos)

    def refresh(self):
        self.put("Status", self.status_text())
        self.put("Log", redact("\n".join(self.main.logbuf)))
        self.put("wstunnel.log", redact(ws_tail()))

    def full_refresh(self):
        self.comp = None
        self.refresh()

    def check_ip(self):
        self.eng.last_ip = "checking..."
        threading.Thread(target=self.eng._fetch_ip, daemon=True).start()

    def restart_ws(self):
        threading.Thread(target=lambda: self.eng.start_ws(load()), daemon=True).start()

    def copy(self):
        QApplication.clipboard().setText(redact(self.status_text() + "\n\n--- LOG ---\n" +
                                                "\n".join(self.main.logbuf) + "\n\n--- wstunnel.log ---\n" + ws_tail()))

    def folder(self):
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(DATA)))

    def closeEvent(self, e):
        self.timer.stop()
        self.main.dbg = None
        e.accept()


STYLE = f"""
QWidget {{ background:{NIGHT}; color:#E8EAED; font-family:Inter,'Segoe UI'; font-size:13px; }}
QPlainTextEdit, QLineEdit {{ background:{PANEL}; border:1px solid #3a2f24; border-radius:6px; padding:6px;
  font-family:'JetBrains Mono',Consolas; }}
QPushButton {{ background:{PANEL}; border:1px solid #3a2f24; border-radius:8px; padding:8px 14px; }}
QPushButton:hover {{ border-color:{AMBER}; }}
QPushButton#primary {{ background:{AMBER}; color:#1a1208; font-weight:600; font-size:15px; padding:14px; border:none; }}
QPushButton#primary:disabled {{ background:#6b5a3a; color:#2a2118; }}
QPushButton#link {{ background:transparent; border:none; color:{GREY}; padding:4px; }}
QLabel#status {{ font-size:22px; font-weight:600; }}
QLabel#dim {{ color:{GREY}; }}
"""
STATUS = {"off": "Above ground", "connecting": "Working...", "on": "Underground", "error": "Collapsed"}
COLOR = {"off": GREY, "connecting": AMBER, "on": MOSS, "error": RED}


class Main(QWidget):
    def __init__(self, eng):
        super().__init__()
        self.eng, self.st = eng, "off"
        self.logbuf, self.dbg, self.admin = [], None, admin_signed_in()
        self.setWindowTitle(APP)
        self.setFixedSize(420, 420)
        self.logo = QLabel()
        title = QLabel(f"<span style='font-size:20px;font-weight:700'>{APP}</span><br>"
                       f"<span style='color:{GREY}'>Dig past the firewall.</span>")
        head = QHBoxLayout()
        head.addWidget(self.logo)
        head.addWidget(title, 1)
        self.dbgbtn = None
        for label, fn in (("Debug", self.open_debug), ("Account", self.open_account),
                          ("Settings", lambda: Settings(self).exec())):
            b = QPushButton(label)
            b.setObjectName("link")
            b.clicked.connect(lambda _=False, f=fn: f())
            head.addWidget(b)
            if label == "Debug":
                self.dbgbtn = b
        self.dbgbtn.setVisible(self.admin)
        self.status, self.detail = QLabel(), QLabel()
        self.status.setObjectName("status")
        self.detail.setObjectName("dim")
        self.detail.setWordWrap(True)
        self.up = QLabel("Uptime: -")
        self.up.setObjectName("dim")
        self.btn = QPushButton("Connect")
        self.btn.setObjectName("primary")
        self.btn.clicked.connect(self.toggle)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(20, 16, 20, 20)
        lay.addLayout(head)
        lay.addSpacing(18)
        lay.addWidget(self.status)
        lay.addWidget(self.detail)
        lay.addSpacing(10)
        lay.addWidget(self.up)
        lay.addStretch(1)
        lay.addWidget(self.btn)  # Connect lives at the bottom
        eng.log.connect(self.on_log)
        eng.state.connect(self.set_state)
        self.tray = QSystemTrayIcon(QIcon(make_icon("off")), self)
        menu = QMenu()
        for label, fn in (("Show", self.showNormal), ("Connect / Disconnect", self.toggle),
                          ("Quit", self.quit)):
            a = QAction(label, self)
            a.triggered.connect(fn)
            menu.addAction(a)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(lambda r: self.showNormal() if r == QSystemTrayIcon.Trigger else None)
        self.tray.show()
        self.tick = QTimer(self)
        self.tick.timeout.connect(self.refresh)
        self.tick.start(1000)
        self.dog = QTimer(self)
        self.dog.timeout.connect(eng.watchdog)
        self.dog.start(10000)
        self.set_state("off", "Not connected")
        eng.ready.connect(self.after_setup)
        QTimer.singleShot(400, lambda: eng.setup() if not (wg_ready() and wstunnel_path()) else self.after_setup(True))

    def on_log(self, m):
        self.logbuf.append(time.strftime("%H:%M:%S ") + m)
        del self.logbuf[:-500]

    def set_admin(self, flag):
        self.admin = flag
        self.dbgbtn.setVisible(flag)
        if not flag and self.dbg:
            self.dbg.close()

    def open_account(self):
        Account(self).exec()

    def open_debug(self):
        if not self.admin:
            return self.open_account()
        if self.dbg is None:
            self.dbg = Debug(self)
        self.dbg.show()
        self.dbg.raise_()

    def after_setup(self, ok):
        if ok and not load()["server_ip"]:
            self.showNormal()
            Settings(self).exec()

    def set_state(self, st, detail):
        self.st = st
        self.status.setText(STATUS[st])
        self.status.setStyleSheet(f"color:{COLOR[st]}")
        self.detail.setText(detail)
        self.logo.setPixmap(make_icon(st, 48))
        self.tray.setIcon(QIcon(make_icon(st)))
        self.btn.setEnabled(st != "connecting")
        self.btn.setText("Disconnect" if st == "on" else "Connect")

    def refresh(self):
        if self.eng.up:
            s = int(time.time() - self.eng.t0)
            self.up.setText(f"Uptime: {s // 3600:02}:{s % 3600 // 60:02}:{s % 60:02}")
        else:
            self.up.setText("Uptime: -")

    def toggle(self):
        self.eng.disconnect_() if self.st == "on" else self.eng.connect_()

    def quit(self):
        self.eng.disconnect_(wait=True)
        self.tray.hide()
        QApplication.quit()

    def closeEvent(self, e):
        e.ignore()
        self.hide()
        self.tray.showMessage(APP, "Still running in the tray.", QSystemTrayIcon.Information, 2000)


def main():
    app = QApplication(sys.argv)
    if "--icon" in sys.argv:  # used by build.bat to make burrow.ico
        make_icon("on", 256).save("burrow.ico")
        make_icon("on", 1024).save("burrow.png")
        return
    if IS_WIN:
        import ctypes
        if not ctypes.windll.shell32.IsUserAnAdmin():
            QMessageBox.critical(None, APP, "Burrow needs to run as administrator.")
            return
    app.setStyleSheet(STYLE)
    app.setQuitOnLastWindowClosed(False)
    w = Main(Engine())
    w.show()
    app.aboutToQuit.connect(lambda: w.eng.disconnect_(wait=True))
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
