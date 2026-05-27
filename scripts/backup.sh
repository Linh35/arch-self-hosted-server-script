#!/usr/bin/env bash
set -euo pipefail

# Snapshot the selfhost data directory with restic.
#
# First-time setup:
#   1. Create ~/.config/selfhost-backup.env (chmod 600) with:
#        export RESTIC_REPOSITORY=b2:my-bucket:/selfhost
#        export RESTIC_PASSWORD='long-random-string'
#        export B2_ACCOUNT_ID=...
#        export B2_ACCOUNT_KEY=...
#      (or RESTIC_REPOSITORY=/mnt/usb/restic for a local disk)
#   2. Source it and run `restic init` once.
#   3. Drop this in cron / systemd timer.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DATA="$HERE/data"
DUMPS="$DATA/_dumps"
ENV_FILE="${SELFHOST_BACKUP_ENV:-$HOME/.config/selfhost-backup.env}"
LOCK="$HERE/.restic-lock"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing $ENV_FILE. See header of $0 for what to put in it." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Another backup is running (lock: $LOCK)." >&2
  exit 1
fi

mkdir -p "$DUMPS"

immich_db_running() {
  [[ -n "$(docker compose -f "$HERE/compose/immich/docker-compose.yml" ps -q database 2>/dev/null)" ]]
}

if immich_db_running; then
  echo "Dumping Immich postgres"
  docker compose -f "$HERE/compose/immich/docker-compose.yml" \
    exec -T database pg_dumpall --clean --if-exists -U postgres \
    | gzip > "$DUMPS/immich-postgres.sql.gz"
fi

pause_svc() {
  local svc=$1
  if [[ -d "$HERE/compose/$svc" ]]; then
    (cd "$HERE/compose/$svc" && docker compose pause 2>/dev/null) || true
  fi
}
unpause_svc() {
  local svc=$1
  if [[ -d "$HERE/compose/$svc" ]]; then
    (cd "$HERE/compose/$svc" && docker compose unpause 2>/dev/null) || true
  fi
}

cleanup() {
  unpause_svc jellyfin
  unpause_svc copyparty
}
trap cleanup EXIT

pause_svc jellyfin
pause_svc copyparty

echo "Running restic backup"
restic backup "$DATA" \
  --exclude "*/cache/*" \
  --exclude "*/transcodes/*" \
  --exclude "*/thumbs/*" \
  --tag selfhost

echo "Pruning old snapshots"
restic forget --prune \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6
