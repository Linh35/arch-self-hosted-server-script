# Backups: restic → Backblaze B2 (offsite)

Nightly **encrypted, deduplicated, incremental** snapshots of `$STORAGE_ROOT`,
pushed offsite by [`scripts/backup.sh`](../scripts/backup.sh). This is the "1"
in 3-2-1: even if the house and the RAID1 pool are gone, the data isn't.

`backup.sh` already dumps the Immich Postgres DB and pauses Copyparty for a
consistent snapshot, excludes caches/thumbs/transcodes, and prunes old
snapshots (keep 7 daily / 4 weekly / 6 monthly).

## One-time setup

1. **Install the tools** (bootstrap.sh does this on a real host):
   ```sh
   sudo pacman -S --needed restic podman-compose
   ```

2. **Create your credentials file** from the template and lock it down:
   ```sh
   cp scripts/selfhost-backup.env.example ~/.config/selfhost-backup.env
   chmod 600 ~/.config/selfhost-backup.env
   $EDITOR ~/.config/selfhost-backup.env        # set RESTIC_PASSWORD + B2 bucket/keys
   ```
   In the B2 console: make a **private** bucket, then an **Application Key**
   scoped to it. Store `RESTIC_PASSWORD` somewhere safe offline too — losing it
   means the backups are unrecoverable.

3. **Initialise the restic repo** once:
   ```sh
   set -a; source ~/.config/selfhost-backup.env; set +a
   restic init
   ```

4. **Install + enable the nightly timer** (a *user* service — it runs under your
   login, which is why bootstrap enables lingering so it fires even when you're
   not logged in):
   ```sh
   mkdir -p ~/.config/systemd/user
   cp systemd/selfhost-backup.{service,timer} ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now selfhost-backup.timer
   ```

## Operate

```sh
systemctl --user list-timers selfhost-backup.timer   # when does it next run?
systemctl --user start selfhost-backup.service        # run a backup right now
journalctl --user -u selfhost-backup.service -f       # watch it

# Inspect / restore (after sourcing the env file):
set -a; source ~/.config/selfhost-backup.env; set +a
restic snapshots
restic restore latest --target /tmp/restore-test      # verify restores work!
```

> Test a restore now and then — an untested backup isn't a backup.
