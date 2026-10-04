#!/usr/bin/env bash
# =====================================================================
#  vm-install.sh — install or update the CS2 server ON the VM from this git checkout
#
#    git clone https://github.com/sakith-x2code/cs2-gcp-pelican-panel.git cs2
#    cd cs2 && sudo ./vm-install.sh            # first run asks a few questions
#
#  Update later:   cd cs2 && git pull && sudo ./vm-install.sh
#  Config lives in ./cs2.conf (git-ignored, never committed).
# =====================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-$DIR/cs2.conf}"

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

set_kv() {
  local f="$1" k="$2" v="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$k" -v v="$v" 'BEGIN{d=0} index($0,k"=")==1{print k"=\""v"\"";d=1;next}{print} END{if(!d)print k"=\""v"\""}' "$f" >"$tmp"
  cat "$tmp" >"$f"; rm -f "$tmp"
}

if [[ ! -f "$CONF" ]]; then
  cp "$DIR/cs2.conf.example" "$CONF"
  chmod 600 "$CONF"
  echo "Created $CONF"
  if [[ -t 0 ]]; then
    echo "Steam Game Server Login Token (app id 730): https://steamcommunity.com/dev/managegameservers"
    read -r -p "Steam GSLT token: " a;                [[ -n "$a" ]] && set_kv "$CONF" SRCDS_TOKEN "$a"
    read -r -p "Server name [Friends CS2]: " a;        [[ -n "$a" ]] && set_kv "$CONF" CS2_SERVERNAME "$a"
    read -r -p "Join password (empty = none): " a;     [[ -n "$a" ]] && set_kv "$CONF" CS2_PW "$a"
    read -r -p "Admin IP/CIDR for dashboard+SSH [0.0.0.0/0]: " a; [[ -n "$a" ]] && set_kv "$CONF" ADMIN_CIDR "$a"
  else
    echo "Non-interactive: edit $CONF (at least SRCDS_TOKEN), then re-run."
  fi
fi

# shellcheck disable=SC1090
source "$CONF"
[[ -n "${SRCDS_TOKEN:-}" ]] || echo "  ! SRCDS_TOKEN is empty — players outside this network may not be able to join."
for v in CS2_SERVERNAME CS2_PW CS2_RCONPW DASH_PASSWORD; do
  [[ "${!v:-}" != *'"'* && "${!v:-}" != *'$'* && "${!v:-}" != *'`'* ]] || { echo "$v must not contain \" \$ or \`"; exit 1; }
done

bash "$DIR/server/install.sh" "$CONF"

# shellcheck disable=SC1091
source /opt/cs2/cs2.env
domain="${DASH_DOMAIN:-${EXTERNAL_IP//./-}.sslip.io}"
cat <<EOF

Counter-Strike 2 server
  Connect:    connect ${EXTERNAL_IP}:27015${CS2_PW:+; password ${CS2_PW}}
  One-click:  steam://connect/${EXTERNAL_IP}:27015${CS2_PW:+/${CS2_PW}}
Dashboard
  URL:        https://${domain}   (fallback: https://${EXTERNAL_IP})
  Login:      ${DASH_USER:-admin} / ${DASH_PASSWORD}
Manage:       sudo cs2ctl help

First start downloads ~60 GB of game files (10–25 min). Follow it with: sudo cs2ctl logs -f
Firewall: the VM needs UDP 27015 open to everyone and TCP 80/443 open to your admin IP
(./cs2-gcp.sh infra from Cloud Shell creates these rules).
EOF
