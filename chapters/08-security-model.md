# Chapter 8: Security Model

## Layers of defense

The security model is layered, with each layer handling a different threat:

1. **UFW firewall** — blocks ports that aren't needed
2. **Docker firewall fix** — prevents Docker from bypassing UFW
3. **VPN isolation** — admin services unreachable without WireGuard
4. **Application authentication** — public services require login
5. **fail2ban** — rate-limits and bans brute-force attempts
6. **Least privilege** — secrets in `.env` files, not compose files

## UFW + Docker: the bypass problem

UFW is the standard Ubuntu firewall. Docker has a known behavior: it modifies iptables directly and can make published container ports reachable from the internet even when UFW has a DENY rule for that port.

This isn't a Docker bug per se — it's working as designed. Docker adds its own iptables chains (`DOCKER`, `DOCKER-USER`) that run before the UFW rules. A DENY in UFW for port 8989 won't stop traffic if Docker has published port 8989 and added a forwarding rule.

The fix: a oneshot systemd service that runs after Docker starts and adds an iptables rule to the `DOCKER-USER` chain that drops forwarded packets except what's explicitly allowed:

```bash
# restore-docker-firewall.sh (simplified)
iptables -I DOCKER-USER -i eth0 ! -s 10.8.0.0/24 -j DROP
# Drops packets from the internet that Docker is forwarding, 
# except from our VPN subnet (10.8.0.0/24)
```

This means arr-stack ports (8989, 7878, 8080, 9696) are Docker-published but only reachable from WireGuard clients. UFW alone wouldn't be enough.

## fail2ban jails

fail2ban watches log files for patterns indicating brute-force attacks and bans offending IPs via iptables. Each public service has its own jail:

**Nextcloud:**
- Watches Nextcloud's failed login logs
- Bans IPs after 5 failures in 10 minutes for 1 hour

**Jellyfin:**
- Watches Jellyfin's auth failure logs
- Same thresholds

**SSH:**
- Default sshd jail (comes with fail2ban)

**Research Brain:**
- Custom filter watching the app's login failure log (piped from Docker container logs via `researchbrain-log.service`)
- Same thresholds

The `jail.local` file (in `/etc/fail2ban/jail.local`) sets the global defaults and critically: **whitelists the home IP and the WireGuard VPN subnet** (`10.8.0.0/24`). This prevents accidentally banning myself during normal admin activity.

```ini
# /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 10.8.0.0/24 YOUR_HOME_IP/32
bantime  = 3600
findtime = 600
maxretry = 5
```

## Connecting container logs to fail2ban

fail2ban watches files, not Docker log streams. Getting Research Brain's logs into a file that fail2ban can watch required a systemd service that pipes Docker logs to a file:

```ini
# /etc/systemd/system/researchbrain-log.service
[Service]
ExecStart=/bin/sh -c "docker logs -f --tail 0 research-brain >> /var/log/researchbrain.log 2>&1"
Restart=always
RestartSec=5
```

This service starts after Docker, follows the container's log output, and appends to `/var/log/researchbrain.log`. fail2ban watches that file with its `polling` backend (since it's being appended to externally).

The same pattern works for any Dockerized service that needs fail2ban integration.

## Secrets management

Early versions of the compose files had secrets (passwords, API keys) hardcoded in the `docker-compose.yml`. This is wrong for two reasons:
1. Compose files are often version-controlled, which means secrets end up in git
2. `docker inspect` can reveal environment variables set directly in compose

The fix: all secrets moved to `.env` files, loaded with `env_file:` in compose. The `.env` files are gitignored (`/etc/gitignore` and the repo's `.gitignore` both exclude them), `chmod 600`, and only root-readable.

The vps-config git repo only stores `.env.example` files with placeholder values — never the actual `.env` files.

## HTTPS everywhere for public services

Both Nextcloud and Research Brain are served over HTTPS via Caddy with DNS-01 Let's Encrypt certs. HTTP is not offered (Caddy's `auto_https disable_redirects` prevents HTTP-to-HTTPS redirects, but there's also nothing listening on port 80 for these services — Pi-hole has that port). Browsers that request `http://brain.YOUR_DOMAIN` simply get no response; they need to use `https://`.

HSTS headers are set on both services:
```
header Strict-Transport-Security "max-age=15552000;"
```

This tells browsers to only ever connect via HTTPS for the next 180 days, even if the user types `http://`.

## What's next

With security sorted, the backup strategy ties everything together — making sure configuration, data, and media can be recovered if something goes wrong.

→ [Chapter 9: Backup Strategy](09-backup-strategy.md)
