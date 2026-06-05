#!/usr/bin/env bash
set -uo pipefail

# Test the selfhost scripts and compose files without touching real disks,
# packages, or containers. Safe to run anywhere — the script-execution checks
# use DRY_RUN so nothing is actually installed, mounted, or started.
#
# Layers:
#   1. bash -n        syntax check on every shell script
#   2. shellcheck     static analysis (skipped with a note if not installed)
#   3. compose        validate each docker-compose.yml parses
#   4. dry-run        walk bootstrap / storage / manage / backup code paths
#
# Run locally with `make test`, or in a real Arch environment with
# `make test-container` (works on macOS via `podman machine`).

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
note() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  ok: %s\n' "$*"; }
bad()  { printf '  FAIL: %s\n' "$*"; fail=1; }

scripts=(scripts/lib.sh scripts/storage.sh scripts/manage.sh scripts/backup.sh scripts/test.sh test/unit.sh bootstrap.sh)

note "syntax (bash -n)"
for f in "${scripts[@]}"; do
  if bash -n "$f"; then ok "$f"; else bad "$f"; fi
done

note "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning -x "${scripts[@]}"; then ok "shellcheck clean"; else bad "shellcheck reported issues"; fi
else
  printf '  skipped: shellcheck not installed\n'
fi

note "compose validation"
while IFS= read -r c; do
  d=$(dirname "$c")
  if (
    cd "$d"
    # Provide the vars the compose files mark as required, so validation
    # doesn't trip on `${VAR:?...}` substitutions.
    export COPYPARTY_PASSWORD=test VPN_SERVICE_PROVIDER=mullvad \
           WIREGUARD_PRIVATE_KEY=x WIREGUARD_ADDRESSES=10.0.0.2/32
    if command -v podman-compose >/dev/null 2>&1; then
      podman-compose -f docker-compose.yml config >/dev/null 2>&1
    elif command -v docker >/dev/null 2>&1; then
      docker compose -f docker-compose.yml config >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml'))"
    else
      printf '    (no compose/python validator available)\n' >&2
      exit 0
    fi
  ); then ok "$c"; else bad "$c"; fi
done < <(find compose -mindepth 2 -maxdepth 2 -name docker-compose.yml | sort)

note "dry-run code paths"
export DRY_RUN=1 ASSUME_YES=1
dry() { if "$@" >/dev/null 2>&1; then ok "$*"; else bad "$*"; fi; }
dry ./bootstrap.sh
dry ./scripts/storage.sh status
dry ./scripts/storage.sh create /dev/sdX /dev/sdY
dry ./scripts/storage.sh add /dev/sdZ
dry ./scripts/manage.sh up
dry ./scripts/manage.sh down
dry ./scripts/manage.sh ps

note "unit assertions"
if bash test/unit.sh; then ok "unit suite"; else bad "unit suite"; fi

if [[ $fail -eq 0 ]]; then
  printf '\nAll checks passed.\n'
else
  printf '\nSome checks FAILED.\n' >&2
fi
exit $fail
