#!/usr/bin/env bash
set -uo pipefail

# Assertion-based unit tests for the selfhost scripts.
#
# Everything here runs through DRY_RUN=1, so no disk is touched, no package
# installed and no container started — the suite is safe to run on any machine
# (macOS, a CI box, or the Arch test container). It exercises the *real* code
# paths and checks behaviour, unlike scripts/test.sh which only lints + smoke
# tests. Run directly (`bash test/unit.sh`) or via `make test` / `make unit`.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
LIB="$REPO/scripts/lib.sh"

# Start from a clean slate: the parent suite (scripts/test.sh) exports DRY_RUN
# for its smoke layer, but each test below sets exactly the env it means to
# exercise, so a leaked value must not decide the outcome.
unset DRY_RUN ASSUME_YES STORAGE_ROOT

pass=0 fail=0
green() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
red()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
# Fall back to plain text when not a TTY (CI logs).
[[ -t 1 ]] || { green() { printf '  PASS %s\n' "$*"; }; red() { printf '  FAIL %s\n' "$*"; }; }

ok()  { pass=$((pass+1)); green "$1"; }
no()  { fail=$((fail+1)); red "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; }

assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi
}
assert_contains() { # desc haystack needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "[$3] not found in: $2"; fi
}
assert_not_contains() { # desc haystack needle
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "[$3] unexpectedly present in: $2"; fi
}
assert_status() { # desc expected_code actual_code
  if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected exit $2, got $3"; fi
}

# libsh "<code>" — source lib.sh in a clean subshell and run code, returning
# combined stdout+stderr. Prefix env vars on the call (DRY_RUN=1 libsh ...).
libsh() { bash -c "source '$LIB'; $1" 2>&1; }

section() { printf '\n--- %s ---\n' "$*"; }

# ---------------------------------------------------------------------------
section "lib.sh: run / DRY_RUN"

out=$(libsh 'run echo hello')
assert_eq "run executes the command when DRY_RUN unset" "hello" "$out"

out=$(DRY_RUN=1 libsh 'run echo hello')
assert_contains "run prints [dry-run] under DRY_RUN" "$out" "[dry-run]"
assert_contains "run echoes the command text under DRY_RUN" "$out" "echo hello"

# Prove dry-run does NOT actually run the command: it would create this file.
sentinel="$(mktemp -u)"
DRY_RUN=1 libsh "run touch '$sentinel'" >/dev/null
if [[ -e "$sentinel" ]]; then no "run does not execute under DRY_RUN" "file was created"; rm -f "$sentinel"; else ok "run does not execute under DRY_RUN"; fi

# ---------------------------------------------------------------------------
section "lib.sh: confirm / need / die"

out=$(DRY_RUN=1 libsh "confirm 'go?' && echo CONFIRMED")
assert_contains "confirm auto-yes under DRY_RUN" "$out" "CONFIRMED"
assert_contains "confirm notes [auto-yes]" "$out" "auto-yes"

out=$(ASSUME_YES=1 libsh "confirm 'go?' && echo CONFIRMED")
assert_contains "confirm auto-yes under ASSUME_YES" "$out" "CONFIRMED"

libsh 'need this_command_does_not_exist_xyz'; st=$?
assert_status "need fails for a missing command" 1 "$st"
out=$(libsh 'need this_command_does_not_exist_xyz')
assert_contains "need reports the missing command" "$out" "this_command_does_not_exist_xyz"

libsh 'need bash'; st=$?
assert_status "need succeeds for an installed command" 0 "$st"

out=$(libsh "die 'boom'"); st=$?
assert_status "die exits non-zero" 1 "$st"
assert_contains "die prints ERROR" "$out" "ERROR: boom"

# ---------------------------------------------------------------------------
section "lib.sh: storage_root / load_env"

out=$(libsh 'storage_root')
assert_eq "storage_root defaults to the in-repo data dir" "$REPO/data" "$out"

out=$(STORAGE_ROOT=/srv/storage libsh 'storage_root')
assert_eq "storage_root honours STORAGE_ROOT" "/srv/storage" "$out"

out=$(libsh 'load_env; printf "%s" "$TZ"')
assert_eq "load_env exports TZ from .env.example" "Europe/London" "$out"

# ---------------------------------------------------------------------------
section "storage.sh: argument validation (DRY_RUN)"

run_storage() { DRY_RUN=1 ASSUME_YES=1 ./scripts/storage.sh "$@" 2>&1; }

run_storage create /dev/sda >/dev/null 2>&1; st=$?
assert_status "create rejects a single device (RAID1 needs >=2)" 1 "$st"
out=$(run_storage create /dev/sda)
assert_contains "create explains the two-device minimum" "$out" "at least two"

out=$(run_storage create /dev/sda /dev/sdb); st=$?
assert_status "create accepts two devices in dry-run" 0 "$st"
assert_contains "create issues mkfs.btrfs" "$out" "mkfs.btrfs"
assert_contains "create uses raid1 for data+metadata" "$out" "raid1"
assert_contains "create mounts the pool at the storage root" "$out" "mount"
assert_contains "create persists an fstab entry by UUID" "$out" "fstab"

run_storage create-single >/dev/null 2>&1; st=$?
assert_status "create-single requires exactly one device" 1 "$st"
out=$(run_storage create-single /dev/sda); st=$?
assert_status "create-single accepts one device in dry-run" 0 "$st"
assert_contains "create-single issues mkfs.btrfs" "$out" "mkfs.btrfs"
assert_contains "create-single uses single data + dup metadata" "$out" "-m dup -d single"
assert_contains "create-single points to add for redundancy later" "$out" "add /dev/sdY"

run_storage add >/dev/null 2>&1; st=$?
assert_status "add requires exactly one device" 1 "$st"
out=$(run_storage add /dev/sdd)
assert_contains "add issues btrfs device add" "$out" "btrfs device add"
assert_contains "add rebalances to raid1" "$out" "balance start"

run_storage remove >/dev/null 2>&1; st=$?
assert_status "remove requires exactly one device" 1 "$st"

out=$(run_storage status); st=$?
assert_status "status succeeds in dry-run" 0 "$st"
assert_contains "status reports the storage root" "$out" "Storage root:"

run_storage bogus-command >/dev/null 2>&1; st=$?
assert_status "unknown storage command exits non-zero" 1 "$st"

# ---------------------------------------------------------------------------
section "manage.sh: dispatch (DRY_RUN)"

run_manage() { DRY_RUN=1 ./scripts/manage.sh "$@" 2>&1; }

out=$(run_manage up); st=$?
assert_status "up succeeds in dry-run" 0 "$st"
assert_contains "up calls podman-compose" "$out" "podman-compose"
assert_contains "up runs detached (-d)" "$out" "-d"
assert_contains "up iterates the navidrome stack" "$out" "navidrome"
assert_contains "up iterates the caddy proxy stack" "$out" "caddy"

out=$(run_manage down)
assert_not_contains "down does not pass -d" "$out" "podman-compose down -d"

run_manage logs >/dev/null 2>&1; st=$?
assert_status "logs with no service exits 1" 1 "$st"
out=$(run_manage logs)
assert_contains "logs lists available stacks" "$out" "available:"

run_manage frobnicate >/dev/null 2>&1; st=$?
assert_status "unknown manage command exits 1" 1 "$st"

# ---------------------------------------------------------------------------
section "bootstrap.sh: dry-run walk"

out=$(DRY_RUN=1 ./bootstrap.sh 2>&1); st=$?
assert_status "bootstrap completes in dry-run" 0 "$st"
assert_contains "bootstrap installs packages" "$out" "Installing packages"
assert_contains "bootstrap installs cloudflared" "$out" "Installing cloudflared"
assert_contains "bootstrap seeds .env files" "$out" ".env"
assert_contains "bootstrap enables rootless low-port binds" "$out" "ip_unprivileged_port_start"

# ---------------------------------------------------------------------------
section "backup.sh: guards"

out=$(SELFHOST_BACKUP_ENV="$(mktemp -u)" ./scripts/backup.sh 2>&1); st=$?
assert_status "backup aborts when its env file is missing" 1 "$st"
assert_contains "backup explains the missing env file" "$out" "Missing"

# ---------------------------------------------------------------------------
section "compose: invariants"

while IFS= read -r f; do
  name=$(basename "$(dirname "$f")")
  if grep -q 'STORAGE_ROOT' "$f"; then ok "$name compose pins data under STORAGE_ROOT"; else no "$name compose pins data under STORAGE_ROOT"; fi
done < <(find compose -mindepth 2 -maxdepth 2 -name docker-compose.yml | sort)

if grep -q '/music:/music:ro' compose/navidrome/docker-compose.yml; then
  ok "navidrome mounts the music library read-only"
else
  no "navidrome mounts the music library read-only"
fi

# ---------------------------------------------------------------------------
section "caddy: reverse proxy"

cf=compose/caddy/Caddyfile
for pair in "music:4533" "photos:2283" "files:3923" "books:8080" "read:8083"; do
  host=${pair%%:*} port=${pair##*:}
  if grep -q "^${host}.{\$DOMAIN}" "$cf" && grep -q "${port}" "$cf"; then
    ok "Caddyfile routes ${host}.\$DOMAIN to :${port}"
  else
    no "Caddyfile routes ${host}.\$DOMAIN to :${port}"
  fi
done

if grep -Eq '^[[:space:]]+dns cloudflare' "$cf"; then ok "Caddyfile defaults to publicly-trusted Cloudflare DNS certs"; else no "Caddyfile defaults to publicly-trusted Cloudflare DNS certs"; fi
if grep -Eq '^[[:space:]]*#[[:space:]]*tls internal' "$cf"; then ok "Caddyfile documents the internal-CA fallback"; else no "Caddyfile documents the internal-CA fallback"; fi
if grep -q 'reverse_proxy {$UPSTREAM_HOST}' "$cf"; then ok "Caddyfile proxies via the configurable upstream host"; else no "Caddyfile proxies via the configurable upstream host"; fi

cc=compose/caddy/docker-compose.yml
if grep -q 'host.containers.internal:host-gateway' "$cc"; then ok "caddy compose maps the host gateway"; else no "caddy compose maps the host gateway"; fi
if grep -Eq '"(80|443):(80|443)"' "$cc"; then ok "caddy compose publishes :80/:443"; else no "caddy compose publishes :80/:443"; fi
if grep -q 'CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN:-}' "$cc"; then ok "caddy compose keeps the Cloudflare token optional"; else no "caddy compose keeps the Cloudflare token optional"; fi

# ---------------------------------------------------------------------------
printf '\n=== %d passed, %d failed ===\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
