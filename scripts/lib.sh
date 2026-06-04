#!/usr/bin/env bash
# Shared helpers for the selfhost scripts. Source this file; do not run it.
#
# Provides:
#   log / warn / die      consistent, prefixed output
#   run CMD...            run a command, or just print it when DRY_RUN=1
#   need CMD              assert a command is installed
#   confirm "msg"        y/N prompt (auto-yes when ASSUME_YES=1 or DRY_RUN=1)
#   load_env             export vars from the shared root .env
#   storage_root         echo the configured STORAGE_ROOT (default /srv/storage)
#
# DRY_RUN=1  makes every `run` print instead of execute. The whole stack
# (bootstrap, manage, backup, storage) honours it, so you can exercise the
# real code paths on any machine without touching pacman/podman/disks.

# Resolve the repo root from this file's location, wherever it's sourced from.
SELFHOST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELFHOST_LIB_DIR/.." && pwd)"
export REPO_ROOT

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
: "${SCRIPT_NAME:=selfhost}"

log()  { printf '%s\n' "[$SCRIPT_NAME] $*"; }
warn() { printf '%s\n' "[$SCRIPT_NAME] WARNING: $*" >&2; }
die()  { printf '%s\n' "[$SCRIPT_NAME] ERROR: $*" >&2; exit 1; }

# run CMD... — execute the command, or in dry-run mode just print it.
# Note: this runs a single simple command. For pipelines, guard with
# `if [[ "$DRY_RUN" == 1 ]]` explicitly at the call site.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# need CMD — fail with a clear message if a required tool is missing.
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# confirm "message" — returns 0 if the user says yes. Auto-yes in dry-run or
# when ASSUME_YES=1, so scripts stay non-interactive in tests and automation.
confirm() {
  local msg=${1:-"Continue?"}
  if [[ "$DRY_RUN" == 1 || "$ASSUME_YES" == 1 ]]; then
    log "$msg [auto-yes]"
    return 0
  fi
  local reply
  read -r -p "$msg [y/N] " reply
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

# load_env — export vars from the shared root .env (falling back to the
# committed .env.example so dry-runs/tests work before setup).
load_env() {
  local f
  for f in "$REPO_ROOT/.env" "$REPO_ROOT/.env.example"; do
    if [[ -f "$f" ]]; then
      set -a
      # shellcheck source=/dev/null
      source "$f"
      set +a
      return 0
    fi
  done
}

# storage_root — where all service data lives. Override with STORAGE_ROOT in
# the root .env. Defaults to the in-repo data/ dir when unset, matching the
# compose files' own fallback, so a fresh checkout still works.
storage_root() {
  printf '%s\n' "${STORAGE_ROOT:-$REPO_ROOT/data}"
}
