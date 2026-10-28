#!/bin/sh
set -eu
umask 077
php /opt/mooship/check-runtime.php "$(php -r '$v = json_decode(file_get_contents("/opt/mooship/version.json"), true); echo explode(" ", $v["release"])[0];')"
if [ "$#" -eq 0 ]; then set -- fpm; fi
case "$1" in
    --help|-h)
        printf '%s\n' 'Mooship Moodle runtime: fpm | install | cron | cron-once | check | php ...'
        ;;
    install) exec php /opt/mooship/install.php ;;
    check) exec php /opt/mooship/readiness.php ;;
    fpm|cron|cron-once)
        php /opt/mooship/validate.php
        if ! php /opt/mooship/readiness.php; then
            printf '%s\n' '[ERROR] Install the database first, or verify its version and connectivity.' >&2
            exit 1
        fi
        case "$1" in
            fpm) exec php-fpm -F ;;
            cron) exec /opt/mooship/cron.sh ;;
            cron-once) exec php /opt/moodle/admin/cli/cron.php --keep-alive=0 ;;
        esac
        ;;
    *) exec "$@" ;;
esac
