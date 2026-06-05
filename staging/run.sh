#!/usr/bin/env bash
set -euo pipefail

# Build and boot the disposable staging container (podman-in-podman). The inner
# stacks publish their ports on this container; we map them to the host so you
# can hit the services directly. Tear everything down with `make staging-down`.
#
#   PROFILE=lite   (default) caddy + navidrome + copyparty + calibre
#   PROFILE=full            adds immich + stremio
#
# Usage: bash staging/run.sh   |   PROFILE=full bash staging/run.sh

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IMG=selfhost-staging
NAME=selfhost-staging
PROFILE="${PROFILE:-lite}"

command -v podman >/dev/null || { echo "podman not found on host" >&2; exit 1; }

echo "==> building $IMG"
podman build -t "$IMG" -f staging/Containerfile .

echo "==> removing any previous $NAME"
podman rm -f "$NAME" >/dev/null 2>&1 || true

echo "==> starting $NAME (profile: $PROFILE)"
podman run -d --name "$NAME" --privileged \
  -e PROFILE="$PROFILE" \
  -p 4533:4533 -p 3923:3923 -p 8080:8080 -p 8081:8081 -p 8083:8083 \
  -p 2283:2283 -p 8181:8181 -p 11470:11470 -p 12470:12470 \
  -p 8088:80 -p 8443:443 \
  "$IMG"

echo "==> following startup logs (Ctrl-C to detach; the container keeps running)"
exec podman logs -f "$NAME"
