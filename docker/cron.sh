#!/bin/sh
set -eu
child=''
finish() {
    trap - TERM INT QUIT
    if [ -n "$child" ]; then
        kill -TERM "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    exit 0
}
trap finish TERM INT QUIT
while :; do
    php /opt/moodle/admin/cli/cron.php --keep-alive=0 &
    child=$!
    if ! wait "$child"; then exit 1; fi
    child=''
    sleep 60 &
    child=$!
    wait "$child"
    child=''
done
