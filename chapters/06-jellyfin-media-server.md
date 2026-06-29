# Chapter 6: Jellyfin Media Server

## What Jellyfin does

Jellyfin is an open-source media server — the self-hosted equivalent of Plex or Emby. It organizes movies and TV shows, transcodes video for different clients, and provides a streaming interface accessible from web browsers, mobile apps, and smart TVs.

In this stack, Jellyfin is VPN-only. There's no use case that requires streaming from outside VPN-connected devices.

## The storage problem on a 50 GB VPS

The VPS has 50 GB of disk. A single Blu-ray rip can be 30-50 GB. The media library cannot live on the VPS disk.

The solution: media lives in a Backblaze B2 bucket (`Blacktape`), and Jellyfin reads it via an **rclone FUSE mount** at `/mnt/b2-media/`. Jellyfin sees `/mnt/b2-media/` as a local directory — it has no idea it's reading from object storage in a datacenter.

## rclone FUSE mount: the VFS cache mode matters

rclone's FUSE mode has several caching options. The wrong one breaks video seeking.

**`--vfs-cache-mode writes`** (not used): Reads stream directly from B2 on demand. For a video player requesting a specific byte range mid-file (which is what seeking does), this causes rclone to fetch that range cold from B2. Long pause every time you seek.

**`--vfs-cache-mode full`** (what's running): rclone downloads the full file to a local cache on first access, then serves reads from the cache. Seeking is instant after the initial buffer. `--vfs-read-ahead 512M` pre-buffers ahead of the playback position.

The tradeoff: a large file is downloaded entirely on first play. On a fast VPS connection this is fast, but it means Jellyfin can't "start playing immediately" for very large files.

```bash
rclone mount b2-media:YOUR_MEDIA_BUCKET /mnt/b2-media \
  --vfs-cache-mode full \
  --vfs-read-ahead 512M \
  --dir-cache-time 24h \
  --fast-list \
  --no-modtime \
  --allow-other
```

`--dir-cache-time 24h` prevents rclone from hitting the B2 API every 5 minutes (the default) to refresh the directory listing. B2 charges for API calls — Class B operations like listing are free up to 2,500/day, but unnecessary calls add up.

`--no-modtime` avoids fetching modification times for every file during listing, which would be additional API calls.

## Why writes go through rclone CLI, not the FUSE mount

Early testing wrote large files through the FUSE mount. This froze the VPS — rclone's write buffering under load was overwhelming the 2 GB RAM with a single download.

The fix: writes to B2 always go through the rclone CLI (`rclone copy`, not the FUSE mount), which has explicit bandwidth limiting and better memory management. The FUSE mount is read-only for Jellyfin's purpose.

`rclone copy` with `--bwlimit 18M` (measured at ~65% of VPS uplink capacity) leaves headroom for the other services while uploading to B2.

## The arr-stack writes locally, not to B2

Sonarr and Radarr cannot reliably validate paths on FUSE-mounted filesystems. Directory listings and file existence checks behave inconsistently through FUSE.

Instead: downloaded media is stored locally at `/opt/arr-stack/tv/` and `/opt/arr-stack/movies/`, organized and ready to seed. A separate script (`backup-to-b2.sh`) handles copying finished media to B2. Jellyfin reads from B2 FUSE mount, not from the local arr-stack directories.

## Hard links: organizing without breaking seeding

When a download is complete and organized (moved into the proper `/movies/Title (Year)/` structure), qBittorrent needs to keep seeding from its original download path. Moving the file would break seeding.

The organize script uses **hard links** (`cp -al`) instead of moves:
- Both paths (`/downloads/file` and `/movies/Movie/file`) point to the same inode on disk
- No extra disk space used
- qBittorrent keeps seeding from `/downloads/` — it sees its file unchanged
- Jellyfin (or rclone, when backing up) reads from the organized path

This only works because downloads, movies, and TV all live on the same filesystem (`/dev/vda1`). Hard links can't span filesystems.

## The systemd FUSE mount service

The rclone mount starts as a systemd service so it comes back after reboots:

```ini
# /etc/systemd/system/rclone-b2media.service
[Unit]
Description=rclone B2 media FUSE mount
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=rclone mount b2-media:YOUR_MEDIA_BUCKET /mnt/b2-media \
    --vfs-cache-mode full \
    --vfs-read-ahead 512M \
    --dir-cache-time 24h \
    --fast-list \
    --no-modtime \
    --allow-other
ExecStop=/bin/fusermount -uz /mnt/b2-media
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Jellyfin's Docker container must start after this service is ready (using `depends_on` or startup order) — if Jellyfin starts before the mount is available, it sees an empty `/mnt/b2-media/` and caches that as the library state.

## What's next

Jellyfin streams the media, but the arr-stack is what populates it automatically — monitoring for new releases and managing downloads.

→ [Chapter 7: Arr-stack: Automated Media](07-arr-stack-media-automation.md)
