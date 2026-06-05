#!/usr/bin/env bash
set -euo pipefail

# One-time setup. Run as your normal user; it will sudo where needed.
# Honours DRY_RUN=1 to print actions instead of performing them.

SCRIPT_NAME=bootstrap
# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

if [[ "$DRY_RUN" != 1 && $EUID -eq 0 ]]; then
  die "Don't run this as root. Run as your normal user; it will sudo where needed."
fi
if [[ "$DRY_RUN" != 1 ]] && ! command -v pacman >/dev/null; then
  die "pacman not found. This is for Arch (or Arch-derived) systems."
fi

HERE="$REPO_ROOT"

log "Installing packages"
run sudo pacman -S --needed --noconfirm \
  podman podman-compose \
  fuse-overlayfs slirp4netns aardvark-dns netavark \
  btrfs-progs \
  restic git curl jq wget tar

log "Enabling lingering and rootless podman services"
run sudo loginctl enable-linger "${USER:-$(id -un)}"
run systemctl --user daemon-reload
run systemctl --user enable --now podman.socket
# Honours `restart:` policies after host reboot for rootless containers.
if [[ "$DRY_RUN" == 1 ]] || systemctl --user list-unit-files podman-restart.service >/dev/null 2>&1; then
  run systemctl --user enable --now podman-restart.service
fi

log "Allowing rootless binds to :80/:443 (for the Caddy reverse proxy)"
if [[ "$DRY_RUN" == 1 ]]; then
  log "  [dry-run] would set net.ipv4.ip_unprivileged_port_start=80 via /etc/sysctl.d"
else
  echo 'net.ipv4.ip_unprivileged_port_start=80' \
    | sudo tee /etc/sysctl.d/99-selfhost-ports.conf >/dev/null
  sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80 >/dev/null
fi

log "Installing cloudflared"
if [[ "$DRY_RUN" == 1 ]] || ! command -v cloudflared >/dev/null; then
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    armv7l)  arch=arm    ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  run curl -fL --retry 3 -o "$tmp/cloudflared" "$url"
  run sudo install -m 755 "$tmp/cloudflared" /usr/local/bin/cloudflared
fi
run cloudflared --version

log "Fetching Immich compose template"
run mkdir -p "$HERE/compose/immich"
if [[ "$DRY_RUN" == 1 ]]; then
  log "  [dry-run] would fetch Immich docker-compose.yml + example.env from upstream"
else
  cd "$HERE/compose/immich"
  if [[ ! -f docker-compose.yml ]]; then
    curl -fL --retry 3 -o docker-compose.yml \
      https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
  fi
  if [[ ! -f example.env ]]; then
    curl -fL --retry 3 -o example.env \
      https://github.com/immich-app/immich/releases/latest/download/example.env
  fi
fi

log "Creating .env files from .env.example where missing"
if [[ "$DRY_RUN" == 1 ]]; then
  log "  [dry-run] would copy each .env.example to .env and seed cloudflared/config.yml"
else
  find "$HERE" -name '.env.example' -not -path '*/data/*' | while read -r ex; do
    dst="${ex%.example}"
    if [[ ! -f "$dst" ]]; then
      cp "$ex" "$dst"
      log "  created $dst"
    fi
  done
  if [[ ! -f "$HERE/compose/immich/.env" && -f "$HERE/compose/immich/example.env" ]]; then
    cp "$HERE/compose/immich/example.env" "$HERE/compose/immich/.env"
    log "  created compose/immich/.env"
  fi
  if [[ ! -f "$HERE/cloudflared/config.yml" ]]; then
    cp "$HERE/cloudflared/config.yml.example" "$HERE/cloudflared/config.yml"
    log "  created cloudflared/config.yml"
  fi
fi

echo
log "Done. Next steps are in README.md."
