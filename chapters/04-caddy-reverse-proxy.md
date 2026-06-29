# Chapter 4: Caddy Reverse Proxy

## Why Caddy

Caddy is a modern reverse proxy that handles HTTPS automatically. Unlike nginx, you don't write a separate certbot cron job and then reference the cert files — Caddy manages certificate issuance and renewal internally.

More importantly for this stack: Caddy has first-class support for DNS-01 ACME challenges via community plugins. This is the critical capability given that port 80 is unavailable (Pi-hole owns it — see Chapter 3).

## DNS-01 vs HTTP-01 certificate challenges

Let's Encrypt verifies domain ownership in one of two ways:

**HTTP-01:** Serve a specific file at `http://yourdomain.com/.well-known/acme-challenge/<token>`. Simple, but requires port 80 to be bound and publicly accessible.

**DNS-01:** Create a specific `_acme-challenge.yourdomain.com` TXT record in DNS. The ACME server checks the record via DNS lookup — no HTTP involved, no port 80 needed.

DNS-01 requires API access to your DNS provider. Since the domain is on Cloudflare, I use Caddy's `caddy-dns/cloudflare` plugin with a Cloudflare API token scoped to `Zone:DNS:Edit` on the `YOUR_DOMAIN` zone. Caddy writes and deletes the challenge TXT record automatically.

**Bonus:** DNS-01 works even for services that are never publicly accessible (like Nextcloud when it was VPN-only). You can get a real browser-trusted cert for a service that doesn't have a public IP.

## Custom Caddy build

The upstream Caddy Docker image doesn't include the Cloudflare DNS plugin. It requires a custom build using `xcaddy`:

```dockerfile
# configs/wirehole/caddy/Dockerfile
FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:latest
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

This is a multi-stage build: the `builder` stage compiles Caddy with the plugin, the final stage uses the official Caddy image with just the binary replaced. Keeps the image lean.

## The Caddyfile

The global settings prevent Caddy from attempting any port 80 binding:

```caddyfile
{
    auto_https disable_redirects
}

cloud.YOUR_DOMAIN {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy 172.18.0.10:80 {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    header Strict-Transport-Security "max-age=15552000;"
}

brain.YOUR_DOMAIN {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy 127.0.0.1:8001 {
        flush_interval -1    # required for SSE streaming
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    header Strict-Transport-Security "max-age=15552000;"
}
```

## Caddy runs on the host network

`network_mode: host` means Caddy lives in the host network namespace. It reaches services by IP:
- Nextcloud: `172.18.0.10` (Docker bridge IP)
- Research Brain: `127.0.0.1:8001` (loopback)

This matches the pattern used by wg-easy and Pi-hole in the same stack, and avoids the extra complexity of cross-network Docker routing.

## The trusted_proxies problem with Nextcloud

Nextcloud needs to trust the `X-Forwarded-Proto: https` header from Caddy so it generates HTTPS URLs (not HTTP). To trust that header, Nextcloud needs to know which IPs are legitimate proxies.

The expected answer would be `127.0.0.1` or `172.18.0.1` (the Docker bridge gateway). But Apache logs inside the Nextcloud container consistently showed `REMOTE_ADDR = 10.8.0.1` — the WireGuard interface IP — due to an iptables MASQUERADE rule that rewrites the source address.

Setting `trusted_proxies = 10.8.0.1` was the empirical fix. Anything else (including what appeared theoretically correct) broke `X-Forwarded-Proto` trust, causing Nextcloud to generate HTTP redirect URLs and fail login.

**Lesson:** For reverse-proxy trust chains in Docker, trust what Apache actually logs, not what the network diagram suggests.

## SSE streaming and flush_interval

The Research Brain app uses Server-Sent Events (SSE) for streaming AI responses token by token. By default, Caddy buffers the proxy response before forwarding it — which turns streaming into a single blob that arrives all at once.

The fix is `flush_interval -1` in the `reverse_proxy` block. This tells Caddy to forward each chunk immediately as it arrives, enabling real streaming.

**Important:** `X-Accel-Buffering: no` is nginx-specific and is ignored by Caddy. The only way to enable SSE streaming in Caddy is `flush_interval -1`.

## Reloading Caddy without downtime

Adding a new vhost (like `brain.YOUR_DOMAIN`) doesn't require restarting the container — Caddy supports config reload:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec caddy caddy reload   --config /etc/caddy/Caddyfile --adapter caddyfile
```

Always validate before reloading. A syntax error in the Caddyfile that causes a failed reload will leave the existing config running — but an outright crash would take down all services fronted by Caddy.

## What's next

With Caddy handling HTTPS for public services, the first major public service to deploy is Nextcloud.

→ [Chapter 5: Nextcloud + Backblaze B2](05-nextcloud-b2-storage.md)
