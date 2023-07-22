#!/bin/bash -eu

ARCHIVE_HOST_NAME="$1"

ssh -q -o ConnectTimeout=1 "$RSYNC_USER"@"$ARCHIVE_HOST_NAME" exit
