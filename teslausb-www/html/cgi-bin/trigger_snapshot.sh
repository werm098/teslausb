#!/bin/bash

/root/bin/waitforidle || true
/root/bin/make_snapshot.sh

cat << EOF
HTTP/1.0 200 OK
Content-type: text/plain

EOF