#!/usr/bin/env bash
set -euo pipefail

# Build the Arch test container and run the suite inside it. Uses podman if
# available, else docker. On macOS, install podman (`brew install podman`)
# and start the VM once (`podman machine init && podman machine start`).

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

engine=""
for e in podman docker; do
  if command -v "$e" >/dev/null 2>&1; then engine=$e; break; fi
done
if [[ -z "$engine" ]]; then
  echo "Need podman or docker." >&2
  echo "macOS: brew install podman && podman machine init && podman machine start" >&2
  exit 1
fi

echo "==> Using $engine"
"$engine" build -t selfhost-test -f test/Containerfile .
"$engine" run --rm selfhost-test
