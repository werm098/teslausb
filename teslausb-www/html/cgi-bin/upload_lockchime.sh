#!/bin/bash

sudo /root/bin/disable_gadget.sh || true
sudo mount /mnt/cam || true

if [ "$REQUEST_METHOD" = "POST" ]; then
    if [ "$CONTENT_LENGTH" -gt 0 ]; then
    echo "$(cat)" | base64 -d > /mnt/cam/LockChime.wav
    fi
fi

sudo umount /mnt/cam || true
sudo /root/bin/enable_gadget.sh || true

cat << EOF
HTTP/1.0 200 OK
Content-type: text/plain

EOF
