#!/bin/bash -eu

SRC="${RSYNC_USER}@${RSYNC_SERVER}:${MUSIC_SHARE_NAME}"
DST="${MUSIC_MOUNT}"
RSYNC_STATS="/tmp/music-rsync-stats"
RSYNC_LOG="/tmp/music-rsync-cmd.log"

# check that DST is the mounted disk image, not the mountpoint directory
if ! findmnt --mountpoint "$DST" > /dev/null
then
  log "$DST not mounted, skipping music sync"
  exit
fi

function do_music_sync {
  log "Syncing music from remote..."

  if ! rsync -rtumL --timeout=60 --no-human-readable --no-perms --delete --modify-window=2 \
                --exclude=.fseventsd/*** --exclude=*.DS_Store --exclude=.metadata_never_index --exclude="System Volume Information/***" \
                --log-file="$RSYNC_LOG" --info=stats2 "$SRC/" "$DST" &> "$RSYNC_STATS"
  then
    log "rsync failed with error $?"
  fi

  # remove empty directories
  find "$DST" -depth -type d -empty -delete || true

  # parse log for relevant info
  declare -i NUM_FILES_COPIED
  NUM_FILES_COPIED=$(($(sed -n -e 's/\(^Number of regular files transferred: \)\([[:digit:]]\+\).*/\2/p' "$RSYNC_STATS")))
  declare -i NUM_FILES_DELETED
  NUM_FILES_DELETED=$(($(sed -n -e 's/\(^Number of deleted files: [[:digit:]]\+ (reg: \)\([[:digit:]]\+\)*.*/\2/p' "$RSYNC_STATS")))
  declare -i TOTAL_FILES
  TOTAL_FILES=$(sed -n -e 's/\(^Number of files: [[:digit:]]\+ (reg: \)\([[:digit:]]\+\)*.*/\2/p' "$RSYNC_STATS")
  declare -i NUM_FILES_ERROR
  NUM_FILES_ERROR=$(($(grep -c "failed to open" "$RSYNC_STATS" || true)))

  declare -i NUM_FILES_SKIPPED=$((TOTAL_FILES-NUM_FILES_COPIED))
  NUM_FILES_COPIED=$((NUM_FILES_COPIED-NUM_FILES_ERROR))

  local message="Copied $NUM_FILES_COPIED music file(s), deleted $NUM_FILES_DELETED, skipped $NUM_FILES_SKIPPED previously-copied files, and encountered $NUM_FILES_ERROR errors."

  if [ $NUM_FILES_COPIED -ne 0 ] || [ $NUM_FILES_DELETED -ne 0 ] || [ $NUM_FILES_ERROR -ne 0 ]
  then
    /root/bin/send-push-message "$NOTIFICATION_TITLE:" "$message"
  else
    log "$message"
  fi
}

if ! do_music_sync
then
  log "Error while syncing music"
fi
