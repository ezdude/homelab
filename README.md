# Blacktape Homelab

A privacy-focused, fully self-hosted personal cloud running on a single $12/month DigitalOcean VPS.

## What's running

| Service | Exposure | Purpose |
|---|---|---|
| **WireGuard VPN** | Public UDP 51820 | Admin access tunnel — all internal services are VPN-only |
| **Pi-hole + stubby** | Internal | Ad-blocking DNS with DNS-over-HTTPS to Cloudflare |
| **Nextcloud** | Public HTTPS | Personal cloud storage (files, photos, contacts, Obsidian sync) |
| **Caddy** | Public 443 | Reverse proxy with DNS-01 HTTPS certs via Cloudflare API |
| **Jellyfin** | VPN-only | Media streaming server (reads from B2 via rclone FUSE mount) |
| **Sonarr + Radarr + qBittorrent + Prowlarr** | VPN-only + PIA | Automated media, routed through PIA VPN via Gluetun |
| **Redis** | Internal | Session locking + Nextcloud push notifications (notify_push) |
| **Research Brain** | Public HTTPS (authed) | Personal RAG + AI synthesis app (FastAPI + ChromaDB + Gemini) |
| **Backblaze B2** | External storage | Nextcloud primary storage + media archive + config backups |

**Hardware:** 1 vCPU, 2 GB RAM, 50 GB SSD — Ubuntu 22.04 LTS. Everything runs in Docker.

## Architecture overview

```
Internet
  │
  ├─── :443 HTTPS ──► Caddy (host network) ──► Nextcloud (public)
  │                                         └──► Research Brain (public, authed)
  │
  ├─── :51820 UDP ──► WireGuard VPN (10.8.0.0/24)
  │                     │
  │                     ├── wg-easy web UI (VPN-only)
  │                     ├── Pi-hole admin (VPN-only)
  │                     ├── Jellyfin :8096 (VPN-only)
  │                     └── Arr-stack :8989/:7878/:8080/:9696 (VPN-only)
  │
  └─── :80 ──► Pi-hole (DNS, NOT HTTP — blocks Caddy from using port 80)
```

Key constraint: Pi-hole owns port 80, so Caddy uses DNS-01 challenge (Cloudflare API) for all HTTPS certs — never needs to bind port 80.

## The full story

Read the chapters in order for the build log — decisions, constraints, pitfalls, and lessons:

1. [VPS Setup & Basics](chapters/01-vps-setup.md)
2. [WireGuard VPN](chapters/02-wireguard-vpn.md)
3. [Pi-hole + DNS-over-HTTPS](chapters/03-pihole-dns-over-https.md)
4. [Caddy Reverse Proxy](chapters/04-caddy-reverse-proxy.md)
5. [Nextcloud + Backblaze B2](chapters/05-nextcloud-b2-storage.md)
6. [Jellyfin Media Server](chapters/06-jellyfin-media-server.md)
7. [Arr-stack: Automated Media](chapters/07-arr-stack-media-automation.md)
8. [Security Model](chapters/08-security-model.md)
9. [Backup Strategy](chapters/09-backup-strategy.md)
10. [Research Brain: AI App](chapters/10-research-brain-ai-app.md)

## Want to replicate this?

The `configs/` directory has generalized versions of all docker-compose files and key configs — with `YOUR_DOMAIN`, `YOUR_VPS_IP`, `YOUR_B2_BUCKET` placeholders instead of real values.

The `scripts/` directory has the maintenance scripts (backup, update, DB snapshot) generalized the same way.

Each chapter explains what needs to be adapted for your setup. This isn't a one-command deploy — it's a documented reference for building something similar deliberately.

**Prerequisites:** Docker, a domain on Cloudflare, a Backblaze B2 account, and a VPS running Ubuntu.

## Why document this?

Building and maintaining this stack taught me a lot about how production infrastructure actually works — port conflicts, VPN routing, reverse proxy quirks, API compatibility, backup strategies. This repo is the write-up I wish had existed when I started.
