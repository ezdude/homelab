# Chapter 7: Arr-stack: Automated Media

## What the arr-stack is

"Arr-stack" refers to a suite of open-source media automation tools named with the `-arr` suffix:
- **Sonarr** — monitors TV shows, requests new episodes automatically
- **Radarr** — same for movies
- **Prowlarr** — indexer manager (replaces the older Jackett)
- **qBittorrent** — the download client

These tools work together: Prowlarr knows which indexer sites to search, Sonarr/Radarr request downloads from Prowlarr, which finds torrents, which are downloaded by qBittorrent. The whole flow runs automatically once configured.

## Privacy: two VPN layers

The arr-stack runs with two separate VPN layers for different purposes:

1. **WireGuard (admin):** The arr-stack web UIs are VPN-only — not reachable from the internet. All management goes through the WireGuard tunnel.

2. **Gluetun + PIA (download traffic):** All actual download traffic from qBittorrent is routed through Private Internet Access VPN via Gluetun. The VPS provider (DigitalOcean) never sees what's being downloaded — only PIA's servers do.

This is defense-in-depth: two separate threat models, two separate VPN layers.

## How Gluetun works

Gluetun is a Docker container that runs a VPN client (OpenVPN or WireGuard to PIA in this case) and acts as a network gateway for other containers.

Sonarr, Radarr, qBittorrent, and Prowlarr all connect to the internet through Gluetun's network namespace using Docker's `network_mode: service:gluetun`. None of them have their own internet access — all traffic goes through the PIA tunnel.

```yaml
# configs/arr-stack/docker-compose.yml (key sections)
services:
  gluetun:
    image: qmcgaw/gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=private internet access
      - OPENVPN_USER=${OPENVPN_USER}
      - OPENVPN_PASSWORD=${OPENVPN_PASSWORD}
      - SERVER_REGIONS=US East
    ports:
      # Expose arr-stack ports through Gluetun (VPN-only at UFW level)
      - "8989:8989"   # Sonarr
      - "7878:7878"   # Radarr
      - "8080:8080"   # qBittorrent
      - "9696:9696"   # Prowlarr

  sonarr:
    image: linuxserver/sonarr
    network_mode: "service:gluetun"   # all traffic via Gluetun
    # No ports — inherits from Gluetun

  qbittorrent:
    image: linuxserver/qbittorrent
    network_mode: "service:gluetun"
```

The ports are published through Gluetun's network namespace. From inside the container, everything appears to have Gluetun's interface as its default route. If Gluetun's VPN drops, the containers lose internet access entirely (kill switch behavior is implicit).

## Prowlarr over Jackett

The original standard indexer manager for this stack was Jackett. Prowlarr is the newer replacement that has become the standard:
- Prowlarr integrates directly with Sonarr/Radarr via API — no separate Torznab feed URLs to configure
- Prowlarr is actively maintained; Jackett is in maintenance mode
- Prowlarr's UI is more consistent with the rest of the arr-stack

Sonarr and Radarr connect to Prowlarr using `localhost` networking (they share Gluetun's network namespace, so they can reach each other directly without going through Docker networks).

## FlareSolverr: still pending

Some indexers (like 1337x) are protected by Cloudflare's bot detection, which blocks automated scraping. FlareSolverr is a service that solves Cloudflare challenges and proxies the requests, allowing Prowlarr to access these indexers.

FlareSolverr is not yet deployed in this stack — it's on the to-do list. Without it, Cloudflare-protected indexers simply fail in Prowlarr.

## What's next

With the services running, the next topic is how they're hardened — fail2ban, firewall rules, and the overall security model.

→ [Chapter 8: Security Model](08-security-model.md)
