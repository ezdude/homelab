# Chapter 2: WireGuard VPN

## The problem this solves

Running a VPS means you have services that you want to access from anywhere — but that doesn't mean you want them accessible by *anyone*. Jellyfin, the arr-stack tools, and all admin interfaces should only be reachable by you.

The naive approach is to lock them down to your home IP. But then you can't access them from a coffee shop or while traveling. And if your home ISP assigns dynamic IPs, the allowlist breaks regularly.

A VPN is the cleaner answer: you install a WireGuard client on every device you own, and anything behind the VPN is reachable from all of them — from anywhere — without being reachable from the internet at large.

## Why WireGuard (not OpenVPN)?

WireGuard is the modern choice:
- Significantly faster than OpenVPN due to being in the kernel
- Much simpler configuration (a few lines vs pages of OpenVPN config)
- Smaller attack surface (fewer lines of code)
- Built into the Linux kernel since 5.6 — no kernel module fiddling

The main tradeoff is that WireGuard is a Layer 3 VPN only (IP routing, not a full tunnel with DNS handling) — but that's fine here since Pi-hole handles DNS separately.

## wg-easy

Rather than managing WireGuard config files manually, I use [wg-easy](https://github.com/wg-easy/wg-easy) — a Docker container that provides a web UI for adding/removing peers, viewing connection status, and downloading QR codes for mobile setup.

It runs on port 51821, which is only reachable via the VPN itself. The initial setup requires connecting once directly (before the VPN is up), then all future peer management is done via the web UI at `http://10.8.0.1:51821`.

```yaml
# From configs/wirehole/docker-compose.yml
wg-easy:
  image: ghcr.io/wg-easy/wg-easy
  environment:
    - WG_HOST=YOUR_VPS_IP
    - PASSWORD_HASH=${WG_PASSWORD_HASH}  # bcrypt hash
    - WG_DEFAULT_DNS=10.8.0.1           # routes DNS through Pi-hole on the VPN
  volumes:
    - wg-easy-data:/etc/wireguard
  ports:
    - "51820:51820/udp"  # VPN port — must be public
    - "51821:51821/tcp"  # web UI — blocked at UFW level, only reachable via VPN
  cap_add:
    - NET_ADMIN
    - SYS_MODULE
  sysctls:
    - net.ipv4.conf.all.src_valid_mark=1
    - net.ipv4.ip_forward=1
  network_mode: host
```

## VPN subnet

WireGuard uses `10.8.0.0/24`. The VPS host is `10.8.0.1` (reachable once VPN is up). Client peers get IPs in `10.8.0.2/24` and up.

This matters for other services: Caddy runs on host network and reaches Nextcloud at `172.18.0.10` (Docker bridge IP), but fail2ban and other host tools see WireGuard client IPs as the source of requests. The `10.8.0.0/24` subnet is allowlisted in fail2ban to prevent accidentally banning my own VPN IP.

## What I'd do differently

The WireGuard setup itself was smooth. The only catch: the `WG_DEFAULT_DNS` setting routes VPN clients' DNS through Pi-hole on `10.8.0.1`, which means Pi-hole needs to be running before VPN clients can resolve DNS. The bring-up order matters: WireGuard → Pi-hole. If Pi-hole crashes, VPN clients lose DNS. This is the right trade-off (you get ad blocking everywhere) but it's worth knowing.

## What's next

With WireGuard up, VPN clients can reach `10.8.0.1` and the VPN subnet. The next piece is DNS — Pi-hole running on that `10.8.0.1` address, with DNS-over-HTTPS for privacy.

→ [Chapter 3: Pi-hole + DNS-over-HTTPS](03-pihole-dns-over-https.md)
