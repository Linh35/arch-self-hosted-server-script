# Runbook — Paperless-ngx + SearXNG

End-to-end setup for the two services added together: **Paperless-ngx**
(`docs.<domain>`) and **SearXNG** (`search.<domain>`). Both follow the house
rule — LAN + WARP only, reached by name through Caddy, **nothing public**. This
captures every step and the non-obvious gotchas, so a fresh bring-up is smooth.

| Service       | Stack               | Host port | Hostname            | Login |
|---------------|---------------------|-----------|---------------------|-------|
| Paperless-ngx | `compose/paperless` | `8087`    | `docs.<domain>`     | own (admin) |
| SearXNG       | `compose/searxng`   | `8089`    | `search.<domain>`   | none  |

## Prerequisites

These assume the base stack from the README is already in place:

- Rootless **podman** + `podman-compose`, lingering enabled (`bootstrap.sh`).
- **Caddy** stack running (`compose/caddy`) with `CLOUDFLARE_API_TOKEN`
  (Zone:Read + DNS:Edit) set — it issues the per-name TLS certs via DNS-01.
- **cloudflared** WARP-to-Tunnel running (for access from outside the LAN).
- `STORAGE_ROOT` set in the repo-root `.env` (the btrfs pool); all service
  data lands under it.
- A server **LAN IP** the names will point at (this host: `<server-ip>`).

## 1. Configure the per-stack env files

Each stack reads its own `.env` (gitignored). Copy the examples and fill them.

```sh
cp compose/paperless/.env.example compose/paperless/.env
cp compose/searxng/.env.example   compose/searxng/.env
```

**Paperless** (`compose/paperless/.env`) — set the real values:

- `DOMAIN` — your base domain (used for `PAPERLESS_URL=https://docs.$DOMAIN`).
- `PAPERLESS_SECRET_KEY` — `openssl rand -hex 32`.
- `PAPERLESS_DB_PASSWORD` — any strong string (used by Postgres + Paperless).
- `PAPERLESS_ADMIN_USER` / `PAPERLESS_ADMIN_PASSWORD` — seeds the superuser on
  **first boot only** (see §6 to change it later).
- `PUID`/`PGID` — keep **non-zero** (default `1000`). Paperless runs `usermod`
  on this and refuses `0` (root is already uid 0), same as FreshRSS. The
  container's root-stage init chowns its data dirs to this uid, so it can write
  under `STORAGE_ROOT` regardless of host ownership.

**SearXNG** (`compose/searxng/.env`) — just `DOMAIN` (and `TZ`). There is **no
secret to set**: on first run the image writes `settings.yml` with a random
`secret_key` into `$STORAGE_ROOT/searxng/`.

## 2. Add the DNS records (the names must resolve to the LAN IP)

This stack uses **per-name A records** (no wildcard), so each new name needs its
own record pointing at the server's LAN IP, **DNS-only (grey cloud, not
proxied)** — the whole point is LAN/WARP, never public. Public DNS returning a
private IP is fine; it only routes for devices on the LAN or WARP.

Dashboard: Cloudflare → DNS → add `A  docs  <server-ip>  (DNS only)` and
`A  search  <server-ip>  (DNS only)`.

Or via API with the same token Caddy uses:

```sh
set -a; . compose/caddy/.env; set +a          # loads CLOUDFLARE_API_TOKEN
ZID=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=<domain>" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["id"])')

for n in docs search; do
  curl -s -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZID/dns_records" \
    --data "{\"type\":\"A\",\"name\":\"$n\",\"content\":\"<server-ip>\",\"ttl\":1,\"proxied\":false}"
done
```

(Alternatively, add `docs`/`search` to `/etc/hosts` on each client.)

## 3. (SearXNG only) build the branded image

SearXNG is built locally so it carries the custom **"AL"** logo/favicon
(`compose/searxng/Containerfile` swaps the assets in `compose/searxng/brand/`
and drops the stale precompressed `.svg.br/.gz`). Plain upstream otherwise.

```sh
cd compose/searxng && podman-compose build && cd -
```

## 4. Bring the stacks up

```sh
./scripts/manage.sh up          # brings up every stack (new ones included)
# or just these two:
( cd compose/paperless && podman-compose up -d )
( cd compose/searxng   && podman-compose up -d )
```

First Paperless boot pulls a few images and runs DB migrations — give it ~60s
until `paperless_db` is `(healthy)` and the `paperless` webserver answers.

## 5. Load the Caddy routes — restart, do NOT just reload

The routes `docs.<domain> -> :8087` and `search.<domain> -> :8089` are already
in `compose/caddy/Caddyfile`. **Gotcha:** the Caddyfile is bind-mounted as a
single file. Editing it on the host replaces the file's inode, so the running
container keeps seeing the *old* file and `caddy reload` silently re-applies
stale config. **Restart the container** so the bind mount re-resolves:

```sh
podman restart caddy
```

On first request to each new name, Caddy obtains a publicly-trusted cert via the
Cloudflare DNS-01 challenge (~10–30s) — the first hit may fail until it lands.

## 6. First login / accounts

- **SearXNG** — no login; open `https://search.<domain>`.
- **Paperless** — open `https://docs.<domain>`, sign in with
  `PAPERLESS_ADMIN_USER` / `PAPERLESS_ADMIN_PASSWORD`. To **change the password
  later**, editing `.env` does nothing (it only seeds on first boot) — reset the
  existing user directly (this also bypasses the strength validators):

  ```sh
  podman exec paperless python3 /usr/src/paperless/src/manage.py shell -c "
  from django.contrib.auth.models import User
  u=User.objects.get(username='admin'); u.set_password('NEWPASS'); u.save()"
  ```

Add documents by dropping files into `$STORAGE_ROOT/paperless/consume/` or
uploading via the web UI.

## Verify

```sh
# raw ports on the LAN
curl -s -o /dev/null -w 'paperless :8087 -> %{http_code}\n' http://127.0.0.1:8087/
curl -s -o /dev/null -w 'searxng   :8089 -> %{http_code}\n' http://127.0.0.1:8089/

# through Caddy by name, with full TLS verification (0 = trusted)
for h in docs search; do
  curl -s -o /dev/null -w "$h -> HTTP %{http_code} TLS=%{ssl_verify_result}\n" \
    --resolve $h.<domain>:443:<server-ip> https://$h.<domain>/
done

# a real SearXNG query
curl -s --resolve search.<domain>:443:<server-ip> \
  "https://search.<domain>/search?q=test&format=json" | head -c 200
```

## Gotchas (the things that actually bit us)

- **Postgres 18 won't start on the classic mount.** `postgres:18` moved its data
  dir to `/var/lib/postgresql` (version-subdir layout) and refuses the
  `/var/lib/postgresql/data` mount this stack uses — it crash-loops with an
  "unused mount/volume" error. The compose pins **`postgres:16`** (what AppFlowy
  uses too). Don't bump it without also moving the mount + `pg_upgrade`.
- **Caddy edits need a restart, not a reload** — single-file bind mount, see §5.
- **DNS negative cache.** If a name 404'd before its record existed, clients may
  cache `NXDOMAIN` briefly. Wait a minute or flush DNS.
- **Paperless behind the proxy.** `PAPERLESS_URL=https://docs.$DOMAIN` makes that
  origin CSRF-trusted (login over the name works); `PAPERLESS_ALLOWED_HOSTS=*`
  keeps raw `http://<server-ip>:8087` working too.
- **SearXNG caps.** We deliberately do **not** copy upstream's `cap_drop: ALL`.
  Under rootless podman that hardening blocks the root entrypoint from creating
  and owning its config on first run (the documented "remove cap_drop on first
  run" dance). Default caps = first run just works. The limiter is off (no
  redis) because the LAN/WARP perimeter is the access control.

## Day-2

- **Change the SearXNG logo:** edit `compose/searxng/brand/` (or regenerate from
  Fraunces), then `cd compose/searxng && podman-compose build && podman-compose up -d`.
  Hard-refresh the browser (Ctrl+Shift+R) — logos/favicons cache hard.
- **Tune SearXNG** (engines, JSON API, image proxy): edit
  `$STORAGE_ROOT/searxng/settings.yml`, then `./scripts/manage.sh restart`.
- **More OCR languages:** set `PAPERLESS_OCR_LANGUAGE` (e.g. `eng+vie`) in
  `compose/paperless/.env` and restart.
- **Update SearXNG to a newer upstream:** `cd compose/searxng && podman-compose build`
  (rebases the brand image on the latest `searxng/searxng`).
