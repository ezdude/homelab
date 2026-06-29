# Chapter 9: Backup Strategy

## What needs to be backed up

Three categories of things can be lost:

| Category | What it is | Recovery if lost |
|---|---|---|
| **Files** (Nextcloud) | Documents, photos, Obsidian notes | Very bad — personal data loss |
| **Media** (Jellyfin) | Movies, TV shows | Bad but replaceable |
| **Configuration** | Docker compose files, Caddyfile, scripts | Recoverable with effort |
| **Database** (Nextcloud) | File metadata, shares, user data | Bad — files exist in B2 but Nextcloud can't index them |

## Files: Nextcloud primary storage on B2

Nextcloud's files live in Backblaze B2 as primary object storage (not a sync target). B2 has built-in versioning and deletion protection — deleted files can be restored for up to 30 days by default, longer if configured.

This means the primary "backup" for Nextcloud files is B2 itself. The file data is already in object storage with redundancy. What additionally needs backing up is the **database** — without it, Nextcloud can't map its internal file IDs to the B2 objects.

## Database: nightly SQLite snapshot

Nextcloud's database is SQLite (appropriate for a single-user personal instance — no concurrent writes, simple to back up). A nightly cron job creates an atomic hot snapshot using `sqlite3 .backup` and uploads it to B2:

```bash
# nextcloud-db-backup.sh (simplified)
DOW=$(date +%A)  # Monday, Tuesday, etc. — 7-day rolling window
BACKUP_FILE="nc-backup-${DOW}.tar.gz"

# Atomic hot snapshot — no maintenance mode needed
docker exec nextcloud sqlite3 /var/www/html/data/owncloud.db ".backup /tmp/nc-backup.db"
docker cp nextcloud:/tmp/nc-backup.db /tmp/nc-backup.db

# Also backup config.php (contains objectstore credentials)
docker cp nextcloud:/var/www/html/config/config.php /tmp/nc-config.php

# Tar and upload to B2
tar czf "/tmp/$BACKUP_FILE" -C /tmp nc-backup.db nc-config.php
rclone copy "/tmp/$BACKUP_FILE" "b2-backup:YOUR_B2_BUCKET/backups/nextcloud/"

# Cleanup
rm /tmp/nc-backup.db /tmp/nc-config.php "/tmp/$BACKUP_FILE"
```

The day-of-week slot naming (`nc-backup-Monday.tar.gz`, etc.) gives a 7-day rolling window automatically — each backup overwrites the same slot from 7 days ago. No cleanup script needed.

`sqlite3 .backup` is an atomic hot backup — it creates a consistent snapshot without putting Nextcloud into maintenance mode. This means the cron can run at 3 AM without any service interruption.

## Configuration: git repo + B2 tarball + GitHub

The `/root/vps-config/` git repo (this repo's private counterpart) tracks all config files. Any time a config file changes, the workflow is:

```bash
cd /root/vps-config
./sync.sh          # copies live files into the repo
git diff           # review
git add -A && git commit -m "describe change"
git push           # mirrors to GitHub (private repo)
```

Off-box redundancy has two layers:
- **GitHub** (private repo): accessible from any machine, full git history
- **B2 tarball**: weekly snapshot of the full repo including `.git` history

```bash
# vps-config-backup.sh (simplified)
DOW=$(date +%A)
tar czf "/tmp/vps-config-${DOW}.tar.gz" -C /root vps-config
rclone copy "/tmp/vps-config-${DOW}.tar.gz" \
    "b2-backup:YOUR_B2_BUCKET/backups/vps-config/"
rm "/tmp/vps-config-${DOW}.tar.gz"
```

Weekly cron: `0 4 * * 0` (Sunday, 04:00). Same 7-day rolling window pattern.

## Media: manual backup with bwlimit

Media (movies, TV) downloaded by the arr-stack is stored locally at `/opt/arr-stack/tv/` and `/opt/arr-stack/movies/`. A manual `backup-to-b2.sh` script copies finished media to B2 when ready:

```bash
# backup-to-b2.sh (simplified)
rclone copy \
    --bwlimit 18M \        # ~65% of VPS uplink — leaves headroom for other services
    --progress \
    /opt/arr-stack/movies/ \
    b2-backup:YOUR_MEDIA_BUCKET/media/movies/
```

The `--bwlimit 18M` was chosen by measuring peak VPS→B2 throughput (28 MB/s) and targeting 65% to leave room for WireGuard, Nextcloud, and Jellyfin traffic to coexist.

Media backup is manual, not automated, because:
1. Downloads are still in progress — backing up mid-download wastes bandwidth
2. Hard-linked seeding duplicates: Jellyfin-organized paths and download paths point to the same inode, so both would be backed up if not careful
3. Media is replaceable; the timing isn't critical

## Logrotate for all custom log files

Every script and service that writes logs has a corresponding logrotate config:

```
/etc/logrotate.d/b2-backup
/etc/logrotate.d/b2-manage
/etc/logrotate.d/jellyfin-manage
/etc/logrotate.d/vps-config-backup
```

All use the same pattern: daily rotation, 7 copies kept, compressed, `copytruncate` (so scripts can keep writing without needing to reopen file descriptors), and `missingok` (don't error if the log doesn't exist yet).

## What's NOT backed up

- **WireGuard peer private keys** — intentionally not in any backup. Losing them means re-generating and re-distributing peer configs. Acceptable; the keys themselves are the security.
- **rclone config** (`~/.config/rclone/rclone.conf`) — contains B2 API credentials. Backed up only in memory; easy to regenerate from B2 dashboard.
- **Media during download** — if the VPS is lost mid-download, those downloads are lost. Acceptable.
- **Jellyfin database** — if lost, Jellyfin rescans the library and rebuilds it. Slow but automatic. Not worth the backup complexity.

## What's next

The final piece is the Research Brain — an AI-powered research app built on top of all this infrastructure.

→ [Chapter 10: Research Brain AI App](10-research-brain-ai-app.md)
