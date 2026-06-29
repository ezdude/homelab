#!/usr/bin/env bash
# nextcloud-db-backup.sh
# Nightly backup of Nextcloud SQLite DB + config to Backblaze B2.
# Uses sqlite3's .backup for a safe hot snapshot — no maintenance mode needed.
# Stores 7 rolling copies named by day-of-week (Monday overwrites last Monday, etc.)
#
# Cron: 0 3 * * * /usr/local/bin/nextcloud-db-backup.sh >> /var/log/nextcloud-db-backup.log 2>&1
#
# Prerequisites: sqlite3, rclone (configured with a B2 remote named 'b2-backup')

set -euo pipefail

LOGFILE="/var/log/nextcloud-db-backup.log"
DB_SRC="/opt/wirehole/nextcloud/data/owncloud.db"   # adjust if your Nextcloud data path differs
CONFIG_SRC="/opt/wirehole/nextcloud/config"
STAGING="/tmp/nc-backup-staging"
DAY=$(date +%A)   # Monday, Tuesday, ... — 7-slot rolling window
ARCHIVE="/tmp/nc-backup-${DAY}.tar.gz"

# Replace with your actual rclone remote name and bucket path
B2_DEST="b2-backup:YOUR_B2_BUCKET/backups/nextcloud/nc-backup-${DAY}.tar.gz"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }

log "SESSION START — day slot: ${DAY}"

# Validate prerequisites
if [[ ! -f "$DB_SRC" ]]; then
    log "ERROR: DB not found at $DB_SRC — aborting"
    exit 1
fi
command -v sqlite3 &>/dev/null || { log "ERROR: sqlite3 not installed"; exit 1; }
command -v rclone  &>/dev/null || { log "ERROR: rclone not found"; exit 1; }

# Clean up any leftover staging from a previous failed run
rm -rf "$STAGING" "$ARCHIVE"
mkdir -p "$STAGING"

# Hot backup of SQLite DB — atomic, no maintenance mode needed
log "ACTION: sqlite3 hot backup owncloud.db -> staging"
sqlite3 "$DB_SRC" ".backup ${STAGING}/owncloud.db"

# Copy config dir (contains config.php with objectstore credentials + system settings)
log "ACTION: copying config dir -> staging"
cp -r "$CONFIG_SRC" "${STAGING}/config"

# Bundle into a compressed archive
log "ACTION: creating archive ${ARCHIVE}"
tar czf "$ARCHIVE" -C /tmp nc-backup-staging

# Upload to B2, overwriting the same day-of-week slot
# --bwlimit 18M: ~65% of typical VPS uplink — leaves headroom for other services
log "ACTION: uploading to ${B2_DEST}"
rclone copyto "$ARCHIVE" "$B2_DEST" \
    --bwlimit 18M \
    --retries 3 \
    --retries-sleep 10s

log "ACTION: upload complete"

# Clean up
rm -rf "$STAGING" "$ARCHIVE"
log "ACTION: cleanup done"
log "SESSION END"
