#!/usr/bin/env bash
# =====================================================================
#  CS2 server installer (idempotent — safe to re-run)
#  Works on Ubuntu 22.04/24.04 and Debian 12, on GCP or any x86_64 Linux VM.
#
#  Usage: sudo bash install.sh /path/to/cs2.env
#  Installs: Docker, CS2 (joedwards32/cs2, host networking), Caddy (HTTPS + auth),
#            the cs2 dashboard, cs2ctl, auto-update + watchdog timers, OS tuning.
# =====================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_IN="${1:-$SRC_DIR/cs2.env}"
BASE=/opt/cs2

say() { echo -e "\e[36m==>\e[0m \e[1m$*\e[0m"; }
ok()  { echo -e "\e[32m  ✓\e[0m $*"; }
die() { echo -e "\e[31m  ✗ $*\e[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)"
[[ -f "$ENV_IN" ]] || die "Config not found: $ENV_IN"
[[ "$(uname -m)" == "x86_64" ]] || die "CS2 dedicated server needs x86_64"

mkdir -p "$BASE"/{data,state,dashboard,caddy/data,caddy/config}

# set_kv FILE KEY VALUE — replace or append KEY="VALUE"
set_kv() {
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" 'BEGIN{d=0} index($0,k"=")==1{print k"=\""v"\"";d=1;next}{print} END{if(!d)print k"=\""v"\""}' "$f" >"$tmp"
  cat "$tmp" >"$f"; rm -f "$tmp"
}
gen_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-20}" || true; }

# shellcheck disable=SC1090
source "$ENV_IN"
# Generate missing secrets and save them back to the caller's config (VM-side installs)
if [[ -z "${CS2_RCONPW:-}" ]];    then CS2_RCONPW="$(gen_secret 24)";    set_kv "$ENV_IN" CS2_RCONPW "$CS2_RCONPW"; ok "Generated RCON password"; fi
if [[ -z "${DASH_PASSWORD:-}" ]]; then DASH_PASSWORD="$(gen_secret 20)"; set_kv "$ENV_IN" DASH_PASSWORD "$DASH_PASSWORD"; ok "Generated dashboard password"; fi
if [[ -z "${EXTERNAL_IP:-}" ]]; then
  EXTERNAL_IP="$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null \
    || curl -fsS https://api.ipify.org 2>/dev/null || true)"
fi
# Let's Encrypt can't validate when admin ports are locked to one IP
if [[ "${DASH_TLS:-auto}" == "auto" && -n "${ADMIN_CIDR:-}" && "${ADMIN_CIDR}" != "0.0.0.0/0" ]]; then DASH_TLS="internal"; fi

if [[ "$(realpath "$ENV_IN")" != "$BASE/cs2.env" ]]; then install -m 600 "$ENV_IN" "$BASE/cs2.env"; fi
chmod 600 "$ENV_IN"
set_kv "$BASE/cs2.env" EXTERNAL_IP "$EXTERNAL_IP"
set_kv "$BASE/cs2.env" DASH_TLS "${DASH_TLS:-auto}"

: "${CS2_IMAGE:=joedwards32/cs2:latest}" "${DASH_USER:=admin}" "${DASH_TLS:=auto}"
: "${CS2_MAXPLAYERS:=12}" "${CS2_STARTMAP:=de_dust2}" "${CS2_MAPGROUP:=mg_active}" "${TV_ENABLE:=0}"

# ---------------------------------------------------------------- packages
say "System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl jq python3 unattended-upgrades chrony >/dev/null
# Security updates only, never auto-reboot mid-match
cat >/etc/apt/apt.conf.d/52cs2-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
systemctl enable --now unattended-upgrades chrony >/dev/null 2>&1 || true
ok "Packages installed (unattended security updates on, no auto-reboot)"

# ---------------------------------------------------------------- docker
say "Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
EOF
systemctl enable docker >/dev/null 2>&1
systemctl restart docker
docker compose version >/dev/null || die "docker compose plugin missing"
ok "$(docker --version)"

# ---------------------------------------------------------------- OS tuning
say "OS tuning for a UDP game server"
cat >/etc/sysctl.d/90-cs2.conf <<'EOF'
# Larger socket buffers: fewer dropped UDP packets during bursts
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.netdev_max_backlog = 5000
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
# Fair queueing; BBR for TCP traffic (dashboard, downloads)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# Keep the game in RAM
vm.swappiness = 10
fs.file-max = 1048576
EOF
modprobe tcp_bbr 2>/dev/null || true
sysctl --system >/dev/null
# Swap guards against OOM during big SteamCMD updates on 8 GB machines
if ! swapon --show | grep -q /swapfile; then
  if [[ ! -f /swapfile ]]; then fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null; fi
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi
ok "sysctl + 4 GB swap"

# ---------------------------------------------------------------- game env + compose
say "CS2 server container"
q() { local v="${1//\'/}"; printf "'%s'" "$v"; }           # single-quoted, literal for compose
esc() { local v="${1//\//\\/}"; printf '%s' "$v"; }          # image needs / escaped as \/
{
  echo "SRCDS_TOKEN=$(q "${SRCDS_TOKEN:-}")"
  echo "CS2_SERVERNAME=$(q "$(esc "${CS2_SERVERNAME:-CS2}")")"
  echo "CS2_PW=$(q "${CS2_PW:-}")"
  echo "CS2_RCONPW=$(q "$CS2_RCONPW")"
  echo "CS2_MAXPLAYERS=$(q "$CS2_MAXPLAYERS")"
  echo "CS2_GAMEALIAS=$(q "${CS2_GAMEALIAS:-}")"
  echo "CS2_STARTMAP=$(q "$CS2_STARTMAP")"
  echo "CS2_MAPGROUP=$(q "$CS2_MAPGROUP")"
  echo "CS2_BOT_QUOTA=$(q "${CS2_BOT_QUOTA:-}")"
  echo "CS2_BOT_DIFFICULTY=$(q "${CS2_BOT_DIFFICULTY:-}")"
  echo "CS2_ADDITIONAL_ARGS=$(q "$(esc "${CS2_ADDITIONAL_ARGS:-}")")"
  echo "CS2_IP='0.0.0.0'"
  echo "CS2_PORT='27015'"
  echo "CS2_SERVER_HIBERNATE='0'"
  echo "CS2_LAN='0'"
  echo "CS2_LOG='on'"
  echo "TV_ENABLE=$(q "$TV_ENABLE")"
  echo "TV_AUTORECORD=$(q "${TV_AUTORECORD:-0}")"
  echo "TV_PW=$(q "${TV_PW:-}")"
  echo "STEAMAPPVALIDATE=$(q "${STEAMAPPVALIDATE:-0}")"
} >"$BASE/game.env"
chmod 600 "$BASE/game.env"
chown 1000:1000 "$BASE/data"

cat >"$BASE/docker-compose.yml" <<EOF
# Managed by install.sh — edit cs2.conf and run ./cs2-gcp.sh push instead.
services:
  cs2:
    image: ${CS2_IMAGE}
    container_name: cs2
    network_mode: host          # no Docker NAT in the packet path
    env_file: game.env
    volumes:
      - ./data:/home/steam/cs2-dedicated
    restart: unless-stopped
    stop_grace_period: 30s
    stdin_open: true
    tty: true
    ulimits:
      nofile: { soft: 65535, hard: 65535 }
  caddy:
    image: caddy:2
    container_name: cs2-caddy
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
    restart: unless-stopped
EOF
ok "Compose file written"

# ---------------------------------------------------------------- caddy (HTTPS + basic auth)
say "Dashboard web front (Caddy)"
docker pull -q caddy:2 >/dev/null
HASH="$(docker run --rm caddy:2 caddy hash-password --plaintext "$DASH_PASSWORD")"
DOMAIN="${DASH_DOMAIN:-}"
[[ -z "$DOMAIN" && -n "$EXTERNAL_IP" ]] && DOMAIN="${EXTERNAL_IP//./-}.sslip.io"
SITE_BODY="	encode gzip
	basic_auth {
		${DASH_USER} ${HASH}
	}
	reverse_proxy 127.0.0.1:8088
	header {
		X-Frame-Options DENY
		X-Content-Type-Options nosniff
		Referrer-Policy no-referrer
	}"
{
  echo "{"
  [[ -n "$EXTERNAL_IP" ]] && echo "	default_sni ${EXTERNAL_IP}"
  echo "}"
  if [[ -n "$DOMAIN" ]]; then
    echo "${DOMAIN} {"
    [[ "$DASH_TLS" == "internal" ]] && echo "	tls internal"
    echo "$SITE_BODY"
    echo "}"
  fi
  if [[ -n "$EXTERNAL_IP" ]]; then
    echo "https://${EXTERNAL_IP} {"
    echo "	tls internal"
    echo "$SITE_BODY"
    echo "}"
  fi
} >"$BASE/Caddyfile"
chmod 644 "$BASE/Caddyfile"
ok "HTTPS for ${DOMAIN:-<no domain>} (${DASH_TLS}) and https://${EXTERNAL_IP}"

# ---------------------------------------------------------------- dashboard + cs2ctl
say "Dashboard + cs2ctl"
install -m 755 "$SRC_DIR/dashboard/app.py" "$BASE/dashboard/app.py"
install -m 644 "$SRC_DIR/dashboard/index.html" "$BASE/dashboard/index.html"
install -m 755 "$SRC_DIR/cs2ctl" /usr/local/bin/cs2ctl

cat >/etc/systemd/system/cs2-dashboard.service <<'EOF'
[Unit]
Description=CS2 dashboard (API on 127.0.0.1:8088, served via Caddy)
After=docker.service network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/cs2/dashboard/app.py serve
Restart=always
RestartSec=3
Nice=5

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/cs2-stack.service <<'EOF'
[Unit]
Description=CS2 server stack (docker compose)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/cs2
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

for unit in autoupdate:10min watchdog:2min; do
  name="${unit%%:*}"; every="${unit##*:}"
  cat >"/etc/systemd/system/cs2-${name}.service" <<EOF
[Unit]
Description=CS2 ${name}
After=cs2-stack.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cs2ctl ${name}
EOF
  cat >"/etc/systemd/system/cs2-${name}.timer" <<EOF
[Unit]
Description=Run CS2 ${name} every ${every}

[Timer]
OnBootSec=5min
OnUnitActiveSec=${every}
RandomizedDelaySec=20

[Install]
WantedBy=timers.target
EOF
done

systemctl daemon-reload
systemctl enable --now cs2-dashboard.service >/dev/null 2>&1
systemctl restart cs2-dashboard.service
systemctl enable cs2-stack.service >/dev/null 2>&1
systemctl enable --now cs2-autoupdate.timer cs2-watchdog.timer >/dev/null 2>&1
ok "Services and timers enabled"

# ---------------------------------------------------------------- start
say "Starting stack (first run downloads the server image and ~60 GB of game files)"
cd "$BASE"
docker compose pull -q
docker compose up -d --remove-orphans
docker compose restart caddy >/dev/null   # pick up Caddyfile changes
systemctl start cs2-stack.service
ok "Running. Check progress with: cs2ctl logs   |   cs2ctl status"
