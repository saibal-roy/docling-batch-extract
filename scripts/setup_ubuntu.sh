#!/usr/bin/env bash
# Prepare an Ubuntu 26.04 LTS server (the latest LTS, the only supported release) to run the extractor.
#
# Usage (as the user that will own the service, not root; sudo is used where needed):
#   scripts/setup_ubuntu.sh [--cron-minutes N] [--no-cron]
#
#   --cron-minutes N   run extract.py every N minutes from cron (default 5)
#   --no-cron          don't install the cron entry
#   --resize           recompute .env (workers/threads/memory) even if it exists
#   --force            continue on an unsupported Ubuntu release (not tested)
#
# Steps: check the OS and resources → install Docker Engine (official apt repo), Python venv,
# cron and flock → create the venv and data folders → pull and start the docling container and
# wait for /health → install the cron entry. Safe to run again: each step skips what is
# already done.
#
# DOCLING_URL (default http://localhost:5001) is where the health check reaches the service;
# set it when the service isn't on localhost (e.g. running this inside a container).
set -euo pipefail

CRON_MINUTES=5
INSTALL_CRON=1
RESIZE=0
FORCE=0
while [ $# -gt 0 ]; do
  case $1 in
    --cron-minutes) CRON_MINUTES=$2; shift 2 ;;
    --no-cron) INSTALL_CRON=0; shift ;;
    --resize) RESIZE=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONTAINER=docling_ocr_worker_cpu
URL=${DOCLING_URL:-http://localhost:5001}
CRON_MARKER="# docling-batch-extract"
step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

[ -f "$ROOT/extract.py" ] && [ -f "$ROOT/docker-compose.yml" ] || { echo "Run this from the repository (extract.py not found in $ROOT)" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "Run as the user that will own the service, not root (sudo is used where needed)." >&2; exit 1; }

step "Checking the system"
. /etc/os-release
[ "${ID:-}" = ubuntu ] || { echo "This script supports Ubuntu only (found: ${PRETTY_NAME:-unknown})." >&2; exit 1; }
SUPPORTED=26.04   # policy: only the latest Ubuntu LTS is supported and tested
if [ "${VERSION_ID:-}" != "$SUPPORTED" ]; then
  [ "$FORCE" -eq 1 ] || { echo "Ubuntu $SUPPORTED LTS is the supported release (found ${VERSION_ID:-unknown}); rerun with --force to continue untested." >&2; exit 1; }
  warn "Ubuntu ${VERSION_ID:-unknown} is not supported (only $SUPPORTED LTS); continuing because of --force"
fi
CPUS=$(nproc)
MEM_GB=$(awk '/MemTotal/ { printf "%.1f", $2 / 1048576 }' /proc/meminfo)
DISK_GB=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
echo "Ubuntu $VERSION_ID · $CPUS CPUs · ${MEM_GB} GB RAM · ${DISK_GB} GB free disk · $(uname -m)"
[ "$CPUS" -ge 2 ] || warn "2 vCPU minimum (validated target: 2 vCPU / 8 GB)"
awk -v m="$MEM_GB" 'BEGIN { exit !(m < 7.5) }' && warn "8 GB RAM recommended (container limit is 6.5 GB)"
[ "$DISK_GB" -ge 20 ] || warn "20 GB free disk recommended (the image alone is ~5.2 GB)"

step "Installing packages (Docker Engine, Python venv, flock)"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  sudo apt-get update -q
  sudo apt-get install -yq ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -q
  sudo apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "Docker already installed: $(docker --version)"
fi
sudo apt-get install -yq python3-venv python3-pip util-linux curl cron >/dev/null
if [ -d /run/systemd/system ]; then
  sudo systemctl enable --now docker cron >/dev/null
else
  # No systemd (e.g. inside a container): the Docker daemon must already be reachable.
  warn "systemd not running: not enabling services; Docker must already be available"
fi

# The script and cron read `docker stats`/`docker inspect`, so the user needs the docker group.
# Group membership applies to new logins; this script itself uses sudo for docker meanwhile.
if id -nG "$USER" | grep -qw docker; then DOCKER="docker"; else
  sudo usermod -aG docker "$USER"
  DOCKER="sudo docker"
  warn "added $USER to the docker group: log out and back in before running extract.py by hand"
fi

step "Python environment"
cd "$ROOT"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt
mkdir -p inputs outputs completed errors logs
echo "venv ready: $(.venv/bin/python --version)"

step "Sizing docling-serve for this machine (.env)"
# Profiles measured with tests/profile_benchmark.sh (README: "Server specification and capacity").
if [ -f .env ] && [ "$RESIZE" -eq 0 ]; then
  echo "keeping existing .env (run with --resize to recompute):"; sed 's/^/  /' .env
else
  if [ "$CPUS" -le 2 ]; then WORKERS=1; THREADS=2      # 2 vCPU / 8 GB target profile
  else WORKERS=$((CPUS / 2)); THREADS=2; fi            # 2 threads per worker
  MEM_MB=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
  LIMIT_MB=$(( (MEM_MB - 1536) / 100 * 100 ))         # leave ~1.5 GB for the OS and extract.py
  [ "$LIMIT_MB" -ge 4000 ] || warn "only ${LIMIT_MB} MB left for the container; 6500 MB recommended"
  printf '# Written by scripts/setup_ubuntu.sh for %s CPUs / %s GB RAM. Edit, or rerun with --resize.\nDOCLING_WORKERS=%s\nDOCLING_THREADS=%s\nDOCLING_MEMORY=%sM\n' \
    "$CPUS" "$MEM_GB" "$WORKERS" "$THREADS" "$LIMIT_MB" > .env
  sed 's/^/  /' .env
fi

step "Starting docling-serve (first pull downloads ~2.2 GB)"
$DOCKER compose -f "$ROOT/docker-compose.yml" up -d
printf 'Waiting for /health'
for _ in $(seq 1 120); do
  if curl -sf -m 3 "$URL/health" >/dev/null; then echo " ok"; break; fi
  printf '.'; sleep 5
done
curl -sf -m 3 "$URL/health" >/dev/null || { echo; echo "docling-serve did not become healthy; check: $DOCKER compose logs" >&2; exit 1; }
$DOCKER stats --no-stream --format 'Container memory: {{.MemUsage}}' $CONTAINER

if [ "$INSTALL_CRON" -eq 1 ]; then
  step "Installing cron entry (every $CRON_MINUTES min)"
  LINE="*/$CRON_MINUTES * * * * cd $ROOT && DOCLING_URL=$URL flock -n /tmp/docling-batch-extract.lock .venv/bin/python extract.py >/dev/null 2>&1 $CRON_MARKER"
  ( crontab -l 2>/dev/null | grep -v "$CRON_MARKER" || true; echo "$LINE" ) | crontab -
  crontab -l | grep "$CRON_MARKER"
fi

step "Done"
cat <<EOF
Drop PDFs into:   $ROOT/inputs/
Results:          $ROOT/outputs/   (PDFs move to completed/ or errors/)
Per-PDF logs:     $ROOT/logs/
Run now by hand:  cd $ROOT && .venv/bin/python extract.py
Service status:   docker compose ps · curl $URL/health
Remove cron:      crontab -l | grep -v '$CRON_MARKER' | crontab -

Security: never open port 5001 in a firewall or cloud security group; the service has no
authentication. Use an SSH tunnel to reach it: ssh -L 5001:localhost:5001 <user>@<server>
EOF
