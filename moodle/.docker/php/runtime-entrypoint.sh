#!/bin/sh
set -eu
php /opt/mooship/check-runtime.php
if [ -f /var/www/html/public/version.php ] || [ -f /var/www/html/version.php ]; then
    php /opt/mooship/check-runtime.php --source /var/www/html
fi
exec docker-php-entrypoint "$@"
