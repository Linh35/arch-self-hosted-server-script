# arch-self-hosted-server-script

My self-hosted setup on Arch. Bootstrap script, a few compose files run
under rootless Podman, a Cloudflare tunnel as the private VPN path in,
restic for backups. Replaces Google Photos, Drive, and a few other
things I'd rather not pay for.

Everything stays on the LAN. Nothing is published to a public hostname.
From outside the house you reach the services over the tunnel, which only
accepts devices running the Cloudflare WARP client enrolled in your Zero
Trust org — so the tunnel acts as a VPN, not a public front door.

## Stack

| Software         | Port    | Name (via Caddy)     | Access                    |
|------------------|---------|----------------------|---------------------------|
| Caddy (proxy)    | 80/443  | —                    | LAN / WARP tunnel         |
| Immich           | 2283    | `photos.<domain>`    | LAN / WARP tunnel         |
| Copyparty        | 3923    | `files.<domain>`     | LAN / WARP tunnel         |
| Calibre (GUI)    | 8080    | `books.<domain>`     | LAN / WARP tunnel         |
| Calibre content  | 8081    | —                    | LAN / WARP tunnel         |
| Calibre-Web      | 8083    | `read.<domain>`      | LAN / WARP tunnel         |
| Navidrome        | 4533    | `music.<domain>`     | LAN / WARP tunnel         |
| Stremio server   | 11470   | — (app talks direct) | LAN / WARP tunnel         |
| Gluetun (VPN)    | —       | —                    | — (outbound for Stremio)  |

Caddy puts a clean name and HTTPS in front of each service, so you reach
them at `https://music.<domain>` instead of `http://<server-ip>:4533`. The
raw `http://<server-ip>:PORT` still works too. Either way it's the same on
the LAN and from anywhere once your device is on the WARP tunnel — no
service is exposed on a public hostname.

Copyparty handles the Drive role. It speaks WebDAV so any OS can mount it
like a normal network drive, has a usable web UI, and is one small Python
process with no database to babysit.

Calibre manages your ebook library and runs a content server; Calibre-Web
serves that same library to clients as a clean web reader with OPDS, so a
book added in either shows up in both.

Navidrome serves your music to every device over the Subsonic API — native
apps on iOS (Amperfy, play:Sub), macOS and Linux (Supersonic, Feishin,
Tempo), plus its own web UI. A downloader (spotDL or deemix) drops files
into the music folder; Navidrome indexes them.

Stremio server runs inside Gluetun's network namespace, so every byte
goes through the VPN. If the VPN drops, nothing leaks. The Stremio app
on a phone or tablet talks to it over the LAN and streams whatever you
pick directly to the device.

No email in here. I use Fastmail. Calendar is planned (Radicale).

## Storage (RAID)

All service data lives under one directory set by `STORAGE_ROOT` in the
root `.env` (the stacks read it through `./scripts/manage.sh`). Point it at
a btrfs RAID1 pool and every photo, file, book, and track is mirrored
across two disks — lose a drive, lose nothing.

`scripts/storage.sh` wraps the btrfs side:

```sh
sudo ./scripts/storage.sh create /dev/sdb /dev/sdc   # new RAID1 pool (WIPES the disks)
sudo ./scripts/storage.sh add /dev/sdd               # plug in a disk, grow, stay redundant
sudo ./scripts/storage.sh status                     # devices + usage
sudo ./scripts/storage.sh scrub                      # verify + self-heal from the mirror
sudo ./scripts/storage.sh health                     # error counters + scrub state
```

`create` builds the mirror, mounts it at `STORAGE_ROOT`, and writes an
fstab entry so it returns after a reboot. Adding a disk is online — no
reformat, no downtime; btrfs rebalances and capacity grows. Usable space
is about half the raw total (the cost of mirroring). btrfs RAID1 gives
real-time redundancy, checksums with self-healing, easy online growth, and
it's in the mainline kernel so nothing breaks across Arch updates.

Leave `STORAGE_ROOT` unset and everything falls back to the in-repo `data/`
directory — fine for a single disk or a quick try.

## Cloudflare tunnel (as a VPN)

`cloudflared` keeps an outbound connection open to Cloudflare. No port
forwarding, no exposed home IP, works through CGNAT. Instead of publishing
public hostnames, this setup runs the tunnel in **private network**
(WARP-to-Tunnel) mode: a private CIDR — your LAN subnet — is routed
through the tunnel, and only devices running the Cloudflare **WARP**
client, enrolled in your Zero Trust org, can reach it. So it behaves like
a VPN. Nothing is open to the public internet.

On the LAN you hit services directly at `http://<server-ip>:PORT` since
they listen on all interfaces. From outside, connect WARP and use the
exact same LAN address — the tunnel carries it.

The price is that Cloudflare's edge sits in the path. If that bothers you,
plain WireGuard or Tailscale gets you the same LAN-only-over-VPN shape
without a third party.

## Setup

```sh
git clone git@github.com:Linh35/arch-self-hosted-server-script.git ~/selfhost
cd ~/selfhost
./bootstrap.sh
```

That installs Podman, podman-compose, cloudflared, restic, btrfs-progs,
pulls the Immich compose template, and copies every `.env.example` to
`.env`.
It also enables lingering so containers come back up after a reboot
without you logging in first.

Then fill in:

- `.env` — set `STORAGE_ROOT` to your pool mount (or leave it commented for
  `data/`), plus `DOMAIN`/`TZ` if needed.
- `compose/copyparty/.env` — set `COPYPARTY_PASSWORD`. Required.
- `compose/immich/.env` — set `DB_PASSWORD`, and `UPLOAD_LOCATION` to
  `$STORAGE_ROOT/immich`.
- `compose/calibre/.env` — optional `CALIBRE_GUI_PASSWORD`.
- `compose/caddy/.env` — set `DOMAIN` for the service names; optionally
  `UPSTREAM_HOST` or `CLOUDFLARE_API_TOKEN` (see Reverse proxy below).

### Cloudflare tunnel (WARP-to-Tunnel)

```sh
cloudflared tunnel login
cloudflared tunnel create selfhost
```

The create command prints a UUID. Paste it into `cloudflared/config.yml`
in both places. There are no hostnames to set here — the config routes a
private network, not public domains.

Route your LAN subnet through the tunnel (adjust the CIDR to match your
network, e.g. `192.168.1.0/24`):

```sh
cloudflared tunnel route ip add 192.168.1.0/24 selfhost

sudo mkdir -p /etc/cloudflared
sudo cp cloudflared/config.yml /etc/cloudflared/
sudo cp ~/.cloudflared/<uuid>.json /etc/cloudflared/
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

Then, in the Cloudflare **Zero Trust** dashboard (one-time, in the web UI):

- **Networks → Tunnels** — confirm `selfhost` is *Healthy* and shows your
  CIDR under its private routes.
- **Settings → WARP Client → Device enrollment** — add a policy for who
  may join (e.g. your email).
- **Settings → WARP Client → Device settings → Split Tunnels** — WARP
  excludes RFC1918 ranges by default, which would skip your LAN. Remove
  your CIDR from the *Exclude* list (or switch that profile to *Include*
  and add it) so LAN traffic goes through the tunnel.

On each device that needs remote access, install the **Cloudflare WARP**
client, log in to your team/org, and connect. Once enrolled you can reach
every service at its LAN address (`http://<server-ip>:2283`, etc.) from
anywhere. On the LAN itself you don't need WARP at all.

### Stremio + VPN

Edit `compose/stremio/.env` and fill in your VPN provider details. The
example file has a Mullvad WireGuard block; for other providers, the
variable names are at <https://github.com/qdm12/gluetun-wiki>.

Once everything is up, install Stremio on a tablet or phone, open the
settings, and point it at `http://<your-server-lan-ip>:11470`. Add
addons like Torrentio, ThePirateBay+, or YTS for search.

Stremio Server has no auth of its own, so it relies on the same boundary
as everything else: it only listens on the LAN and is reachable from
outside solely through the authenticated WARP tunnel. Keep it that way —
don't add a public hostname for it.

### Books (Calibre + Calibre-Web)

Open the Calibre desktop GUI at `http://<server-ip>:8080` and create (or
point to) the library at `/library`. To serve e-reader apps over OPDS,
start the Content Server inside Calibre: Preferences → Sharing over the net
→ start (it listens on `:8081`).

Then open Calibre-Web at `http://<server-ip>:8083`. On first run it asks
for the library database location — enter `/books`, the same library
Calibre writes to. Create the admin user and you're done; books added in
Calibre show up in Calibre-Web for browsing, reading, and download.

### Music (Navidrome)

Put your music under `$STORAGE_ROOT/music` (a downloader like spotDL or
deemix can write straight there). Open Navidrome at
`http://<server-ip>:4533`, create the admin user, and it scans the folder.
Point any Subsonic client at that URL — Amperfy or play:Sub on iOS,
Supersonic/Feishin/Tempo on macOS and Linux — or use the web UI.

### Reverse proxy (Caddy)

Caddy gives every service a name and HTTPS, so you browse to
`https://music.<domain>` instead of `http://<server-ip>:4533`. It terminates
TLS and proxies to each service's port on the host; `bootstrap.sh` lowers
`net.ipv4.ip_unprivileged_port_start` so the rootless container can bind
:80/:443.

Set `DOMAIN` in `compose/caddy/.env` (or the root `.env`), then point the
service names at the server. Because access is LAN-only, the names just need
to resolve to the server's **LAN** IP — pick one:

- Add A records `music`, `photos`, `files`, `books`, `read` (etc.) in your
  DNS pointing at the LAN IP (e.g. `192.168.1.50`). Public DNS handing back a
  private IP is fine — it only routes for devices on the LAN or WARP.
- Or add the same names to `/etc/hosts` on each client.

**TLS modes:**

- *Default — internal CA.* HTTPS works immediately with no setup, but the
  cert isn't publicly trusted. Install Caddy's root CA (written under
  `$STORAGE_ROOT/caddy/data`) on your devices to silence warnings.
- *Publicly-trusted — Cloudflare DNS.* Recommended once you have a domain on
  Cloudflare (no warnings, e.g. for Amperfy on iOS). In
  `compose/caddy/Caddyfile`, swap the `(tls)` snippet from `tls internal` to
  the commented `dns cloudflare` block, and set `CLOUDFLARE_API_TOKEN` (a
  scoped token with Zone:Read + DNS:Edit) in `compose/caddy/.env`. The DNS-01
  challenge needs no inbound ports, so it still works with nothing public.

If `host.containers.internal` doesn't resolve in your podman networking, set
`UPSTREAM_HOST` to the server's LAN IP in `compose/caddy/.env`.

### Start

```sh
./scripts/manage.sh up
```

Other subcommands: `down`, `restart`, `pull`, `ps`, `logs <service>`.

## Testing

The scripts are exercised without touching real disks, packages, or
containers — every mutating command goes through a `DRY_RUN`-aware wrapper,
so the suite just prints what *would* happen.

```sh
make test            # lint + compose validation + dry-run + unit; runs anywhere
make unit            # just the assertion-based unit tests (test/unit.sh)
make lint            # just bash -n + shellcheck
make test-container  # build an Arch container and run the suite inside it
```

`make test` runs `bash -n` and shellcheck on every script, checks each
compose file parses, walks the bootstrap/storage/manage/backup code paths
with `DRY_RUN=1`, then runs `test/unit.sh` — assertion-based tests that
check actual behaviour (lib helpers, storage argument validation and the
RAID1 commands it emits, manage dispatch, the Caddy routes, compose
invariants). It degrades gracefully when a tool is missing (it skips
shellcheck if it isn't installed, for instance).

`make test-container` builds `test/Containerfile` (Arch + the toolchain)
and runs the suite in real Linux — the closest thing to the target host.
On macOS it works through Podman's VM:

```sh
brew install podman
podman machine init && podman machine start
make test-container
```

`storage.sh create`/`add` can't be tested for real off the server (they
need actual block devices and btrfs), so the suite only dry-runs their
logic — live RAID changes happen on the Arch box itself. GitHub Actions
runs the same suite on every push (`.github/workflows/ci.yml`).

## Backups

`scripts/backup.sh` dumps Immich's Postgres, pauses the file-based
services for a clean snapshot, runs restic.

Put restic credentials in `~/.config/selfhost-backup.env` (chmod 600).
There's an example block at the top of the script. Then once:

```sh
source ~/.config/selfhost-backup.env
restic init
```

After that, cron or a systemd timer.

## Secrets

Anything sensitive lives in a `.env` file or `~/.config/selfhost-backup.env`,
all gitignored. `data/` and the cloudflared credentials JSON are also
gitignored. Don't commit anything from those paths.

## Notes

Containers run rootless. The compose files are still called
`docker-compose.yml` because that's what `podman-compose` looks for. If
you want to use `docker compose` instead, the files are compatible.

Arch-only (`pacman`). On Artix you'd need OpenRC units for cloudflared
and the rootless podman bits instead of the systemd ones.

The ~100 MB request cap on Cloudflare's free plan applies to the HTTP
proxy (public hostnames), not to WARP-to-Tunnel routing, so large uploads
over WARP aren't subject to it. On the LAN nothing touches Cloudflare at
all — full local speed.

The Immich compose isn't committed. Bootstrap pulls the latest one from
upstream, so re-running it after a while will move you to a newer version.
Don't run it casually.

## License

MIT.
