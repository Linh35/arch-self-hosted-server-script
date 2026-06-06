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
  btrfs-progs ufw \
  restic git curl jq wget tar

log "Ensuring Docker Hub is searched for unqualified image names"
# Several compose images use short names (deluan/navidrome, copyparty/ac). Arch's
# default registries.conf has no unqualified-search-registries, so podman can't
# resolve them. Add a user-level config (rootless) that points short names at
# Docker Hub, unless the system already defines a search list.
if [[ "$DRY_RUN" == 1 ]]; then
  log "  [dry-run] would write ~/.config/containers/registries.conf (unqualified-search-registries=docker.io)"
elif ! podman info --format '{{.Registries.search}}' 2>/dev/null | grep -q docker.io; then
  mkdir -p "$HOME/.config/containers"
  printf 'unqualified-search-registries = ["docker.io"]\n' \
    > "$HOME/.config/containers/registries.conf"
  log "  wrote ~/.config/containers/registries.conf"
fi

log "Configuring the host firewall (ufw): allow SSH + the LAN, deny the rest"
# Without this, ufw's default deny-incoming silently drops every connection from
# other devices (services only answer on localhost). Allow SSH explicitly so we
# never lock out, then trust the LAN subnet (the access perimeter). WARP-tunnelled
# traffic arrives from the host's own LAN IP, so it's covered too.
lan_cidr=$(ip route show 2>/dev/null | awk '/proto kernel scope link/ {print $1; exit}')
if [[ "$DRY_RUN" == 1 ]]; then
  log "  [dry-run] would: ufw allow 22/tcp; ufw allow from <LAN CIDR>; ufw --force enable"
elif [[ -n "$lan_cidr" ]]; then
  sudo ufw allow 22/tcp >/dev/null
  sudo ufw allow from "$lan_cidr" >/dev/null
  sudo ufw --force enable >/dev/null
  log "  ufw enabled (SSH + $lan_cidr allowed)"
else
  warn "couldn't detect the LAN subnet; left ufw untouched. Configure it by hand."
fi

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
