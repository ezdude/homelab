# Chapter 5: Nextcloud + Backblaze B2

## Why Nextcloud

Nextcloud is an open-source personal cloud — file sync, contacts, calendar, photo backup, and more. The self-hosted alternative to iCloud or Google Drive.

The critical constraint on a 50 GB VPS SSD: storing files locally would fill the disk quickly. The solution is using Backblaze B2 as Nextcloud's **primary object store** — files are written directly to B2 via the S3-compatible API, never touching the VPS disk. The VPS only stores Nextcloud metadata, caches, and the database.

## B2 as primary storage (not sync)

There's an important distinction between B2 as sync target vs. B2 as primary storage:

- **Sync:** files are written to local disk first, then synced to B2 as a backup copy. Disk space used.
- **Primary storage:** files go directly to B2. Local disk only holds metadata. This is what's running here.

Nextcloud supports S3-compatible object stores as primary storage via `config.php`:

```php
'objectstore' => [
    'class' => '\\OC\\Files\\ObjectStore\\S3',
    'arguments' => [
        'bucket'          => 'YOUR_B2_BUCKET_NAME',
        'autocreate'      => false,
        'key'             => 'YOUR_B2_KEY_ID',
        'secret'          => 'YOUR_B2_APPLICATION_KEY',
        'hostname'        => 's3.us-west-004.backblazeb2.com',  // your B2 region endpoint
        'port'            => 443,
        'use_ssl'         => true,
        'region'          => 'us-west-004',
        'use_path_style'  => true,
        'uploadPartSize'  => 5368709120,  // 5 GB (see pitfall below)
        'putSizeLimit'    => 5368709120,
    ],
],
```

**Caveat:** Once Nextcloud is configured with B2 as primary storage and you've added files, you cannot change the object store without migrating all files. This is an early decision that locks in.

## The multipart upload bug

Nextcloud's S3 library has a bug with B2's S3-compatible API: **multipart uploads fail** with `Aws\Exception\MultipartUploadException`. This was first hit uploading a 100 MB file.

Multipart upload kicks in above a certain file size threshold. The fix is to raise that threshold above any file you'd realistically upload through Nextcloud's web/desktop interface:

```php
'uploadPartSize' => 5368709120,  // 5 GB
'putSizeLimit'   => 5368709120,
```

This forces single PUT for files up to 5 GB (B2's maximum for a single PUT). Files larger than 5 GB cannot go through Nextcloud — use rclone directly to B2 instead (rclone uses B2's native API, which doesn't have this problem).

## Apache timeout for large uploads

The default Apache `Timeout 300` (5 minutes) kills large single-PUT uploads mid-stream. The fix is a custom Apache config mounted into the container:

```apache
# /opt/wirehole/nextcloud-conf/zz-timeout.conf
Timeout 7200
# Note: ProxyTimeout is NOT set — mod_proxy isn't loaded in the Nextcloud image
```

This file is mounted into the container at `/etc/apache2/conf-enabled/zz-timeout.conf:ro`. The `:ro` flag and the mount path ensure it survives container rebuilds — it's not an in-container edit that gets lost on restart.

## notify_push and Redis

By default, Nextcloud desktop clients poll the server every 30 seconds to check for changes. On a constrained VPS, 3+ clients all polling every 30s creates constant CPU load.

`notify_push` is Nextcloud's push notification service: the server notifies clients immediately when something changes, so clients don't need to poll. This dropped idle CPU usage from ~48% to ~3.76%.

notify_push requires Redis for message queuing. The configuration:

```yaml
redis:
  image: redis:7-alpine
  networks:
    - nc-network

notify_push:
  image: nextcloud/notify_push:latest
  environment:
    - NEXTCLOUD_URL=http://172.18.0.10  # internal, bypasses Caddy
  networks:
    - nc-network
```

The `NEXTCLOUD_URL` points to the Nextcloud container directly (not through Caddy). This avoids a routing loop: if notify_push went through Caddy → Nextcloud, the `X-Forwarded-Proto` headers would need to match exactly, and latency would be added. Direct internal routing is simpler and faster.

## The overwriteprotocol decision

`overwriteprotocol = https` must be set in `config.php` to force Nextcloud to generate HTTPS URLs in all responses.

Without it, most pages work correctly (because the `X-Forwarded-Proto: https` header is trusted). But the desktop client Login Flow v2 endpoint (`/index.php/login/v2`) generates `http://` URLs for its `poll.endpoint` and `login` fields — those URLs are hardcoded using a code path that doesn't honor the forwarded header. The desktop client then fails with "URL returned from server does not start with https."

Tradeoff: setting this means the direct internal URL `http://nextcloud-container:8080` generates HTTPS links, which makes direct access (bypassing Caddy) non-functional. The correct access path is always `https://cloud.YOUR_DOMAIN` over the VPN.

## Cloudflare DNS: gray-cloud (not proxied)

The `cloud.YOUR_DOMAIN` DNS record points directly to the VPS IP with Cloudflare proxy **disabled** (gray cloud / DNS-only). Nextcloud + Cloudflare proxy has known compatibility issues with large file transfers. DNS-only means Cloudflare sees only DNS queries, not traffic.

## What's next

With Nextcloud serving files from B2, the media stack goes in next — Jellyfin for streaming and the arr-stack for automation.

→ [Chapter 6: Jellyfin Media Server](06-jellyfin-media-server.md)
