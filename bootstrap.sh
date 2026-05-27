#!/usr/bin/env bash
set -euo pipefail

# One-time setup. Run as your normal user.

if [[ $EUID -eq 0 ]]; then
  echo "Don't run this as root. Run as your normal user; it will sudo where needed." >&2
  exit 1
fi

if ! command -v pacman >/dev/null; then
  echo "pacman not found. This is for Arch (or Arch-derived) systems." >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

log() { printf '%s\n' "[bootstrap] $*"; }

log "Installing packages"
sudo pacman -S --needed --noconfirm \
  docker docker-compose docker-buildx \
  restic git curl jq wget tar \
  kodi

log "Enabling docker"
sudo systemctl enable --now docker
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  log "Added $USER to docker group. Log out and back in (or run 'newgrp docker') before continuing."
fi

log "Installing cloudflared"
if ! command -v cloudflared >/dev/null; then
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    armv7l)  arch=arm    ;;
    *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
  esac
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  curl -fL --retry 3 -o "$tmp/cloudflared" "$url"
  sudo install -m 755 "$tmp/cloudflared" /usr/local/bin/cloudflared
fi
cloudflared --version

log "Fetching Immich compose template"
mkdir -p "$HERE/compose/immich"
cd "$HERE/compose/immich"
if [[ ! -f docker-compose.yml ]]; then
  curl -fL --retry 3 -o docker-compose.yml \
    https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
fi
if [[ ! -f example.env ]]; then
  curl -fL --retry 3 -o example.env \
    https://github.com/immich-app/immich/releases/latest/download/example.env
fi

log "Creating .env files from .env.example where missing"
find "$HERE" -name '.env.example' -not -path '*/data/*' | while read -r ex; do
  dst="${ex%.example}"
  if [[ ! -f "$dst" ]]; then
    cp "$ex" "$dst"
    log "  created $dst"
  fi
done
if [[ ! -f "$HERE/compose/immich/.env" ]]; then
  cp "$HERE/compose/immich/example.env" "$HERE/compose/immich/.env"
  log "  created compose/immich/.env"
fi
if [[ ! -f "$HERE/cloudflared/config.yml" ]]; then
  cp "$HERE/cloudflared/config.yml.example" "$HERE/cloudflared/config.yml"
  log "  created cloudflared/config.yml"
fi

echo
log "Done. Next steps are in README.md."
