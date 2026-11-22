# cs2-gcp — Counter-Strike 2 server on Google Cloud, with a web dashboard

Scripts that build a tuned CS2 dedicated server on a Google Cloud VM and manage it day to day: live stats, player list, map/mode changes, RCON console, logs, automatic updates, a crash watchdog, an idle auto-stop that shuts the VM down when nobody is playing, and phone/Discord notifications when it goes up or down.

**Stack (all open source):** Ubuntu 24.04 · Docker · [`joedwards32/cs2`](https://github.com/joedwards32/CS2) game image (MIT) · [Caddy](https://caddyserver.com) for HTTPS + login · built-in dashboard (Python standard library). Pelican Panel was evaluated and not used: it is built for multi-server hosting and adds a database, Wings daemon and eggs that one server doesn't need (see `docs/USER_GUIDE.md`).

Full guide: [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md)

## Two ways to install

### A. Everything from Cloud Shell (one command)

```bash
git clone https://github.com/sakith-x2code/cs2-gcp-pelican-panel.git cs2-gcp
cd cs2-gcp
./cs2-gcp.sh init      # project id, Steam GSLT token, server name, join password
./cs2-gcp.sh deploy    # network, firewall, static IP, VM, snapshots + server install
./cs2-gcp.sh info      # connect string, dashboard URL and login
```

### B. Create the VM, then pull and run on the VM

```bash
# In Cloud Shell: cloud resources only (network, firewall, static IP, VM, snapshots)
git clone https://github.com/sakith-x2code/cs2-gcp-pelican-panel.git cs2-gcp
cd cs2-gcp && ./cs2-gcp.sh init && ./cs2-gcp.sh infra
./cs2-gcp.sh ssh

# On the VM:
sudo apt-get install -y git
git clone https://github.com/sakith-x2code/cs2-gcp-pelican-panel.git cs2
cd cs2 && sudo ./vm-install.sh     # asks for the Steam token etc., then installs
```

Already have a VM? It needs Ubuntu 22.04/24.04 or Debian 12 (x86_64), 4 vCPU / 8 GB / 100 GB, and firewall rules for **UDP 27015** (everyone) and **TCP 80, 443** (your admin IP). Then run the "On the VM" part.

The first start downloads ~60 GB of game files (10–25 min): `sudo cs2ctl logs -f`.

### No terminal? Use SSH in the browser

In the Cloud Console, open **Compute Engine → VM instances**, click **SSH** on `cs2-server` (click **Start** first if it's stopped), then run the "On the VM" commands above. Updates, settings and `sudo cs2ctl …` commands all work there. Step-by-step: [Using SSH in the browser](docs/USER_GUIDE.md#using-ssh-in-the-browser).

## Updating

| Where you installed from | Update scripts/dashboard and apply config changes |
|---|---|
| Cloud Shell (A) | `git pull && ./cs2-gcp.sh push` |
| On the VM (B) | `cd ~/cs2 && git pull && sudo ./vm-install.sh` |

CS2 game updates install automatically when the server is empty. Your settings live in `cs2.conf`, which is git-ignored and survives `git pull`.

## Idle auto-stop

The VM **stops itself after 60 minutes with no players**, so a forgotten server doesn't keep billing.

- A systemd timer (`cs2-idlecheck.timer`) runs `cs2ctl idlecheck` every 5 minutes. After `IDLE_SHUTDOWN_MIN` minutes with 0 human players (bots don't count), it powers off the VM.
- This is a **stop, not a delete**: Google Cloud shows the VM as `TERMINATED`, but the disk, game files, settings and static IP are kept and compute billing ends. Start it again with `./cs2-gcp.sh start` (or **Start** in the Cloud Console); each boot gets a fresh hour.
- The countdown resets while a player is connected, while anyone is logged in over SSH, and during CS2 downloads/updates. A server that isn't answering counts as empty.
- The dashboard shows "VM stops in ~N min". On the VM:

```bash
sudo cs2ctl idle           # time left
sudo cs2ctl idle hold      # pause until the next reboot
sudo cs2ctl idle resume    # turn it back on
```

Settings in `cs2.conf` (apply with `./cs2-gcp.sh push` or `sudo ./vm-install.sh`):

| Setting | Default | Meaning |
|---|---|---|
| `IDLE_SHUTDOWN` | `1` | `0` turns idle auto-stop off |
| `IDLE_SHUTDOWN_MIN` | `60` | minutes with no players before the VM stops (minimum 10) |

## Phone notifications

Get a push on your phone when the server comes online (with the connect address), goes down, updates, or stops, plus a warning 10 minutes before idle auto-stop. Uses the free, open-source [ntfy](https://ntfy.sh) app; a Discord channel webhook works too.

1. Install **ntfy** (Android / iPhone), tap **+** and subscribe to a long random topic, e.g. `cs2-sakith-7Kq2pX9d`.
2. In `cs2.conf` set `NOTIFY_NTFY_TOPIC="cs2-sakith-7Kq2pX9d"` (and/or `NOTIFY_DISCORD_WEBHOOK="https://discord.com/api/webhooks/…"`).
3. Apply with `sudo ./vm-install.sh` on the VM (or `./cs2-gcp.sh push`), then test: `sudo cs2ctl notify test`.

Details: [Phone notifications](docs/USER_GUIDE.md#phone-notifications).

## Commands

From Cloud Shell (`./cs2-gcp.sh help`):

| Command | What it does |
|---|---|
| `init` / `preflight` | create config / check project, APIs, quota, machine availability |
| `deploy` | create or repair all cloud resources and install the server |
| `infra` | cloud resources only (for install path B) |
| `push` | apply `cs2.conf` changes and updated scripts to the VM |
| `info`, `status` | connection details · live status |
| `start`, `stop` | start / stop the VM (it also stops itself after 60 min with no players) |
| `restart`, `update`, `upgrade` | restart game · install CS2 update · pull newest image |
| `rcon "<cmd>"`, `logs [N]`, `ssh` | console command · server log · shell |
| `snapshot`, `resize <type>`, `destroy` | manual backup · change VM size · remove everything |

On the VM (`sudo cs2ctl help`): `status`, `start`, `stop`, `restart`, `update`, `upgrade`, `rcon`, `say`, `logs [-f]`, `console`, `config`, `idle [status|hold|resume]`, `notify test`.

## Repository layout

```
cs2-gcp.sh            Cloud Shell CLI (gcloud: network, firewall, IP, VM, snapshots, remote ops)
vm-install.sh         run ON the VM: first-time setup or update from this checkout
cs2.conf.example      every setting, documented (copy to cs2.conf; git-ignored)
server/install.sh     idempotent installer: Docker, OS tuning, CS2 container, Caddy, dashboard, timers
server/cs2ctl         on-VM management CLI + auto-update / watchdog / idle auto-stop / notification jobs
server/dashboard/     web dashboard (app.py API + index.html UI)
docs/USER_GUIDE.md    installation, specifications, setup, operations, troubleshooting
```

## Default server

c3-highcpu-4 (4 vCPU, 8 GB) in us-south1 (Dallas), 100 GB balanced disk, Premium network tier, static IP, live migration, daily snapshots kept 7 days. Change any of it in `cs2.conf`.

## License

MIT — see [LICENSE](LICENSE).
