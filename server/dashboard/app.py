#!/usr/bin/env python3
"""
CS2 dashboard + helper CLI (Python standard library only, no pip installs).

  app.py serve            HTTP API + UI on 127.0.0.1:8088 (Caddy adds HTTPS + login in front)
  app.py rcon "<cmd>"     run one console command over RCON and print the reply
  app.py status           parsed server status as JSON
  app.py humans           number of human players (-1 if the server is unreachable)

License: MIT
"""
import collections
import glob
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.environ.get("CS2_BASE", "/opt/cs2")
DATA = os.path.join(BASE, "data")
CONTAINER = os.environ.get("CS2_CONTAINER", "cs2")
HERE = os.path.dirname(os.path.abspath(__file__))
LISTEN_HOST = os.environ.get("DASH_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("DASH_PORT", "8088"))
RCON_HOST = os.environ.get("RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.environ.get("RCON_PORT", "27015"))
HISTORY_POINTS = 720          # 1 hour at 5 s
FALLBACK_MAPS = ["de_ancient", "de_anubis", "de_dust2", "de_inferno", "de_mirage", "de_nuke",
                 "de_overpass", "de_train", "de_vertigo", "cs_italy", "cs_office"]
MODES = {  # name: (game_type, game_mode)
    "competitive": (0, 1), "casual": (0, 0), "wingman": (0, 2),
    "deathmatch": (1, 2), "armsrace": (1, 0),
}
PRESETS = {
    "practice": "sv_cheats 1; mp_warmup_end; mp_freezetime 0; mp_roundtime_defuse 60; mp_buy_anywhere 1; "
                "mp_buytime 9999; mp_startmoney 60000; mp_maxmoney 60000; sv_infinite_ammo 1; "
                "ammo_grenade_limit_total 5; sv_grenade_trajectory_prac_pipreview 1; bot_kick; mp_restartgame 1",
    "live":     "sv_cheats 0; sv_infinite_ammo 0; mp_buy_anywhere 0; mp_buytime 20; mp_startmoney 800; "
                "mp_maxmoney 16000; mp_freezetime 15; mp_roundtime_defuse 1.92; ammo_grenade_limit_total 4; "
                "sv_grenade_trajectory_prac_pipreview 0; mp_warmup_end; mp_restartgame 3",
    "warmup":   "mp_warmup_start; mp_warmup_pausetimer 1",
}


def load_env(path=os.path.join(BASE, "cs2.env")):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r'^\s*([A-Z0-9_]+)=(.*)$', line)
                if m:
                    v = m.group(2).strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                        v = v[1:-1]
                    env[m.group(1)] = v
    except FileNotFoundError:
        pass
    return env


ENV = load_env()

# ===================================================================== RCON


class RconError(Exception):
    pass


class Rcon:
    """Source RCON client with a persistent, lock-protected connection."""
    AUTH, AUTH_RESPONSE, EXEC, RESPONSE = 3, 2, 2, 0

    def __init__(self, host, port, password):
        self.host, self.port, self.password = host, port, password
        self.sock = None
        self.lock = threading.Lock()
        self.req = 0

    def _send(self, ptype, body):
        self.req = (self.req % 1_000_000) + 1
        data = struct.pack("<ii", self.req, ptype) + body.encode("utf-8", "replace") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(data)) + data)
        return self.req

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RconError("connection closed")
            buf += chunk
        return buf

    def _recv(self):
        (size,) = struct.unpack("<i", self._recv_exact(4))
        if size < 10 or size > 1_048_576:
            raise RconError("bad packet size")
        payload = self._recv_exact(size)
        rid, ptype = struct.unpack("<ii", payload[:8])
        return rid, ptype, payload[8:-2].decode("utf-8", "replace")

    def _connect(self):
        self.close()
        if not self.password:
            raise RconError("RCON password not configured")
        s = socket.create_connection((self.host, self.port), timeout=3)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = s
        rid = self._send(self.AUTH, self.password)
        deadline = time.time() + 4
        while time.time() < deadline:
            r, t, _ = self._recv()
            if t == self.AUTH_RESPONSE:
                if r == -1:
                    self.close()
                    raise RconError("RCON authentication failed (wrong password)")
                if r == rid:
                    return
        raise RconError("no auth response")

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def command(self, cmd, timeout=4.0):
        with self.lock:
            for attempt in (1, 2):
                try:
                    if self.sock is None:
                        self._connect()
                    self.sock.settimeout(timeout)
                    rid = self._send(self.EXEC, cmd)
                    parts, got_first = [], False
                    while True:
                        try:
                            r, t, body = self._recv()
                        except socket.timeout:
                            if got_first:
                                break
                            raise
                        if r == rid and t == self.RESPONSE:
                            parts.append(body)
                            if not got_first:
                                got_first = True
                                self.sock.settimeout(0.25)  # gather multi-packet replies
                    self.sock.settimeout(timeout)
                    return "".join(parts)
                except (OSError, RconError, struct.error) as e:
                    self.close()
                    if attempt == 2 or (isinstance(e, RconError) and "authentication" in str(e)):
                        raise RconError(str(e) or e.__class__.__name__)
        return ""


RCON = Rcon(RCON_HOST, RCON_PORT, ENV.get("CS2_RCONPW", ""))

# ===================================================================== parsing

PLAYER_RE = re.compile(
    r"^\s*(\d+)\s+(\S+)\s+(\d+)\s+(\d+)\s+([a-z]+)\s+(\d+)\s*(\S*?)\s*'(.*)'\s*$")


def parse_status(text):
    info = {"hostname": None, "map": None, "humans": 0, "bots": 0, "max": None,
            "version": None, "players": [], "hibernating": None}
    in_players = False
    for raw in text.splitlines():
        line = raw.rstrip()
        m = re.match(r"^\s*hostname\s*:\s*(.*)$", line)
        if m:
            info["hostname"] = m.group(1).strip()
        m = re.match(r"^\s*version\s*:\s*(\S+)", line)
        if m:
            info["version"] = m.group(1)
        m = re.match(r"^\s*players\s*:\s*(\d+)\s+humans?,\s*(\d+)\s+bots?\s*\((\d+)\s+max\)(.*)$", line)
        if m:
            info["humans"], info["bots"], info["max"] = int(m.group(1)), int(m.group(2)), int(m.group(3))
            info["hibernating"] = "not hibernating" not in m.group(4) and "hibernating" in m.group(4)
        m = re.match(r"^\s*\[\d+:\s*([A-Za-z0-9_\-/.]+)\s*\|", line)
        if m and info["map"] is None:
            info["map"] = m.group(1)
        m = re.match(r"^\s*map\s*:\s*(\S+)", line)
        if m:
            info["map"] = m.group(1)
        if "---players---" in line:
            in_players = True
            continue
        if line.startswith("#end"):
            in_players = False
        if in_players:
            pm = PLAYER_RE.match(line)
            if pm and pm.group(1) != "65535":
                adr = pm.group(7)
                bot = pm.group(2) == "BOT" or not adr or adr == "unknown"
                info["players"].append({
                    "id": int(pm.group(1)), "time": pm.group(2), "ping": int(pm.group(3)),
                    "loss": int(pm.group(4)), "state": pm.group(5), "rate": int(pm.group(6)),
                    "name": pm.group(8), "bot": bot,
                })
    return info


# ===================================================================== docker + files

def run(cmd, timeout=15):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def container_info():
    rc, out = run(["docker", "inspect", "-f",
                   "{{.State.Status}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.Config.Image}}", CONTAINER])
    if rc != 0:
        return {"state": "missing"}
    status, started, restarts, image = (out.strip().split("|") + ["", "", "", ""])[:4]
    info = {"state": status, "started_at": started, "restarts": int(restarts or 0), "image": image}
    if status == "running":
        rc, top = run(["docker", "top", CONTAINER], timeout=8)
        info["updating"] = rc == 0 and "steamcmd" in top
    return info


def container_stats():
    rc, out = run(["docker", "stats", "--no-stream", "--format", "{{json .}}", CONTAINER], timeout=12)
    if rc != 0:
        return {}
    try:
        d = json.loads(out.strip().splitlines()[0])
        return {"cpu": float(d.get("CPUPerc", "0").rstrip("%") or 0), "mem": d.get("MemUsage", "")}
    except (ValueError, IndexError):
        return {}


def installed_build():
    try:
        with open(os.path.join(DATA, "steamapps", "appmanifest_730.acf")) as f:
            m = re.search(r'"buildid"\s+"(\d+)"', f.read())
            return int(m.group(1)) if m else None
    except OSError:
        return None


_latest = {"t": 0, "build": None}


def latest_build(max_age=900):
    if time.time() - _latest["t"] < max_age:
        return _latest["build"]
    _latest["t"] = time.time()
    try:
        req = urllib.request.Request("https://api.steamcmd.net/v1/info/730",
                                     headers={"User-Agent": "cs2-dashboard"})
        with urllib.request.urlopen(req, timeout=10) as r:
            d = json.load(r)
        app = d["data"]["730"]
        for section in ("depots", "config"):   # tolerate API layout changes
            pub = (app.get(section) or {}).get("branches", {}).get("public", {})
            if pub.get("buildid"):
                _latest["build"] = int(pub["buildid"])
                break
    except Exception:
        pass
    return _latest["build"]


def list_maps():
    names = set()
    for p in glob.glob(os.path.join(DATA, "game", "csgo", "maps", "*.vpk")):
        n = os.path.basename(p)[:-4]
        if re.match(r"^(de|cs|ar|dz|gd)_[a-z0-9_]+$", n) and not re.search(r"_(vanity|preview|lobby|\d+)$", n):
            names.add(n)
    return sorted(names) or FALLBACK_MAPS


def docker_logs(n=200):
    n = max(10, min(int(n), 2000))
    _, out = run(["docker", "logs", "--tail", str(n), CONTAINER], timeout=10)
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", out)


# ===================================================================== host metrics

class Host:
    def __init__(self):
        self.prev_cpu = None
        self.prev_net = None
        self.prev_udp = None
        self.iface = self._default_iface()

    @staticmethod
    def _default_iface():
        try:
            with open("/proc/net/route") as f:
                for line in f.readlines()[1:]:
                    p = line.split()
                    if p[1] == "00000000":
                        return p[0]
        except OSError:
            pass
        return None

    @staticmethod
    def _cpu_times():
        res = {}
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("cpu"):
                    p = line.split()
                    vals = list(map(int, p[1:9]))
                    idle = vals[3] + vals[4]
                    res[p[0]] = (sum(vals), idle)
        return res

    def sample(self):
        out = {"t": time.time()}
        cur = self._cpu_times()
        if self.prev_cpu:
            def pct(k):
                tot = cur[k][0] - self.prev_cpu[k][0]
                idle = cur[k][1] - self.prev_cpu[k][1]
                return round(100 * (tot - idle) / tot, 1) if tot > 0 else 0.0
            out["cpu"] = pct("cpu")
            cores = [pct(k) for k in cur if k != "cpu" and k in self.prev_cpu]
            out["cpu_cores"] = cores
            out["cpu_max_core"] = max(cores) if cores else 0.0
        self.prev_cpu = cur
        out["ncpu"] = len(cur) - 1

        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":")
                mem[k] = int(v.split()[0]) * 1024
        out["mem_total"] = mem.get("MemTotal", 0)
        out["mem_used"] = mem.get("MemTotal", 0) - mem.get("MemAvailable", 0)
        out["mem_pct"] = round(100 * out["mem_used"] / out["mem_total"], 1) if out["mem_total"] else 0
        out["swap_used"] = mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)

        path = DATA if os.path.isdir(DATA) else "/"
        st = os.statvfs(path)
        out["disk_total"] = st.f_blocks * st.f_frsize
        out["disk_used"] = (st.f_blocks - st.f_bfree) * st.f_frsize
        out["disk_pct"] = round(100 * out["disk_used"] / out["disk_total"], 1) if out["disk_total"] else 0

        try:
            with open("/proc/net/dev") as f:
                for line in f:
                    if self.iface and line.strip().startswith(self.iface + ":"):
                        p = line.split(":")[1].split()
                        net = (time.time(), int(p[0]), int(p[8]), int(p[1]), int(p[9]))
                        if self.prev_net:
                            dt = net[0] - self.prev_net[0]
                            out["net_rx"] = round((net[1] - self.prev_net[1]) / dt)
                            out["net_tx"] = round((net[2] - self.prev_net[2]) / dt)
                            out["pps_rx"] = round((net[3] - self.prev_net[3]) / dt)
                            out["pps_tx"] = round((net[4] - self.prev_net[4]) / dt)
                        self.prev_net = net
        except OSError:
            pass
        try:
            with open("/proc/net/snmp") as f:
                lines = [l.split() for l in f if l.startswith("Udp:")]
            hdr, val = lines[0], lines[1]
            u = dict(zip(hdr[1:], map(int, val[1:])))
            errs = u.get("InErrors", 0) + u.get("RcvbufErrors", 0)
            out["udp_errors"] = errs - self.prev_udp if self.prev_udp is not None else 0
            self.prev_udp = errs
        except (OSError, IndexError):
            pass
        out["load"] = [round(x, 2) for x in os.getloadavg()]
        with open("/proc/uptime") as f:
            out["uptime"] = int(float(f.read().split()[0]))
        return out


# ===================================================================== collector

class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.host = Host()
        self.latest_host = {}
        self.game = {"online": False}
        self.container = {}
        self.cstats = {}
        self.build = {}
        self.maps = []
        self.hist = {k: collections.deque(maxlen=HISTORY_POINTS)
                     for k in ("t", "cpu", "cpu_max_core", "mem_pct", "net_rx", "net_tx", "players", "ping")}
        self.events = collections.deque(maxlen=50)

    def event(self, msg):
        with self.lock:
            self.events.appendleft({"t": time.time(), "msg": msg})

    def loop(self):
        tick = 0
        while True:
            try:
                h = self.host.sample()
                if tick % 2 == 0:
                    self.poll_game()
                if tick % 6 == 0:
                    self.container = container_info()
                    self.cstats = container_stats() if self.container.get("state") == "running" else {}
                    self.maps = list_maps()
                if tick % 60 == 0:
                    lb = latest_build()
                    ib = installed_build()
                    self.build = {"installed": ib, "latest": lb,
                                  "update_available": bool(ib and lb and lb > ib)}
                with self.lock:
                    self.latest_host = h
                    if "cpu" in h:
                        humans = [p for p in self.game.get("players", []) if not p["bot"]]
                        self.hist["t"].append(int(h["t"]))
                        self.hist["cpu"].append(h["cpu"])
                        self.hist["cpu_max_core"].append(h["cpu_max_core"])
                        self.hist["mem_pct"].append(h["mem_pct"])
                        self.hist["net_rx"].append(h.get("net_rx", 0))
                        self.hist["net_tx"].append(h.get("net_tx", 0))
                        self.hist["players"].append(self.game.get("humans", 0) if self.game.get("online") else 0)
                        self.hist["ping"].append(round(sum(p["ping"] for p in humans) / len(humans)) if humans else None)
            except Exception as e:  # never let the collector die
                print("collector:", e, file=sys.stderr)
            tick += 1
            time.sleep(5)

    def poll_game(self):
        try:
            g = parse_status(RCON.command("status"))
            g["online"] = True
            g["error"] = None
        except RconError as e:
            g = {"online": False, "error": str(e), "players": []}
        was = self.game.get("online")
        self.game = g
        if was is not None and was != g["online"]:
            self.event("Game server is online" if g["online"] else f"Game server unreachable ({g['error']})")

    def snapshot(self):
        with self.lock:
            return {
                "now": time.time(),
                "host": self.latest_host,
                "game": self.game,
                "container": {**self.container, **self.cstats},
                "build": self.build,
                "maps": self.maps,
                "modes": list(MODES),
                "presets": list(PRESETS),
                "history": {k: list(v) for k, v in self.hist.items()},
                "events": list(self.events),
                "config": {
                    "servername": ENV.get("CS2_SERVERNAME", ""),
                    "ip": ENV.get("EXTERNAL_IP", ""),
                    "port": 27015,
                    "password": ENV.get("CS2_PW", ""),
                    "tv": ENV.get("TV_ENABLE") == "1",
                    "auto_update": ENV.get("AUTO_UPDATE", "1") == "1",
                },
            }


STATE = State()

# ===================================================================== actions

SAFE_MAP = re.compile(r"^[a-z0-9_]{2,64}$")


def clean_text(s, n=120):
    return re.sub(r'[;"\r\n\x00]', "", str(s))[:n].strip()


def spawn(cmd):
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def do_action(a):
    act = a.get("action")
    if act == "changelevel":
        m = a.get("map", "")
        if not SAFE_MAP.match(m):
            raise ValueError("invalid map name")
        return RCON.command(f"changelevel {m}")
    if act == "mode":
        mode, m = a.get("mode"), a.get("map", "")
        if mode not in MODES or not SAFE_MAP.match(m):
            raise ValueError("invalid mode or map")
        gt, gm = MODES[mode]
        return RCON.command(f"game_type {gt}; game_mode {gm}; changelevel {m}")
    if act == "workshop":
        wid = str(a.get("id", ""))
        if not wid.isdigit():
            raise ValueError("workshop id must be numeric")
        return RCON.command(f"host_workshop_map {wid}")
    if act == "preset":
        p = a.get("preset")
        if p not in PRESETS:
            raise ValueError("unknown preset")
        return RCON.command(PRESETS[p])
    simple = {"restart_round": "mp_restartgame 1", "end_warmup": "mp_warmup_end",
              "pause": "mp_pause_match", "unpause": "mp_unpause_match",
              "bot_add_t": "bot_add_t", "bot_add_ct": "bot_add_ct", "bot_kick": "bot_kick",
              "swap_teams": "mp_swapteams", "scramble": "mp_scrambleteams"}
    if act in simple:
        return RCON.command(simple[act])
    if act == "say":
        msg = clean_text(a.get("message", ""))
        if not msg:
            raise ValueError("empty message")
        return RCON.command(f"say {msg}")
    if act == "kick":
        uid = str(a.get("userid", ""))
        if not uid.isdigit():
            raise ValueError("invalid user id")
        return RCON.command(f"kickid {uid}")
    if act == "password":
        pw = str(a.get("password", ""))
        if not re.match(r"^[A-Za-z0-9_\-]{0,32}$", pw):
            raise ValueError("password: letters, digits, _ and - only")
        return RCON.command(f'sv_password "{pw}"') or "Join password changed until next restart."
    if act in ("container_restart", "container_stop", "container_start"):
        verb = act.split("_")[1]
        spawn(["docker", verb, CONTAINER])
        STATE.event(f"Container {verb} requested from dashboard")
        return f"docker {verb} {CONTAINER}: started"
    if act in ("update", "upgrade"):
        spawn(["/usr/local/bin/cs2ctl", act])
        STATE.event(f"{act.title()} requested from dashboard")
        return f"{act} started — the server restarts and reappears when done"
    raise ValueError("unknown action")


# ===================================================================== HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "cs2dash/1.0"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        if not isinstance(body, (bytes, bytearray)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if path == "/api/state":
            return self._send(200, STATE.snapshot())
        if path == "/api/logs":
            m = re.search(r"[?&]n=(\d+)", self.path)
            return self._send(200, {"logs": docker_logs(m.group(1) if m else 300)})
        if path == "/healthz":
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        # CSRF guard: browsers can't add custom headers cross-site without a preflight we never answer
        if self.headers.get("X-CS2-Dash") != "1":
            return self._send(403, {"error": "missing header"})
        origin = self.headers.get("Origin")
        host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host", "")
        if origin and origin.split("://", 1)[-1] != host:
            return self._send(403, {"error": "bad origin"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(min(n, 65536)) or b"{}")
        except ValueError:
            return self._send(400, {"error": "bad json"})
        try:
            if self.path == "/api/rcon":
                cmd = str(body.get("cmd", "")).strip()[:500]
                if not cmd:
                    return self._send(400, {"error": "empty command"})
                out = RCON.command(cmd)
                return self._send(200, {"output": out or "(no output)"})
            if self.path == "/api/action":
                out = do_action(body)
                threading.Thread(target=STATE.poll_game, daemon=True).start()
                return self._send(200, {"output": out or "OK"})
        except RconError as e:
            return self._send(503, {"error": f"Game server not reachable: {e}"})
        except ValueError as e:
            return self._send(400, {"error": str(e)})
        self._send(404, {"error": "not found"})


def serve():
    threading.Thread(target=STATE.loop, daemon=True).start()
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    httpd.daemon_threads = True
    print(f"cs2 dashboard on http://{LISTEN_HOST}:{LISTEN_PORT}", flush=True)
    httpd.serve_forever()


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "serve"
    if cmd == "serve":
        serve()
    elif cmd == "rcon":
        try:
            print(RCON.command(" ".join(argv[2:])))
        except RconError as e:
            print(f"RCON error: {e}", file=sys.stderr)
            return 1
    elif cmd == "status":
        try:
            g = parse_status(RCON.command("status"))
            g["online"] = True
        except RconError as e:
            g = {"online": False, "error": str(e)}
        g["build"] = {"installed": installed_build(), "latest": latest_build(0)}
        print(json.dumps(g, indent=2))
    elif cmd == "summary":
        ib, lb = installed_build(), latest_build(0)
        try:
            d = parse_status(RCON.command("status"))
            print(f"Game:      online · {d['hostname']} · map {d['map']}")
            print(f"Players:   {d['humans']} humans, {d['bots']} bots / {d['max']} max")
            for p in d["players"]:
                if not p["bot"]:
                    print(f"   #{p['id']:<3} {p['name'][:28]:<28} ping {p['ping']:>3}  loss {p['loss']}")
        except RconError as e:
            print(f"Game:      not answering yet ({e})")
        flag = "  <- update available" if ib and lb and lb > ib else ""
        print(f"Build:     installed {ib} · latest {lb}{flag}")
    elif cmd == "humans":
        try:
            print(parse_status(RCON.command("status"))["humans"])
        except RconError:
            print(-1)
    elif cmd == "builds":
        print(f"{installed_build() or 0} {latest_build(0) or 0}")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
