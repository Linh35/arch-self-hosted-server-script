# Design notes — self-hosted email (mailcow)

Status: **exploring, not built.** Captures why the first idea (mailcow split
across Railway + home with failover storage, over WARP) doesn't work, and the
architectures that actually meet the goals. Decide a direction before building.

## Goals

- Own our email (self-hosted mailboxes, not a third-party inbox).
- Mail data lives on **this server's btrfs pool** (`STORAGE_ROOT`).
- **Uptime** — don't lose incoming mail when the home server / home internet is
  down.

## Why "Railway + home, failover storage, via WARP" can't work

Three independent blockers — any one is fatal:

1. **Railway can't host a mail server.** Outbound SMTP (25/465/587) is blocked
   on Free/Hobby and only unblocked for Pro/Enterprise — and that's for
   *sending via a relay*, not *receiving*. No inbound port 25, no control over
   reverse DNS (PTR). Railway is a stateless-app PaaS; mailcow is a ~18-container
   privileged Docker stack expecting a host you control.
2. **Failover storage = split-brain.** A mailbox store (Dovecot maildir +
   MariaDB) is one source of truth. Two stores that each take mail during the
   other's downtime diverge with no sane merge. mailcow **does not support
   HA / multi-node / split storage** — it's not a missing setting.
3. **WARP / Cloudflare Tunnel can't carry inbound mail.** Port 25 over a
   Tunnel/WARP is silently dropped; Cloudflare doesn't proxy SMTP by default,
   and external senders aren't on our WARP network. WARP can only privately
   serve mailcow's **web UI** (SOGo webmail + admin), never the mail transport.

## The key reframe: SMTP already retries

The instinct "I need failover storage so I don't lose mail during an outage" is
mostly unnecessary. **Sending mail servers queue and retry** for days (commonly
up to ~5 days) when the destination is unreachable. A short home outage loses
nothing — senders retry until we're back.

- A **backup MX** doesn't add durability so much as move that queue onto a box
  we control (and shorten the sender-visible "deferred" window).
- What an outage *does* cost is **read access** (IMAP/webmail) to existing mail
  — and neither a backup MX nor "failover storage" fixes that; you can't read a
  mailbox that's on a down server.

So the real lever for uptime is **where the always-on box lives**, not a second
copy of the store.

## Hard requirements for receiving internet email (any option)

Somewhere there must be a box with: a **public static IP**, open **port 25**,
and **custom rDNS/PTR** matching its HELO hostname. Plus DNS: `MX`, `A`/`AAAA`,
**SPF**, **DKIM**, **DMARC** (and ideally MTA-STS + TLS-RPT). This is why
home-only (CGNAT + ISP port-25 block) and Railway are both out.

## Realistic options

### A. VPS-primary, home = backup  *(recommended)*

mailcow on a small VPS that allows port 25 + rDNS. Authoritative store on the
VPS; `restic` backups land on the home btrfs pool (so we still *own* the data
locally, and can restore/migrate anytime).

- **Storage goal:** met as **backups** on `STORAGE_ROOT`, not the live store.
- **Uptime:** best — the VPS is always on regardless of home.
- **Deliverability:** best (static IP, proper rDNS, warmable).
- **Cost/effort:** ~€4–5/mo VPS; lowest complexity, one box to run.

### B. Home-primary + VPS relay + backup-MX

mailcow runs **at home** (live store on the btrfs pool). A cheap VPS provides
the public port-25 endpoint over **WireGuard** (DNAT 25/465/587/993 → home) and
runs a **backup-MX** (Postfix) that queues inbound mail while home is down, then
re-delivers.

- **Storage goal:** met as the **live store** at home.
- **Uptime (receiving):** good — backup-MX queues during outages; **reading**
  mail during an outage still isn't possible.
- **Deliverability:** harder — sending from a residential path needs care
  (route outbound through the VPS/a smarthost; watch the relay IP's reputation).
- **Cost/effort:** ~€3–5/mo nano VPS + more moving parts (WireGuard, HAProxy/
  iptables DNAT, a second Postfix). Most complex.

### C. Forwarding / hosted only

No self-hosted SMTP. Either **Cloudflare Email Routing** (free, forwards
your-domain mail to an existing inbox — no IMAP store, limited sending) or a
cheap **hosted mailbox** (Migadu / Mailbox.org / Fastmail / Purelymail, ~€1–5/mo).

- **Storage goal:** not on our server (could `restic`/`mbsync` a local copy).
- **Uptime/deliverability:** provider's problem (best of all).
- **Cost/effort:** lowest effort; least control/ownership.

## Where WARP fits

Only the **web UI**: front mailcow's SOGo/admin at `mail.<domain>` through Caddy
+ WARP like every other service, so the panel stays LAN/WARP-only. The SMTP/IMAP
ports must be reached directly on the always-on box's public IP (option A/B) or
are the provider's (option C).

## Recommendation

**Option A** unless keeping the *live* store at home is a hard requirement. It
gets uptime and deliverability for the least complexity, and still satisfies
"data on my server" via restic backups to the btrfs pool. Reach for **B** only
if the live mailbox store must physically sit at home.

## Open questions before building

- Budget / willingness to run a small always-on VPS (A or B both need one).
- VPS provider that allows port 25 **and** PTR edits (e.g. Netcup, Hetzner [25
  unblocked on request], OVH) — confirm before committing.
- Which domain hosts the mail, and expected volume (affects IP warming).
- Must the live store be at home (→ B), or are local backups enough (→ A)?
