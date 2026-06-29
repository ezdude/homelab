# Architecture: What's Exposed vs. What's Behind VPN

The core design principle of this homelab is **explicit exposure control**. Every service is either deliberately public or deliberately VPN-only — nothing is "probably fine."

## Exposure Model

| Service | Public? | Reason |
|---|---|---|
| Caddy (port 443) | Yes | Fronts public services only — Nextcloud and Research Brain |
| WireGuard (UDP 51820) | Yes | The VPN entry point itself must be reachable to grant VPN access |
| Nextcloud | Yes (via Caddy) | Personal cloud needs to reach any network, including cellular |
| Research Brain | Yes (via Caddy) | AI tool; needs internet access; single-password auth + fail2ban |
| Pi-hole / stubby | No | DNS infrastructure; never needs to be reached from outside |
| Jellyfin | No (VPN-only) | Media streaming; no reason to expose publicly |
| Sonarr / Radarr | No (VPN-only) | Media automation; no reason to expose publicly |
| qBittorrent | No (VPN-only) | Downloads; should never be publicly exposed |
| Prowlarr | No (VPN-only) | Indexer manager; VPN-only |
| wg-easy | No (VPN-only) | WireGuard admin UI; must be VPN-only |
| Redis | No (internal) | Session store; never exposed |
| notify_push | No (internal) | Nextcloud push; internal only |

## Network Layout

```
┌─────────────────────────────────────────────────────┐
│  Internet                                           │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  VPS (YOUR_VPS_IP)                          │   │
│  │                                             │   │
│  │  Port 443 ──► Caddy (host network)          │   │
│  │                ├── cloud.YOUR_DOMAIN         │   │
│  │                │     └──► Nextcloud :80      │   │
│  │                └── brain.YOUR_DOMAIN         │   │
│  │                      └──► Research Brain     │   │
│  │                            :8001             │   │
│  │                                             │   │
│  │  Port 51820/UDP ──► WireGuard               │   │
│  │                      └── VPN: 10.8.0.0/24   │   │
│  │                            ├── wg-easy       │   │
│  │                            ├── Pi-hole       │   │
│  │                            ├── Jellyfin      │   │
│  │                            └── Arr-stack     │   │
│  │                                             │   │
│  │  Port 80 ──► Pi-hole (DNS, not HTTP)        │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

## Why this split?

**Public services** need to reach any network — from a coffee shop, a mobile connection, or a friend's WiFi. Putting them behind a VPN would mean setting up WireGuard on every device that might need Nextcloud access, which defeats the purpose of a personal cloud.

**VPN-only services** have no use case that requires public access. Jellyfin is only ever watched from home or from a device that already has WireGuard installed. The arr-stack tools are admin interfaces. Keeping them off the public internet eliminates a whole category of attack surface.

**The arr-stack has an extra layer:** download traffic is also routed through Private Internet Access VPN via Gluetun. This means the VPS provider (DigitalOcean) doesn't see the download traffic — only the PIA servers do. Combined with WireGuard for admin access, the arr-stack effectively has two VPN layers: one for privacy, one for admin isolation.

## Port Ownership Conflicts

The biggest constraint shaping this architecture: **Pi-hole owns port 80**.

Pi-hole runs as a DNS server, but it also serves its own web UI on port 80. This means nothing else can bind port 80 on the host — including Caddy.

Caddy normally uses HTTP-01 ACME challenges (serving `/.well-known/acme-challenge/` on port 80) to get Let's Encrypt certificates. That path is blocked here.

The solution is **DNS-01 challenges via the Cloudflare API**: Caddy proves domain ownership by writing a `_acme-challenge` TXT record to Cloudflare's DNS instead of serving an HTTP response. This requires a Cloudflare API token but has a nice side effect: HTTPS certs work even for domains that don't need public HTTP access.

## Docker Networking

Caddy runs with `network_mode: host`, which means it lives on the host network namespace and reaches other services by IP address (not by Docker container name). All other services use Docker bridge networking internally.

The Nextcloud + Redis + notify_push stack uses a shared Docker bridge network (`172.18.0.0/16`). Caddy reaches Nextcloud directly at its bridge IP.

Research Brain is a single container, loopback-bound (`127.0.0.1:8001`) — Caddy reaches it via loopback. No Docker network needed for a single-container app.

## Storage Architecture

```
B2 Bucket: "watermelon1" (Nextcloud primary storage)
  └── All Nextcloud files live here — the VPS disk holds only metadata + cache

B2 Bucket: "Blacktape" (everything else)
  ├── backups/nextcloud/     ← nightly SQLite DB snapshot
  ├── backups/vps-config/    ← weekly config repo tarball
  └── media/                 ← TV shows and movies backed up from VPS local storage
```

Nextcloud uses B2 as its **primary object store** (not a sync target) — files are written directly to B2 via the S3-compatible API, never to local disk. This keeps the 50 GB VPS disk free for everything else.

Jellyfin reads media from B2 via an rclone FUSE mount (`/mnt/b2-media/`). It doesn't use the Nextcloud B2 bucket — it has its own dedicated media bucket, keeping the two completely isolated.
