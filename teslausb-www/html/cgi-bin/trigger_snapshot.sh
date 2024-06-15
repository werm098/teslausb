#!/bin/bash

sudo /root/bin/waitforidle || true
sudo /root/bin/make_snapshot.sh

cat << EOF
HTTP/1.0 200 OK
Content-type: text/plain

EOF