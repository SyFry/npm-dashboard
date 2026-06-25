#!/usr/bin/env bash
#
# npm-dashboard installer.
# Brings up Loki + Grafana Alloy + Grafana (each in its own container) and
# auto-provisions a Loki datasource + the NPM traffic/stats dashboard.
#
# Usage:
#   ./setup.sh                       # autodetect everything, start the stack
#   ./setup.sh --log-dir /path/logs  # force the NPM access-log directory
#   ./setup.sh --backfill            # also ingest existing log history (not just new lines)
#   ./setup.sh --help
#
set -euo pipefail
cd "$(dirname "$0")"

c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_0='\033[0m'
log(){  printf "${c_g}[+]${c_0} %s\n" "$*"; }
warn(){ printf "${c_y}[!]${c_0} %s\n" "$*"; }
die(){  printf "${c_r}[x]${c_0} %s\n" "$*" >&2; exit 1; }

BACKFILL=0
LOG_DIR_OVERRIDE="${NPM_LOG_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --backfill) BACKFILL=1 ;;
    --log-dir)  shift; LOG_DIR_OVERRIDE="${1:-}" ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

# ---- prerequisites -------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine first."
docker compose version >/dev/null 2>&1 || die "The 'docker compose' v2 plugin is required."
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
[ "$DOCKER" = "sudo docker" ] && warn "Using sudo for docker (your user isn't in the docker group)."

# ---- locate NPM access logs ---------------------------------------------
# Strategy: explicit override > running NPM container's /data mount >
#           common host paths > filesystem search.
detect_log_dir() {
  local p src cid img hit

  if [ -n "$LOG_DIR_OVERRIDE" ]; then echo "$LOG_DIR_OVERRIDE"; return 0; fi

  # 2) any running container whose image looks like NPM -> read its /data mount
  if $DOCKER ps -q >/dev/null 2>&1; then
    for cid in $($DOCKER ps -q); do
      img="$($DOCKER inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)"
      case "$img" in
        *nginx-proxy-manager*|*nginxproxymanager*)
          src="$($DOCKER inspect -f '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ .Source }}{{ end }}{{ end }}' "$cid" 2>/dev/null || true)"
          if [ -n "$src" ] && [ -d "$src/logs" ]; then echo "$src/logs"; return 0; fi
          ;;
      esac
    done
  fi

  # 3) common host install paths (Docker, Synology, unRAID, etc.)
  shopt -s nullglob
  local candidates=(
    /opt/nginx-proxy-manager/data/logs
    /opt/npm/data/logs
    /opt/docker/nginx-proxy-manager/data/logs
    ./data/logs
    /home/*/nginx-proxy-manager/data/logs
    /srv/nginx-proxy-manager/data/logs
    /volume1/docker/nginx-proxy-manager/data/logs
    /mnt/user/appdata/NginxProxyManager*/data/logs
    /var/lib/docker/volumes/*nginx*proxy*manager*/_data/logs
    /var/lib/docker/volumes/*npm*/_data/logs
  )
  shopt -u nullglob
  # pass 1: prefer a dir that actually contains access logs
  for p in "${candidates[@]}"; do
    compgen -G "$p/proxy-host-*_access.log" >/dev/null 2>&1 && { echo "$p"; return 0; }
  done
  # pass 2: an existing dir (logs may simply not exist yet)
  for p in "${candidates[@]}"; do [ -d "$p" ] && { echo "$p"; return 0; }; done

  # 4) last resort: search likely roots for the access-log filename
  hit="$(find /opt /home /srv /volume1 /mnt /var/lib/docker/volumes -maxdepth 6 \
           -type f -name 'proxy-host-*_access.log' 2>/dev/null | head -n1 || true)"
  [ -n "$hit" ] && { dirname "$hit"; return 0; }

  return 1
}

LOG_DIR="$(detect_log_dir || true)"
[ -n "$LOG_DIR" ] || die "Couldn't locate NPM's access logs. Re-run with: ./setup.sh --log-dir /path/to/nginx-proxy-manager/data/logs"
LOG_DIR="$(cd "$LOG_DIR" 2>/dev/null && pwd || echo "$LOG_DIR")"   # absolutize
log "NPM access logs: $LOG_DIR"
if ! compgen -G "$LOG_DIR/proxy-host-*_access.log" >/dev/null 2>&1; then
  warn "No proxy-host-*_access.log here yet — Alloy will pick them up once a proxy host serves traffic."
fi

# ---- .env (preserve existing password; generate on first run) -----------
if [ -f .env ]; then
  log "Reusing existing .env"
  # refresh just the log dir line
  if grep -q '^NPM_LOG_DIR=' .env; then
    sed -i "s#^NPM_LOG_DIR=.*#NPM_LOG_DIR=$LOG_DIR#" .env
  else
    printf '\nNPM_LOG_DIR=%s\n' "$LOG_DIR" >> .env
  fi
  GRAFANA_PW="$(grep '^GRAFANA_ADMIN_PASSWORD=' .env | cut -d= -f2-)"
else
  GRAFANA_PW="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-20 || echo changeme$RANDOM)"
  cat > .env <<ENV
NPM_LOG_DIR=$LOG_DIR
GRAFANA_PORT=3000
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=$GRAFANA_PW
LOKI_VERSION=3.4.0
ALLOY_VERSION=v1.9.2
GRAFANA_VERSION=11.6.0
ENV
  chmod 600 .env
  log "Wrote .env (Grafana admin password generated)"
fi

# ---- optional backfill of existing history ------------------------------
if [ "$BACKFILL" -eq 1 ]; then
  log "Backfill requested: reading existing logs from the start."
  sed -i 's/tail_from_end = true/tail_from_end = false/' config/config.alloy
  $DOCKER compose stop alloy >/dev/null 2>&1 || true
  $DOCKER compose rm -f alloy >/dev/null 2>&1 || true
  $DOCKER volume rm npm-dashboard_alloy-data >/dev/null 2>&1 || true
fi

# ---- launch --------------------------------------------------------------
log "Pulling images..."
$DOCKER compose pull || die "Image pull failed. Adjust *_VERSION in .env and re-run: $DOCKER compose up -d"
log "Starting stack..."
$DOCKER compose up -d

# ---- summary -------------------------------------------------------------
PORT="$(grep '^GRAFANA_PORT=' .env | cut -d= -f2-)"; PORT="${PORT:-3000}"
echo
log "Done. Grafana is starting up."
echo "  URL:       http://<this-host>:$PORT      (dashboard: NPM / 'Nginx Proxy Manager — Traffic & Stats')"
echo "  Login:     admin / $GRAFANA_PW"
if command -v hostname >/dev/null 2>&1; then
  ips="$(hostname -I 2>/dev/null || true)"
  [ -n "$ips" ] && echo "  Host IPs:  $ips"
fi
echo
echo "  Manage:    docker compose [ps|logs -f|restart|down]"
echo "  Backfill:  ./setup.sh --backfill"
