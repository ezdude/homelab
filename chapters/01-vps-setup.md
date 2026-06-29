# Chapter 1: VPS Setup & Basics

## The machine

DigitalOcean droplet — 1 vCPU, 2 GB RAM, 50 GB SSD, Ubuntu 22.04 LTS. At the time of writing this runs around $12/month. It's a tight machine: with 7+ Docker containers and a FUSE mount, RAM headroom is real.

The VPS is the foundation. Everything else in this build runs on it.

## First decisions

**Why DigitalOcean?** Mostly familiarity and reliable network performance. For a personal homelab, the specific provider matters less than picking one and learning it. AWS or Linode would work identically for this stack.

**Why Ubuntu 22.04?** LTS, well-supported, and all the packages needed (Docker, WireGuard, fail2ban, rclone, stubby) are either in the official repos or have straightforward install paths. Not an exciting choice — that's the point.

**Why not a dedicated server or Raspberry Pi?**
- Dedicated servers cost more and require more maintenance
- A Pi at home ties uptime to home internet, home power, and your ISP's IP changes
- A VPS gives you a stable public IP, offsite redundancy, and no hardware to manage

## Initial setup

After provisioning, the first things that go on the server:

```bash
# System update
apt update && apt upgrade -y

# Docker (official install — not the distro package)
curl -fsSL https://get.docker.com | sh

# rclone (for B2 FUSE mount and backups)
curl https://rclone.org/install.sh | bash

# stubby (DNS-over-HTTPS proxy — needed by Pi-hole chapter)
apt install -y stubby

# fail2ban
apt install -y fail2ban

# SQLite (for Nextcloud and Jellyfin maintenance)
apt install -y sqlite3
```

## Firewall

UFW is the primary firewall. The rules are simple — allow only what's needed:

```bash
ufw allow 22/tcp      # SSH
ufw allow 51820/udp   # WireGuard
ufw allow 443/tcp     # HTTPS (Caddy)
ufw enable
```

Port 80 is NOT opened. Pi-hole runs on it, but it only needs to be reachable internally (by containers), not from the internet. Caddy uses DNS-01 for certs (see Chapter 4) so it never needs port 80 either.

## The Docker firewall problem

Docker has a well-known issue: it modifies iptables directly and can bypass UFW rules. If you add a UFW DENY rule for a port but Docker is publishing that port, the port may still be reachable from the internet.

The fix is a custom iptables rule that prevents Docker from forwarding packets that weren't explicitly allowed by UFW. This rule is set up as a systemd service so it runs every time Docker or the server restarts:

```ini
# /etc/systemd/system/docker-firewall.service
[Unit]
Description=Restore Docker bypass iptables rules
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/restore-docker-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The script adds an iptables rule that drops forwarded packets to/from the Docker bridge unless they're explicitly allowed. Without this, any container with a published port is reachable from the internet regardless of UFW.

## What I'd do differently

I'd add the Docker firewall fix on day one rather than discovering the gap later. The interaction between Docker and UFW is non-obvious and the documentation doesn't surface it prominently — it requires actively looking for the issue to find it.

## What's next

With a secure base, the next layer is the VPN. WireGuard lets me administer all VPN-only services as if I were on the same local network, from anywhere.

→ [Chapter 2: WireGuard VPN](02-wireguard-vpn.md)
