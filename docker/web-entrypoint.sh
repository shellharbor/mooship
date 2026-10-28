#!/bin/sh
set -eu
umask 077
: "${MOOSHIP_FPM_UPSTREAM:=app:9000}"
export MOOSHIP_FPM_UPSTREAM
if ! printf '%s' "$MOOSHIP_FPM_UPSTREAM" | grep -Eq '^[A-Za-z0-9_.-]+:[0-9]{1,5}$'; then
    printf '%s\n' '[ERROR] MOOSHIP_FPM_UPSTREAM must be a hostname:port.' >&2
    exit 1
fi
port=${MOOSHIP_FPM_UPSTREAM##*:}
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    printf '%s\n' '[ERROR] Invalid FastCGI port.' >&2
    exit 1
fi
envsubst '${MOOSHIP_FPM_UPSTREAM}' < /opt/mooship/nginx.conf.template > /tmp/nginx.conf
exec nginx -c /tmp/nginx.conf -g 'daemon off;'
