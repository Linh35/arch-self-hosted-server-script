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
#   3. Put this in cron or a systemd timer.

SCRIPT_NAME=backup
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_env

HERE="$REPO_ROOT"
DATA="$(storage_root)"   # the btrfs pool (or data/ if STORAGE_ROOT is unset)
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
  [[ -n "$(podman-compose -f "$HERE/compose/immich/docker-compose.yml" ps -q database 2>/dev/null)" ]]
}

if immich_db_running; then
  echo "Dumping Immich postgres"
  podman-compose -f "$HERE/compose/immich/docker-compose.yml" \
    exec -T database pg_dumpall --clean --if-exists -U postgres \
    | gzip > "$DUMPS/immich-postgres.sql.gz"
fi

pause_container() {
  local name=$1
  podman pause "$name" 2>/dev/null || true
}
unpause_container() {
  local name=$1
  podman unpause "$name" 2>/dev/null || true
}

cleanup() {
  unpause_container copyparty
}
trap cleanup EXIT

pause_container copyparty

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
