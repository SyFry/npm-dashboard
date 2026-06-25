#!/usr/bin/env bash
# Tear down the stack. Add --purge to also delete stored data (Loki logs, Grafana state).
set -euo pipefail
cd "$(dirname "$0")"
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"
if [ "${1:-}" = "--purge" ]; then
  $DOCKER compose down -v
  echo "Stack and all data volumes removed."
else
  $DOCKER compose down
  echo "Stack stopped. Data volumes kept (use --purge to delete them)."
fi
