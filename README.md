# cs2-gcp — Counter-Strike 2 server on Google Cloud, with a web dashboard

Scripts that build a tuned CS2 dedicated server on a Google Cloud VM and manage it day to day: live stats, player list, map/mode changes, RCON console, logs, automatic updates and a crash watchdog.

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

## Updating

| Where you installed from | Update scripts/dashboard and apply config changes |
|---|---|
| Cloud Shell (A) | `git pull && ./cs2-gcp.sh push` |
| On the VM (B) | `cd ~/cs2 && git pull && sudo ./vm-install.sh` |

CS2 game updates install automatically when the server is empty. Your settings live in `cs2.conf`, which is git-ignored and survives `git pull`.

## Commands

From Cloud Shell (`./cs2-gcp.sh help`):

| Command | What it does |
|---|---|
| `init` / `preflight` | create config / check project, APIs, quota, machine availability |
| `deploy` | create or repair all cloud resources and install the server |
| `infra` | cloud resources only (for install path B) |
| `push` | apply `cs2.conf` changes and updated scripts to the VM |
| `info`, `status` | connection details · live status |
| `start`, `stop` | start / stop the VM (stop when not playing to save money) |
| `restart`, `update`, `upgrade` | restart game · install CS2 update · pull newest image |
| `rcon "<cmd>"`, `logs [N]`, `ssh` | console command · server log · shell |
| `snapshot`, `resize <type>`, `destroy` | manual backup · change VM size · remove everything |

On the VM (`sudo cs2ctl help`): `status`, `start`, `stop`, `restart`, `update`, `upgrade`, `rcon`, `say`, `logs [-f]`, `console`, `config`.

## Repository layout

```
cs2-gcp.sh            Cloud Shell CLI (gcloud: network, firewall, IP, VM, snapshots, remote ops)
vm-install.sh         run ON the VM: first-time setup or update from this checkout
cs2.conf.example      every setting, documented (copy to cs2.conf; git-ignored)
server/install.sh     idempotent installer: Docker, OS tuning, CS2 container, Caddy, dashboard, timers
server/cs2ctl         on-VM management CLI + auto-update / watchdog jobs
server/dashboard/     web dashboard (app.py API + index.html UI)
docs/USER_GUIDE.md    installation, specifications, setup, operations, troubleshooting
```

## Default server

c3-highcpu-4 (4 vCPU, 8 GB) in us-south1 (Dallas), 100 GB balanced disk, Premium network tier, static IP, live migration, daily snapshots kept 7 days. Change any of it in `cs2.conf`.

## License

MIT — see [LICENSE](LICENSE).
