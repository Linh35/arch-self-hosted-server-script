# arch-self-hosted-server-script

My self-hosted setup on Arch. Bootstrap script, a few compose files run
under rootless Podman, Cloudflare tunnel in front, restic for backups.
Replaces Google Photos, Drive, and a few other things I'd rather not
pay for.

## Stack

| Software         | Port  | Subdomain |
|------------------|-------|-----------|
| Immich           | 2283  | photos.…  |
| Copyparty        | 3923  | files.…   |
| Jellyfin         | 8096  | tv.…      |
| Stremio server   | 11470 | LAN only  |
| Gluetun (VPN)    | —     | —         |

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

## Cloudflare tunnel

`cloudflared` keeps an outbound connection open to Cloudflare and they
route incoming requests back through it. No port forwarding, no exposed
home IP, works through CGNAT, HTTPS handled for you. The price is that
Cloudflare sees the traffic in plaintext. If that bothers you, use
Tailscale instead.

Services also listen on all interfaces, so on the LAN you can hit them
directly at `http://<server-ip>:PORT`.

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

### Cloudflare tunnel

```sh
cloudflared tunnel login
cloudflared tunnel create selfhost
```

The create command prints a UUID. Paste it into `cloudflared/config.yml`
in both places, and swap `example.com` for your domain.

```sh
cloudflared tunnel route dns selfhost photos.yourdomain.com
cloudflared tunnel route dns selfhost files.yourdomain.com
cloudflared tunnel route dns selfhost tv.yourdomain.com

sudo mkdir -p /etc/cloudflared
sudo cp cloudflared/config.yml /etc/cloudflared/
sudo cp ~/.cloudflared/<uuid>.json /etc/cloudflared/
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

### Stremio + VPN

Edit `compose/stremio/.env` and fill in your VPN provider details. The
example file has a Mullvad WireGuard block; for other providers, the
variable names are at <https://github.com/qdm12/gluetun-wiki>.

Once everything is up, install Stremio on a tablet or phone, open the
settings, and point it at `http://<your-server-lan-ip>:11470`. Add
addons like Torrentio, ThePirateBay+, or YTS for search.

The server is not exposed via Cloudflare. Stremio Server has no auth
and would happily serve random people, so keep it LAN-only. If you
want to use it away from home, reach it through Tailscale or similar.

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

Cloudflare's free plan caps requests through the proxy at around 100 MB.
Phone photo uploads are fine. Anything bigger goes over the LAN.

Hardware transcoding in Jellyfin is commented out. Uncomment the block
for your GPU in `compose/jellyfin/docker-compose.yml`.

The Immich compose isn't committed. Bootstrap pulls the latest one from
upstream, so re-running it after a while will move you to a newer version.
Don't run it casually.

## License

MIT.
