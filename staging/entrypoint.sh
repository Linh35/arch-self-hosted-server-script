#!/usr/bin/env bash
set -euo pipefail

# Runs as root INSIDE the staging container. Seeds throwaway config, then brings
# the selfhost compose stacks up on the container's OWN podman. Everything here
# is disposable: `podman rm -f selfhost-staging` on the host wipes it all.
#
# PROFILE selects what to boot:
#   lite  (default)  caddy + navidrome + copyparty + calibre   — fast, no big pulls
#   full             adds immich (Postgres+Redis+ML) and a VPN-stubbed Stremio

REPO=/opt/selfhost
OV="$REPO/staging/overrides"
PROFILE="${PROFILE:-lite}"
export STORAGE_ROOT=/srv/staging-data

cd "$REPO"

log()  { printf '\n\033[36m[staging]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[33m[staging] WARN:\033[0m %s\n' "$*" >&2; }

mkdir -p "$STORAGE_ROOT"

# --- Seed throwaway env files ---------------------------------------------
log "Seeding throwaway .env files (profile: $PROFILE)"

cat > "$REPO/.env" <<EOF
DOMAIN=localhost
TZ=UTC
PUID=0
PGID=0
STORAGE_ROOT=$STORAGE_ROOT
EOF

# Per-stack envs from their committed examples, then staging-only secrets.
find compose -name '.env.example' -not -path '*/data/*' | while read -r ex; do
  cp "$ex" "${ex%.example}"
done
# Containers run as root in this privileged box and the throwaway data dirs are
# root-owned, so force PUID/PGID=0 everywhere. (A per-stack .env's PUID=1000
# would otherwise override the root .env and break root-owned volumes, e.g.
# navidrome's "mkdir /data/cache: permission denied".)
find compose -name '.env' -not -path '*/data/*' | while read -r f; do
  sed -i -E 's/^[[:space:]]*PUID=.*/PUID=0/; s/^[[:space:]]*PGID=.*/PGID=0/' "$f"
done
# copyparty's compose hard-requires a password; set (don't append) so the .env
# has no duplicate key.
if grep -q '^[[:space:]]*COPYPARTY_PASSWORD=' compose/copyparty/.env; then
  sed -i 's/^[[:space:]]*COPYPARTY_PASSWORD=.*/COPYPARTY_PASSWORD=staging/' compose/copyparty/.env
else
  printf 'COPYPARTY_PASSWORD=staging\n' >> compose/copyparty/.env
fi

# --- Per-stack start helpers ----------------------------------------------
start_navidrome() { ( cd compose/navidrome && podman-compose up -d ); }
start_copyparty() { ( cd compose/copyparty && podman-compose up -d ); }
start_calibre()   { ( cd compose/calibre   && podman-compose up -d ); }
start_caddy()     { ( cd compose/caddy      && podman-compose -f "$OV/caddy.staging.yml" up -d ); }
start_stremio()   { ( cd compose/stremio    && podman-compose -f "$OV/stremio.staging.yml" up -d ); }
start_immich()    {
  ( cd compose/immich && [[ -f .env ]] || cp example.env .env; podman-compose up -d )
}

case "$PROFILE" in
  lite) STACKS=(navidrome copyparty calibre caddy) ;;
  full) STACKS=(navidrome copyparty calibre immich stremio caddy) ;;
  *) warn "unknown PROFILE='$PROFILE' (use lite|full)"; exit 1 ;;
esac

# --- Boot ------------------------------------------------------------------
for s in "${STACKS[@]}"; do
  log "starting stack: $s"
  if ! "start_$s"; then warn "stack '$s' failed to start (continuing)"; fi
done

log "Stacks started. Running containers:"
podman ps --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

cat <<'EOF'

[staging] Ready. From the HOST reach services on the mapped ports, e.g.:
  Navidrome  http://localhost:4533
  Copyparty  http://localhost:3923   (admin / staging)
  Calibre    http://localhost:8080
  Calibre-Web http://localhost:8083
  Immich     http://localhost:2283   (full profile)
  Stremio    http://localhost:11470  (full profile)
  Caddy      https://localhost:8443  (self-signed; curl --resolve <svc>.localhost:8443:127.0.0.1)

Shell in:   make staging-sh        Tear down:  make staging-down
EOF

# Keep the container (and the inner containers) alive until torn down.
exec sleep infinity
