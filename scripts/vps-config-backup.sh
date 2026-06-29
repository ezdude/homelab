#!/usr/bin/env bash
# vps-config-backup.sh
# Weekly tarball backup of the vps-config git repo (including .git history) to B2.
# Stores 7 rolling copies by day-of-week.
#
# Cron: 0 4 * * 0 /usr/local/bin/vps-config-backup.sh >> /var/log/vps-config-backup.log 2>&1
#
# Prerequisites: rclone configured with a B2 remote

set -euo pipefail

LOGFILE="/var/log/vps-config-backup.log"
REPO_DIR="/root/vps-config"          # path to your vps-config git repo
DOW=$(date +%A)                       # Monday, Tuesday, ...
ARCHIVE="/tmp/vps-config-${DOW}.tar.gz"

# Replace with your rclone remote name and bucket/path
B2_DEST="b2-backup:YOUR_B2_BUCKET/backups/vps-config/vps-config-${DOW}.tar.gz"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }

log "SESSION START — day slot: ${DOW}"

[[ -d "$REPO_DIR/.git" ]] || { log "ERROR: $REPO_DIR is not a git repo — aborting"; exit 1; }
command -v rclone &>/dev/null || { log "ERROR: rclone not found — aborting"; exit 1; }

rm -f "$ARCHIVE"

log "ACTION: creating tarball of ${REPO_DIR}"
tar czf "$ARCHIVE" -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")"

log "ACTION: uploading to ${B2_DEST}"
rclone copyto "$ARCHIVE" "$B2_DEST" \
    --retries 3 \
    --retries-sleep 10s

log "ACTION: upload complete"
rm -f "$ARCHIVE"
log "SESSION END"
