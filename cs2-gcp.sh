#!/usr/bin/env bash
# =====================================================================
#  cs2-gcp.sh — deploy and manage a Counter-Strike 2 server on Google Cloud
#
#  Run from Google Cloud Shell (recommended) or any machine with gcloud + bash.
#  Usage:  ./cs2-gcp.sh <command> [args]      (./cs2-gcp.sh help)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CS2_CONF:-$SCRIPT_DIR/cs2.conf}"
VERSION="1.1.0"
REPO_URL="https://github.com/x2code-co/cs2-gcp-pelican-panel.git"

# ---------------------------------------------------------------- output helpers
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; C=""; N=""; fi
log()  { echo "${C}==>${N} ${B}$*${N}"; }
ok()   { echo "${G}  ✓${N} $*"; }
warn() { echo "${Y}  !${N} $*" >&2; }
die()  { echo "${R}  ✗ $*${N}" >&2; exit 1; }

usage() {
  cat <<EOF
${B}cs2-gcp ${VERSION}${N} — Counter-Strike 2 server on Google Cloud

${B}Setup${N}
  init            Create cs2.conf from the example and ask for the essentials
  preflight       Check gcloud, project, APIs, quota and machine availability
  deploy          Create/repair everything (network, firewall, IP, VM, snapshots) and install the server
  infra           Cloud resources only; then install on the VM with git clone + sudo ./vm-install.sh
  push            Re-upload config + server scripts and re-run the installer (after editing cs2.conf)

${B}Daily use${N}
  info            Connection string, dashboard URL and login
  status          VM state + game server status
  start | stop    Start / stop the VM (stopped VM = no compute charges; IP and disk are kept)
  restart         Restart the CS2 game container
  update          Update CS2 now (restarts the game)
  upgrade         Pull the newest server image and recreate the container
  rcon "<cmd>"    Run a console command, e.g.  ./cs2-gcp.sh rcon "changelevel de_mirage"
  logs [N]        Last N lines of game server log (default 200)
  ssh             Open a shell on the VM

${B}Maintenance${N}
  snapshot        Take an on-demand disk snapshot
  resize <type>   Change machine type, e.g. resize c3-highcpu-8 (VM restarts)
  destroy         Delete the VM, firewall rules, network, IP and snapshot policy

Config file: ${CONF}
EOF
}

# ---------------------------------------------------------------- config
load_conf() {
  [[ -f "$CONF" ]] || die "No config at $CONF. Run: ./cs2-gcp.sh init"
  # shellcheck disable=SC1090
  source "$CONF"
  [[ -n "${PROJECT_ID:-}" ]] || die "PROJECT_ID is empty in $CONF"
  : "${REGION:=us-south1}" "${ZONE:=us-south1-a}" "${INSTANCE_NAME:=cs2-server}"
  : "${MACHINE_TYPE:=c3-highcpu-4}" "${DISK_SIZE_GB:=100}" "${DISK_TYPE:=pd-balanced}"
  : "${NETWORK_TIER:=PREMIUM}" "${NETWORK_NAME:=cs2-net}" "${SUBNET_RANGE:=10.50.0.0/24}"
  : "${ADMIN_CIDR:=0.0.0.0/0}" "${SNAPSHOT_RETENTION_DAYS:=7}" "${SNAPSHOT_START_UTC:=09:00}"
  : "${TV_ENABLE:=0}" "${DASH_USER:=admin}" "${DASH_TLS:=auto}"
  SUBNET_NAME="${NETWORK_NAME}-${REGION}"
  IP_NAME="${INSTANCE_NAME}-ip"
  TAG="${INSTANCE_NAME}"
  POLICY_NAME="${INSTANCE_NAME}-daily"
  GC=(gcloud --project "$PROJECT_ID" --quiet)
  # When admin access is locked to your IP, reach SSH through Google's IAP tunnel instead
  SSH_FLAGS=()
  if [[ "${SSH_VIA_IAP:-auto}" == "1" || ( "${SSH_VIA_IAP:-auto}" == "auto" && "$ADMIN_CIDR" != "0.0.0.0/0" ) ]]; then
    SSH_FLAGS=(--tunnel-through-iap)
  fi
}

# set_conf KEY VALUE — rewrite one KEY="..." line in cs2.conf (portable, no sed -i)
set_conf() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$val" '
    BEGIN { done=0 }
    index($0, k"=") == 1 { print k"=\""v"\""; done=1; next }
    { print }
    END { if (!done) print k"=\""v"\"" }' "$CONF" >"$tmp"
  cat "$tmp" >"$CONF"; rm -f "$tmp"
  chmod 600 "$CONF"
}

gen_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-20}" || true; }

ensure_secrets() {
  if [[ -z "${CS2_RCONPW:-}" ]]; then CS2_RCONPW="$(gen_secret 24)"; set_conf CS2_RCONPW "$CS2_RCONPW"; ok "Generated RCON password"; fi
  if [[ -z "${DASH_PASSWORD:-}" ]]; then DASH_PASSWORD="$(gen_secret 20)"; set_conf DASH_PASSWORD "$DASH_PASSWORD"; ok "Generated dashboard password"; fi
  if [[ "${TV_ENABLE}" == "1" && -z "${TV_PW:-}" ]]; then TV_PW="$(gen_secret 12)"; set_conf TV_PW "$TV_PW"; fi
  for v in CS2_SERVERNAME CS2_PW CS2_RCONPW DASH_PASSWORD; do
    [[ "${!v:-}" != *'"'* && "${!v:-}" != *'$'* && "${!v:-}" != *'`'* ]] || die "$v must not contain \" \$ or \` characters"
  done
}

# ---------------------------------------------------------------- gcloud helpers
res_exists() { "${GC[@]}" "$@" >/dev/null 2>&1; }

static_ip() { "${GC[@]}" compute addresses describe "$IP_NAME" --region "$REGION" --format='value(address)' 2>/dev/null || true; }

vm_status() { "${GC[@]}" compute instances describe "$INSTANCE_NAME" --zone "$ZONE" --format='value(status)' 2>/dev/null || echo "NOT_FOUND"; }

vm_ssh() { "${GC[@]}" compute ssh "$INSTANCE_NAME" --zone "$ZONE" ${SSH_FLAGS[@]+"${SSH_FLAGS[@]}"} "$@"; }

remote() { vm_ssh --command "$*"; }

require_running() {
  local s; s="$(vm_status)"
  [[ "$s" == "RUNNING" ]] || die "VM is $s. Start it with: ./cs2-gcp.sh start"
}

# ---------------------------------------------------------------- commands
cmd_init() {
  if [[ -f "$CONF" ]]; then warn "$CONF already exists — editing values in place"; else cp "$SCRIPT_DIR/cs2.conf.example" "$CONF"; chmod 600 "$CONF"; ok "Created $CONF"; fi
  # shellcheck disable=SC1090
  source "$CONF"
  local def_project; def_project="$(gcloud config get-value project 2>/dev/null || true)"
  read -r -p "GCP project id [${PROJECT_ID:-$def_project}]: " a; a="${a:-${PROJECT_ID:-$def_project}}"; set_conf PROJECT_ID "$a"
  echo "Get a Game Server Login Token (app id 730) at https://steamcommunity.com/dev/managegameservers"
  read -r -p "Steam GSLT token [${SRCDS_TOKEN:+(keep current)}]: " a; [[ -n "$a" ]] && set_conf SRCDS_TOKEN "$a"
  read -r -p "Server name [${CS2_SERVERNAME}]: " a; [[ -n "$a" ]] && set_conf CS2_SERVERNAME "$a"
  read -r -p "Join password (empty = none) [${CS2_PW}]: " a; [[ -n "$a" ]] && set_conf CS2_PW "$a"
  read -r -p "Region [${REGION}]: " a; if [[ -n "$a" ]]; then set_conf REGION "$a"; set_conf ZONE "${a}-a"; fi
  ok "Saved. Review $CONF, then run: ./cs2-gcp.sh deploy"
}

# Verify the project is reachable; explain the usual causes when it isn't.
check_project() {
  local acct="$1" err
  if err="$("${GC[@]}" compute project-info describe --format='value(name)' 2>&1 >/dev/null)"; then
    ok "Project $PROJECT_ID"; return
  fi
  echo "${R}  ✗ Can't use project ${PROJECT_ID} as ${acct}${N}" >&2
  echo "    gcloud said: $(echo "$err" | grep -m1 -E 'ERROR|error' || echo "$err" | head -1)" >&2
  if [[ "$acct" == *-compute@developer.gserviceaccount.com || "$acct" == *.iam.gserviceaccount.com ]]; then
    cat >&2 <<EOT
    You're running this on a VM, logged in as its service account, which can't manage
    Compute Engine. cs2-gcp.sh is meant for Cloud Shell or your own computer.
      • On this VM, install the server directly instead:  sudo ./vm-install.sh
      • Or open Cloud Shell (>_ icon in console.cloud.google.com) and run cs2-gcp.sh there.
EOT
  elif echo "$err" | grep -qiE 'not found|does not exist|invalid'; then
    echo "    Check PROJECT_ID in cs2.conf — use the project ID, not its name or number." >&2
    echo "    Your projects: $(gcloud projects list --format='value(projectId)' 2>/dev/null | tr '\n' ' ')" >&2
  elif echo "$err" | grep -qiE 'billing'; then
    echo "    Link a billing account: https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}" >&2
  elif echo "$err" | grep -qiE 'has not been used|SERVICE_DISABLED|is disabled'; then
    log "Enabling Compute Engine API (takes ~1 min)"
    "${GC[@]}" services enable compute.googleapis.com && { ok "Project $PROJECT_ID"; return; }
  else
    echo "    ${acct} needs Owner or Compute Admin on ${PROJECT_ID}, or log in with: gcloud auth login" >&2
  fi
  exit 1
}

cmd_preflight() {
  load_conf
  log "Preflight"
  command -v gcloud >/dev/null || die "gcloud not found. Use Google Cloud Shell or install the Google Cloud CLI."
  local acct; acct="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
  [[ -n "$acct" ]] || die "Not logged in. Run: gcloud auth login"
  ok "Logged in as $acct"
  check_project "$acct"
  if ! "${GC[@]}" services list --enabled --filter='config.name=compute.googleapis.com' --format='value(config.name)' | grep -q compute; then
    log "Enabling Compute Engine API (first time takes ~1 min)"
    "${GC[@]}" services enable compute.googleapis.com
  fi
  ok "Compute Engine API enabled"
  if [[ ${#SSH_FLAGS[@]} -gt 0 ]]; then
    "${GC[@]}" services enable iap.googleapis.com >/dev/null 2>&1 || warn "Could not enable IAP API (needed for SSH when ADMIN_CIDR is restricted)"
    ok "SSH via IAP tunnel (ADMIN_CIDR is restricted)"
  fi
  if "${GC[@]}" compute machine-types describe "$MACHINE_TYPE" --zone "$ZONE" >/dev/null 2>&1; then
    ok "$MACHINE_TYPE available in $ZONE"
  else
    local zones; zones="$("${GC[@]}" compute machine-types list --filter="name=$MACHINE_TYPE AND zone~^$REGION" --format='value(zone)' | tr '\n' ' ')"
    die "$MACHINE_TYPE not offered in $ZONE. Zones in $REGION that have it: ${zones:-none}. Edit ZONE or MACHINE_TYPE in cs2.conf."
  fi
  if [[ "$MACHINE_TYPE" == c4* || "$MACHINE_TYPE" == n4* || "$MACHINE_TYPE" == c4d* ]] && [[ "$DISK_TYPE" != hyperdisk* ]]; then
    die "$MACHINE_TYPE requires DISK_TYPE=hyperdisk-balanced"
  fi
  local cpus; cpus="$("${GC[@]}" compute regions describe "$REGION" --format=json | python3 -c '
import json,sys
q={x["metric"]:x for x in json.load(sys.stdin)["quotas"]}
for m in ("CPUS","IN_USE_ADDRESSES","STATIC_ADDRESSES"):
    if m in q: print(m + "=" + str(int(q[m]["limit"] - q[m]["usage"])), end=" ")' 2>/dev/null || true)"
  [[ -n "$cpus" ]] && ok "Free regional quota: $cpus"
  [[ -n "${SRCDS_TOKEN:-}" ]] && ok "Steam token set" || warn "SRCDS_TOKEN empty — friends outside your network may not be able to join. Get one (app 730) at https://steamcommunity.com/dev/managegameservers"
  if [[ "$ADMIN_CIDR" == "0.0.0.0/0" ]]; then warn "ADMIN_CIDR is open to the internet (protected by keys/password). Restrict to your IP for best security."; fi
}

cmd_deploy() {
  cmd_infra
  wait_ssh
  install_remote
  cmd_info
  echo
  warn "First start downloads ~60 GB of game files (usually 10–25 min). Watch progress in the dashboard log or: ./cs2-gcp.sh logs"
}

# Cloud resources only (network, firewall, IP, VM, snapshots) — no software install.
# Use this when you want to install on the VM yourself with git clone + vm-install.sh.
cmd_infra() {
  cmd_preflight
  ensure_secrets

  log "Network"
  if ! res_exists compute networks describe "$NETWORK_NAME"; then
    "${GC[@]}" compute networks create "$NETWORK_NAME" --subnet-mode=custom >/dev/null; ok "Created VPC $NETWORK_NAME"
  else ok "VPC $NETWORK_NAME exists"; fi
  if ! res_exists compute networks subnets describe "$SUBNET_NAME" --region "$REGION"; then
    "${GC[@]}" compute networks subnets create "$SUBNET_NAME" --network "$NETWORK_NAME" --region "$REGION" --range "$SUBNET_RANGE" >/dev/null
    ok "Created subnet $SUBNET_NAME"
  else ok "Subnet $SUBNET_NAME exists"; fi

  log "Firewall"
  local game_rules="udp:27015"; [[ "$TV_ENABLE" == "1" ]] && game_rules+=",udp:27020"
  fw_rule "${INSTANCE_NAME}-game"  "$game_rules"        "0.0.0.0/0"
  fw_rule "${INSTANCE_NAME}-admin" "tcp:22,tcp:80,tcp:443" "$ADMIN_CIDR"
  fw_rule "${INSTANCE_NAME}-iap"   "tcp:22"            "35.235.240.0/20"

  log "Static IP (${NETWORK_TIER} tier)"
  if [[ -z "$(static_ip)" ]]; then
    "${GC[@]}" compute addresses create "$IP_NAME" --region "$REGION" --network-tier "$NETWORK_TIER" >/dev/null
  fi
  IP="$(static_ip)"; ok "Server IP: $IP"

  log "Virtual machine"
  if [[ "$(vm_status)" == "NOT_FOUND" ]]; then
    "${GC[@]}" compute instances create "$INSTANCE_NAME" --zone "$ZONE" \
      --machine-type "$MACHINE_TYPE" \
      --network-interface="network=$NETWORK_NAME,subnet=$SUBNET_NAME,address=$IP,network-tier=$NETWORK_TIER,nic-type=GVNIC" \
      --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
      --boot-disk-size="${DISK_SIZE_GB}GB" --boot-disk-type="$DISK_TYPE" --boot-disk-auto-delete \
      --tags="$TAG" \
      --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
      --maintenance-policy=MIGRATE --restart-on-failure \
      --labels=app=cs2 >/dev/null
    ok "Created $INSTANCE_NAME ($MACHINE_TYPE, ${DISK_SIZE_GB} GB $DISK_TYPE)"
  else
    [[ "$(vm_status)" == "RUNNING" ]] || { "${GC[@]}" compute instances start "$INSTANCE_NAME" --zone "$ZONE" >/dev/null; ok "Started VM"; }
    ok "VM $INSTANCE_NAME exists"
  fi

  if [[ "$SNAPSHOT_RETENTION_DAYS" != "0" ]]; then
    log "Daily snapshots (${SNAPSHOT_RETENTION_DAYS} days)"
    if ! res_exists compute resource-policies describe "$POLICY_NAME" --region "$REGION"; then
      "${GC[@]}" compute resource-policies create snapshot-schedule "$POLICY_NAME" --region "$REGION" \
        --max-retention-days "$SNAPSHOT_RETENTION_DAYS" --on-source-disk-delete keep-auto-snapshots \
        --daily-schedule --start-time "$SNAPSHOT_START_UTC" >/dev/null
    fi
    "${GC[@]}" compute disks add-resource-policies "$INSTANCE_NAME" --zone "$ZONE" --resource-policies "$POLICY_NAME" >/dev/null 2>&1 || true
    ok "Snapshot schedule attached"
  fi
}

cmd_infra_only() {
  cmd_infra
  echo
  ok "Cloud resources ready. VM IP: $(static_ip)"
  echo "  Next, on the VM:  ./cs2-gcp.sh ssh"
  echo "    git clone ${REPO_URL} cs2 && cd cs2 && sudo ./vm-install.sh"
}

fw_rule() {
  local name="$1" rules="$2" src="$3"
  if res_exists compute firewall-rules describe "$name"; then
    "${GC[@]}" compute firewall-rules update "$name" --rules "$rules" --source-ranges "$src" >/dev/null
    ok "Updated firewall $name ($rules from $src)"
  else
    "${GC[@]}" compute firewall-rules create "$name" --network "$NETWORK_NAME" --direction INGRESS \
      --action ALLOW --rules "$rules" --source-ranges "$src" --target-tags "$TAG" >/dev/null
    ok "Created firewall $name ($rules from $src)"
  fi
}

wait_ssh() {
  log "Waiting for SSH"
  local _
  for _ in $(seq 1 30); do
    if vm_ssh --command true -- -o ConnectTimeout=8 -o StrictHostKeyChecking=no >/dev/null 2>&1; then ok "SSH ready"; return; fi
    sleep 10
  done
  die "VM did not become reachable over SSH. Check ADMIN_CIDR / that your account can use IAP (roles/iap.tunnelResourceAccessor), then re-run deploy."
}

# Build a bundle (server files + VM env) and run the installer remotely
install_remote() {
  load_conf; IP="$(static_ip)"
  local tls="$DASH_TLS"
  if [[ "$tls" == "auto" && "$ADMIN_CIDR" != "0.0.0.0/0" ]]; then
    tls="internal"; warn "ADMIN_CIDR is restricted, so Let's Encrypt can't validate; using a self-signed certificate"
  fi
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/cs2"
  cp -r "$SCRIPT_DIR/server/." "$tmp/cs2/"
  {
    echo "# generated by cs2-gcp.sh $(date -u +%FT%TZ)"
    for k in SRCDS_TOKEN CS2_SERVERNAME CS2_PW CS2_RCONPW CS2_MAXPLAYERS CS2_GAMEALIAS CS2_STARTMAP CS2_MAPGROUP \
             CS2_BOT_QUOTA CS2_BOT_DIFFICULTY CS2_ADDITIONAL_ARGS TV_ENABLE TV_AUTORECORD TV_PW CS2_IMAGE \
             STEAMAPPVALIDATE DASH_USER DASH_PASSWORD DASH_DOMAIN AUTO_UPDATE UPDATE_FORCE_AFTER_MIN WATCHDOG; do
      printf '%s="%s"\n' "$k" "${!k:-}"
    done
    printf 'DASH_TLS="%s"\nEXTERNAL_IP="%s"\n' "$tls" "$IP"
  } >"$tmp/cs2/cs2.env"
  chmod 600 "$tmp/cs2/cs2.env"
  tar -C "$tmp" -czf "$tmp/cs2-bundle.tgz" cs2
  log "Uploading and installing (Docker, server, dashboard, tuning)"
  "${GC[@]}" compute scp "$tmp/cs2-bundle.tgz" "$INSTANCE_NAME:/tmp/cs2-bundle.tgz" --zone "$ZONE" ${SSH_FLAGS[@]+"${SSH_FLAGS[@]}"} >/dev/null
  rm -rf "$tmp"
  remote "sudo rm -rf /tmp/cs2 && sudo tar -C /tmp -xzf /tmp/cs2-bundle.tgz && sudo bash /tmp/cs2/install.sh /tmp/cs2/cs2.env && sudo rm -rf /tmp/cs2 /tmp/cs2-bundle.tgz"
  ok "Server installed"
}

cmd_push() { load_conf; ensure_secrets; require_running; install_remote; }

cmd_info() {
  load_conf
  local ip; ip="$(static_ip)"
  [[ -n "$ip" ]] || die "No static IP yet — run deploy"
  local domain="${DASH_DOMAIN:-${ip//./-}.sslip.io}"
  echo
  echo "${B}Counter-Strike 2 server${N}"
  echo "  Connect (in-game console):  ${G}connect ${ip}:27015${CS2_PW:+; password ${CS2_PW}}${N}"
  echo "  One-click (paste in browser): steam://connect/${ip}:27015${CS2_PW:+/${CS2_PW}}"
  [[ "$TV_ENABLE" == "1" ]] && echo "  CSTV:                       connect ${ip}:27020"
  echo "${B}Dashboard${N}"
  echo "  URL:   https://${domain}   (fallback: https://${ip} — accept the self-signed warning)"
  echo "  Login: ${DASH_USER} / ${DASH_PASSWORD}"
  echo "${B}VM${N}  ${INSTANCE_NAME} · ${MACHINE_TYPE} · ${ZONE} · $(vm_status)"
}

cmd_status() {
  load_conf
  local s; s="$(vm_status)"; echo "VM: $s"
  [[ "$s" == "RUNNING" ]] && remote "sudo cs2ctl status" || true
}

cmd_start() {
  load_conf
  "${GC[@]}" compute instances start "$INSTANCE_NAME" --zone "$ZONE" >/dev/null
  ok "VM started. The game server comes up automatically in ~1–2 min (longer if an update is pending)."
  cmd_info
}

cmd_stop() {
  load_conf
  "${GC[@]}" compute instances stop "$INSTANCE_NAME" --zone "$ZONE" >/dev/null
  ok "VM stopped. You pay only for disk + reserved IP while stopped."
}

cmd_resize() {
  load_conf
  local mt="${1:-}"; [[ -n "$mt" ]] || die "Usage: resize <machine-type>"
  "${GC[@]}" compute machine-types describe "$mt" --zone "$ZONE" >/dev/null 2>&1 || die "$mt not available in $ZONE"
  local was; was="$(vm_status)"
  [[ "$was" == "RUNNING" ]] && { log "Stopping VM"; "${GC[@]}" compute instances stop "$INSTANCE_NAME" --zone "$ZONE" >/dev/null; }
  "${GC[@]}" compute instances set-machine-type "$INSTANCE_NAME" --zone "$ZONE" --machine-type "$mt" >/dev/null
  set_conf MACHINE_TYPE "$mt"; ok "Machine type is now $mt"
  if [[ "$was" == "RUNNING" ]]; then "${GC[@]}" compute instances start "$INSTANCE_NAME" --zone "$ZONE" >/dev/null; ok "VM started"; fi
}

cmd_snapshot() {
  load_conf
  local name; name="${INSTANCE_NAME}-manual-$(date -u +%Y%m%d-%H%M%S)"
  "${GC[@]}" compute disks snapshot "$INSTANCE_NAME" --zone "$ZONE" --snapshot-names "$name" >/dev/null
  ok "Snapshot $name created"
}

cmd_destroy() {
  load_conf
  warn "This deletes VM $INSTANCE_NAME (and its disk), firewall rules, network $NETWORK_NAME, IP $IP_NAME and the snapshot policy."
  warn "Existing snapshots are kept (delete them in the console if you don't need them)."
  read -r -p "Type the instance name to confirm: " a
  [[ "$a" == "$INSTANCE_NAME" ]] || die "Aborted"
  "${GC[@]}" compute instances delete "$INSTANCE_NAME" --zone "$ZONE" 2>/dev/null && ok "VM deleted" || true
  for r in game admin iap; do "${GC[@]}" compute firewall-rules delete "${INSTANCE_NAME}-$r" 2>/dev/null && ok "Firewall ${INSTANCE_NAME}-$r deleted" || true; done
  "${GC[@]}" compute resource-policies delete "$POLICY_NAME" --region "$REGION" 2>/dev/null && ok "Snapshot policy deleted" || true
  "${GC[@]}" compute addresses delete "$IP_NAME" --region "$REGION" 2>/dev/null && ok "IP released" || true
  "${GC[@]}" compute networks subnets delete "$SUBNET_NAME" --region "$REGION" 2>/dev/null && ok "Subnet deleted" || true
  "${GC[@]}" compute networks delete "$NETWORK_NAME" 2>/dev/null && ok "Network deleted" || true
}

# ---------------------------------------------------------------- dispatch
cmd="${1:-help}"; shift || true
case "$cmd" in
  init)       cmd_init ;;
  preflight)  cmd_preflight ;;
  deploy)     cmd_deploy ;;
  infra)      cmd_infra_only ;;
  push)       cmd_push ;;
  info)       cmd_info ;;
  status)     cmd_status ;;
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  restart)    load_conf; require_running; remote "sudo cs2ctl restart" ;;
  update)     load_conf; require_running; remote "sudo cs2ctl update" ;;
  upgrade)    load_conf; require_running; remote "sudo cs2ctl upgrade" ;;
  rcon)       load_conf; require_running; [[ $# -gt 0 ]] || die 'Usage: rcon "<command>"'; remote "sudo cs2ctl rcon $(printf '%q' "$*")" ;;
  logs)       load_conf; require_running; remote "sudo cs2ctl logs ${1:-200}" ;;
  ssh)        load_conf; vm_ssh ;;
  snapshot)   cmd_snapshot ;;
  resize)     cmd_resize "${1:-}" ;;
  destroy)    cmd_destroy ;;
  help|-h|--help) usage ;;
  *) usage; die "Unknown command: $cmd" ;;
esac
