#!/usr/bin/env bash
set -euo pipefail

# Manage the btrfs RAID1 storage pool that holds all service data.
#
# Why btrfs RAID1: real-time redundancy (every block on two devices, so any
# one disk can die without data loss), self-healing via checksums, and you
# can grow it online by just adding a disk — even a mismatched size. It's in
# the mainline kernel, so nothing to babysit across Arch kernel updates.
# Usable capacity is roughly half the raw total (the cost of the mirror).
#
# The pool is mounted at STORAGE_ROOT (see the root .env; default /srv/storage)
# and every compose stack stores its data underneath it.
#
# Usage:
#   sudo ./scripts/storage.sh status                 show pool + devices + usage
#   sudo ./scripts/storage.sh create /dev/sdX /dev/sdY [/dev/sdZ ...]
#                                                    make a new RAID1 pool (WIPES disks)
#   sudo ./scripts/storage.sh create-single /dev/sdX make a 1-disk pool now, no
#                                                    redundancy yet (WIPES disk);
#                                                    'add' a 2nd disk later -> RAID1
#   sudo ./scripts/storage.sh add /dev/sdZ           add a disk and grow the pool
#   sudo ./scripts/storage.sh remove /dev/sdZ        shrink the pool off a disk
#   sudo ./scripts/storage.sh scrub                  verify + self-heal checksums
#   sudo ./scripts/storage.sh health                 device error counters + scrub state
#
# Honours DRY_RUN=1 (print, don't execute) and ASSUME_YES=1 (no prompts).

SCRIPT_NAME=storage
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_env

ROOT="$(storage_root)"

require_root() {
  if [[ "$DRY_RUN" != 1 && $EUID -ne 0 ]]; then
    die "this needs root (it touches block devices and mounts). Re-run with sudo."
  fi
}

require_btrfs() {
  # In dry-run we only print commands, so the tool need not be installed.
  if [[ "$DRY_RUN" != 1 ]]; then
    need btrfs
  fi
}

# Refuse to operate on a device that looks like it already holds something,
# unless the operator insists. Cheap guard against nuking the wrong disk.
assert_blank() {
  local dev=$1
  [[ -b "$dev" || "$DRY_RUN" == 1 ]] || die "not a block device: $dev"
  if [[ "$DRY_RUN" != 1 ]] && command -v lsblk >/dev/null 2>&1; then
    local sig
    sig=$(lsblk -no FSTYPE,MOUNTPOINT "$dev" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$sig" && "$ASSUME_YES" != 1 ]]; then
      warn "$dev appears to be in use / formatted:"
      lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$dev" >&2 || true
      confirm "Use $dev anyway? Existing data on it will be DESTROYED." \
        || die "aborted on $dev"
    fi
  fi
}

is_mounted() { mountpoint -q "$ROOT" 2>/dev/null; }

cmd_status() {
  require_btrfs
  log "Storage root: $ROOT"
  if is_mounted || [[ "$DRY_RUN" == 1 ]]; then
    run btrfs filesystem show "$ROOT"
    run btrfs filesystem usage "$ROOT"
  else
    warn "$ROOT is not a mounted btrfs pool yet. Run 'create' to make one."
  fi
}

# _finish_pool <primary-dev> — mount the freshly made pool at ROOT and persist
# it in /etc/fstab by UUID so it survives device reordering across reboots.
# Shared by create (RAID1) and create-single.
_finish_pool() {
  local primary=$1
  run mkdir -p "$ROOT"
  run mount "$primary" "$ROOT"

  if [[ "$DRY_RUN" == 1 ]]; then
    printf '  [dry-run] add btrfs UUID mount for %s to /etc/fstab\n' "$ROOT"
  else
    local uuid
    uuid=$(blkid -s UUID -o value "$primary")
    if ! grep -q "$uuid" /etc/fstab 2>/dev/null; then
      printf 'UUID=%s  %s  btrfs  defaults,compress=zstd:3  0 0\n' "$uuid" "$ROOT" >> /etc/fstab
      log "Added $ROOT to /etc/fstab (UUID=$uuid)"
    fi
  fi
}

cmd_create() {
  require_root; require_btrfs
  [[ $# -ge 2 ]] || die "create needs at least two devices for RAID1, e.g. create /dev/sdb /dev/sdc"
  local devs=("$@")
  log "About to create a btrfs RAID1 pool across: ${devs[*]}"
  log "Mount point: $ROOT"
  warn "Every listed disk will be WIPED."
  confirm "Proceed?" || die "aborted"

  local d
  for d in "${devs[@]}"; do assert_blank "$d"; done

  # -f to overwrite any stale signature; data+metadata both mirrored.
  run mkfs.btrfs -f -m raid1 -d raid1 "${devs[@]}"
  _finish_pool "${devs[0]}"
  log "Pool created. Point STORAGE_ROOT=$ROOT in the root .env, then ./scripts/manage.sh up"
}

cmd_create_single() {
  require_root; require_btrfs
  [[ $# -eq 1 ]] || die "create-single takes exactly one device, e.g. create-single /dev/sdb"
  local dev=$1
  log "About to create a single-disk btrfs pool on: $dev"
  log "Mount point: $ROOT"
  warn "$dev will be WIPED, and this pool has NO redundancy until you add a second disk."
  confirm "Proceed?" || die "aborted"

  assert_blank "$dev"

  # Data is single-copy (no second disk to mirror to yet), but metadata is DUP
  # so btrfs can still self-heal checksummed metadata on the one disk. Wire a
  # second disk later and `storage.sh add` rebalances to full RAID1.
  run mkfs.btrfs -f -m dup -d single "$dev"
  _finish_pool "$dev"
  log "Single-disk pool ready. Point STORAGE_ROOT=$ROOT in the root .env, then ./scripts/manage.sh up"
  log "Add redundancy later: sudo ./scripts/storage.sh add /dev/sdY  (converts the pool to RAID1)"
}

cmd_add() {
  require_root; require_btrfs
  [[ $# -eq 1 ]] || die "add takes exactly one device, e.g. add /dev/sdd"
  local dev=$1
  is_mounted || [[ "$DRY_RUN" == 1 ]] || die "$ROOT is not a mounted pool. Use 'create' first."
  log "Adding $dev to the pool at $ROOT and rebalancing to RAID1."
  assert_blank "$dev"

  run btrfs device add -f "$dev" "$ROOT"
  # Rebalance so the new disk shares the mirror — keeps redundancy as it grows.
  run btrfs balance start -dconvert=raid1 -mconvert=raid1 "$ROOT"
  log "Done. Capacity grew and the pool is still RAID1. Check with: storage.sh status"
}

cmd_remove() {
  require_root; require_btrfs
  [[ $# -eq 1 ]] || die "remove takes exactly one device, e.g. remove /dev/sdd"
  local dev=$1
  is_mounted || [[ "$DRY_RUN" == 1 ]] || die "$ROOT is not a mounted pool."
  warn "btrfs will move that disk's data onto the others first; this can take a while."
  confirm "Remove $dev from the pool at $ROOT?" || die "aborted"
  run btrfs device remove "$dev" "$ROOT"
  log "Removed $dev."
}

cmd_scrub() {
  require_root; require_btrfs
  is_mounted || [[ "$DRY_RUN" == 1 ]] || die "$ROOT is not a mounted pool."
  log "Scrubbing $ROOT (reads every block, repairs from the mirror on checksum errors)."
  run btrfs scrub start -B "$ROOT"
}

cmd_health() {
  require_btrfs
  is_mounted || [[ "$DRY_RUN" == 1 ]] || die "$ROOT is not a mounted pool."
  run btrfs device stats "$ROOT"
  run btrfs scrub status "$ROOT"
}

usage() {
  sed -n '3,30p' "$0"
  exit "${1:-1}"
}

cmd=${1:-}
shift || true
case "$cmd" in
  status)  cmd_status "$@" ;;
  create)  cmd_create "$@" ;;
  create-single) cmd_create_single "$@" ;;
  add)     cmd_add "$@" ;;
  remove)  cmd_remove "$@" ;;
  scrub)   cmd_scrub "$@" ;;
  health)  cmd_health "$@" ;;
  ""|-h|--help) usage 0 ;;
  *) warn "unknown command: $cmd"; usage 1 ;;
esac
