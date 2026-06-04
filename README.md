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

| Software         | Port  | Access                    |
|------------------|-------|---------------------------|
| Immich           | 2283  | LAN / WARP tunnel         |
| Copyparty        | 3923  | LAN / WARP tunnel         |
| Jellyfin         | 8096  | LAN / WARP tunnel         |
| Stremio server   | 11470 | LAN / WARP tunnel         |
| Gluetun (VPN)    | —     | — (outbound for Stremio)  |

Every service is reachable at `http://<server-ip>:PORT` on the LAN, and
the same address from anywhere once your device is on the WARP tunnel.
No service is exposed on a public hostname.

Copyparty handles the Drive role. It speaks WebDAV so any OS can mount it
like a normal network drive, has a usable web UI, and is one small Python
process with no database to babysit.

Kodi is installed natively by the bootstrap script because it runs on the
TV box, not on the server.

Stremio server runs inside Gluetun's network namespace, so every byte
goes through the VPN. If the VPN drops, nothing leaks. The Stremio app
on a phone or tablet talks to it over the LAN and streams whatever you
pick directly to the device.

No email in here. I use Fastmail. Calendar is planned (Radicale).

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

That installs Podman, podman-compose, cloudflared, restic, Kodi, pulls
the Immich compose template, and copies every `.env.example` to `.env`.
It also enables lingering so containers come back up after a reboot
without you logging in first.

Then fill in:

- `compose/copyparty/.env` — set `COPYPARTY_PASSWORD`. Required.
- `compose/immich/.env` — set `DB_PASSWORD` and `UPLOAD_LOCATION`.
- `.env` and `compose/jellyfin/.env` — change `DOMAIN` and `TZ` if needed.

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

### Start

```sh
./scripts/manage.sh up
```

Other subcommands: `down`, `restart`, `pull`, `ps`, `logs <service>`.

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

Hardware transcoding in Jellyfin is commented out. Uncomment the block
for your GPU in `compose/jellyfin/docker-compose.yml`.

The Immich compose isn't committed. Bootstrap pulls the latest one from
upstream, so re-running it after a while will move you to a newer version.
Don't run it casually.

## License

MIT.
