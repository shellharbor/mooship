#!/bin/sh
# Run as the existing PHP container user; install declared production packages only.
set -eu
moodle_root=${1:-/var/www/html}

status=0
php -r '
    $path = $argv[1] . "/composer.json";
    if (!is_file($path)) { exit(3); }
    $manifest = json_decode(file_get_contents($path), true, 512, JSON_THROW_ON_ERROR);
    if (!is_array($manifest) || !is_array($manifest["require"] ?? [])) { exit(1); }
    exit(isset($manifest["require"]["league/oauth2-server"]) ? 0 : 3);
' "$moodle_root" || status=$?
[ "$status" != 3 ] || exit 0
[ "$status" = 0 ] || { echo '[ERROR] Could not read Moodle dependency requirements' >&2; exit 1; }
[ -f "$moodle_root/composer.lock" ] || { echo '[ERROR] Moodle composer.lock is missing' >&2; exit 1; }

composer_file=$(mktemp /tmp/mooship-composer.XXXXXX)
trap 'rm -f "$composer_file"' EXIT
trap 'exit 1' HUP INT TERM
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 10 --max-time 120 \
    https://getcomposer.org/download/2.10.3/composer.phar -o "$composer_file"
printf '%s  %s\n' '7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6' "$composer_file" | sha256sum -c -
php "$composer_file" install --working-dir="$moodle_root" --no-dev --no-scripts --no-plugins \
    --prefer-dist --no-interaction --no-progress --optimize-autoloader
php -r '
    require $argv[1] . "/vendor/autoload.php";
    exit(trait_exists(\League\OAuth2\Server\Entities\Traits\ScopeTrait::class) ? 0 : 1);
' "$moodle_root"
