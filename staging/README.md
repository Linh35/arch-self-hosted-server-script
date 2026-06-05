# Staging: server-in-a-box

Boot the **real** compose stacks in one disposable, isolated container, click
around, then throw it away. Nothing touches your host's podman, storage, or the
Cloudflare tunnel.

This is distinct from `test/`, which only lints + dry-runs the scripts. Staging
actually *runs* the services.

## How it works

`make staging-up` builds an Arch image (`staging/Containerfile`) and runs it
`--privileged`. Inside, a **rootful podman** brings up the stacks from
`compose/` against a throwaway `STORAGE_ROOT=/srv/staging-data`. The inner
services publish their ports on the container; `staging/run.sh` maps those to
the host. `make staging-down` is a single `podman rm -f` — everything inside
vanishes with it.

Two staging-only swaps make it bootable without secrets:
- **Caddy** runs the stock `caddy:2` image with `tls internal` (no Cloudflare
  token / custom build) — see `overrides/caddy.staging.yml`.
- **Stremio** runs without the gluetun VPN — see `overrides/stremio.staging.yml`.

## Usage

```sh
make staging-up              # lite: caddy + navidrome + copyparty + calibre
PROFILE=full make staging-up # adds Immich (heavy) + VPN-stubbed Stremio

make staging-logs            # follow startup output
make staging-sh              # shell inside; try `podman ps`, `./scripts/manage.sh ps`
make staging-ps              # list the inner service containers
make staging-down            # destroy it all
```

### Reach the services (from the host)

| Service     | URL                       | Profile | Login |
|-------------|---------------------------|---------|-------|
| Navidrome   | http://localhost:4533     | all     | admin / admin |
| Copyparty   | http://localhost:3923     | all     | none |
| Calibre GUI | http://localhost:8080     | all     | none |
| Calibre-Web | http://localhost:8083     | all     | admin / admin123 |
| Caddy       | https://localhost:8443    | all     | (self-signed) |
| Immich      | http://localhost:2283     | full    | create on first run |
| Stremio     | http://localhost:11470    | full    | none |

Caddy serves by hostname (and selects its cert by TLS SNI), so test routing
through it with `--resolve` rather than a `Host:` header:
`curl -k --resolve music.localhost:8443:127.0.0.1 https://music.localhost:8443/`.

## Requirements / notes

- Needs `--privileged` for nested podman (fuse-overlayfs + netavark). It runs
  rootful podman *inside* the throwaway container; your host podman stays
  rootless and untouched.
- `full` pulls several GB for Immich (Postgres + Redis + ML) and is slow on
  first boot. Start with `lite`.
