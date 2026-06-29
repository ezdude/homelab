# Chapter 3: Pi-hole + DNS-over-HTTPS

## What Pi-hole does

Pi-hole is a network-wide ad blocker that works at the DNS level. Rather than installing a browser extension on every device, DNS queries for ad/tracking domains return `0.0.0.0` (blocked) before the connection is ever made. This blocks ads on apps, smart TVs, and anywhere a browser extension can't reach.

By routing WireGuard clients' DNS through Pi-hole (`WG_DEFAULT_DNS=10.8.0.1`), every device on the VPN gets ad blocking without any per-device configuration.

## The port 80 problem

Pi-hole runs its web admin UI on port 80. This is the detail that shapes everything about how Caddy is configured in this stack.

Port 80 is taken. Caddy cannot bind it. This means:
- Caddy cannot use HTTP-01 ACME challenges (which require serving a response on port 80)
- Any HTTP-to-HTTPS redirect from Caddy would fail
- Caddy's global `auto_https` redirect must be disabled

The Caddy configuration has `auto_https disable_redirects` at the global level specifically because of Pi-hole. See Chapter 4 for the full Caddy story.

## DNS-over-HTTPS with stubby

Plain DNS queries are unencrypted and visible to your ISP, the VPS provider, and anyone watching the network between the VPS and the upstream resolver. DNS-over-HTTPS (DoH) encrypts those queries inside HTTPS.

The original plan was to use `cloudflared` as the DoH proxy for Pi-hole. It's the commonly recommended approach. However, `cloudflared` removed its `proxy-dns` feature in version 2026.2.0, breaking the setup.

A second candidate, `dnscrypt-proxy`, had a socket activation conflict with systemd on this Ubuntu install.

**The fix: stubby.** Stubby is a lightweight DoH/DoT proxy that's in the Ubuntu repos and has no conflicting dependencies. It listens on `127.0.0.1:5053` and forwards queries to Cloudflare's DoH endpoint (`1.1.1.1`).

```yaml
# Pi-hole docker-compose snippet (in wirehole stack)
pihole:
  image: pihole/pihole:latest
  environment:
    - PIHOLE_DNS_=127.0.0.1#5053  # forward to stubby on the host
    - WEBPASSWORD=${PIHOLE_WEBPASSWORD}
  ports:
    - "53:53/tcp"
    - "53:53/udp"
    - "80:80/tcp"    # ← takes port 80 on the host
  network_mode: host
```

```yaml
# stubby is installed directly on the host (not in Docker)
# /etc/stubby/stubby.yml (key settings)
listen_addresses:
  - 127.0.0.1@5053  # Pi-hole points its upstream DNS here
upstream_recursive_servers:
  - address_data: 1.1.1.1
    tls_auth_name: "cloudflare-dns.com"
```

Pi-hole forwards its upstream DNS queries to `127.0.0.1:5053` (stubby), which encrypts them and sends them to Cloudflare over HTTPS. The result: ad-blocked, encrypted DNS for every VPN client.

## What I'd do differently

Start with stubby from the beginning instead of trying cloudflared first. cloudflared is more frequently cited in tutorials, but its CLI changes faster. Stubby is boring, stable, and does exactly one thing. For infrastructure that you don't want to think about, boring is good.

## What's next

With DNS sorted, the next piece is getting HTTPS working for public services — which requires solving the port 80 problem without port 80.

→ [Chapter 4: Caddy Reverse Proxy](04-caddy-reverse-proxy.md)
