#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WWW_DIR="${WWW_DIR:-/var/www}"
source "$SCRIPT_DIR/lib/common.sh"

backup_project() (
    local SLUG="$1" archive="$2" PROJECT_DIR base stage="" partial="" service running
    local -a resume=()
    PROJECT_DIR=$(mooship_project_path "$SLUG")
    [[ -f "$PROJECT_DIR/.env" && -f "$PROJECT_DIR/public_html/config.php" ]] ||
        mooship_die "Backup requires an installed project"
    archive=$(realpath -m -- "$archive")
    [[ "$archive" != "$PROJECT_DIR" && "$archive" != "$PROJECT_DIR/"* ]] ||
        mooship_die "The archive must be outside the project directory"
    [[ ! -e "$archive" && ! -L "$archive" ]] || mooship_die "The archive already exists"
    base=$(dirname "$archive")
    mkdir -p -- "$base"
    cleanup_backup() {
        local result=$?
        trap - EXIT
        if ((${#resume[@]})); then
            docker compose start "${resume[@]}" || result=1
        fi
        [[ -z "$partial" ]] || rm -f -- "$partial"
        [[ -z "$stage" || "$stage" != "$base/.mooship-backup."* ]] || rm -rf -- "$stage"
        if [[ "$result" == 0 ]]; then
            printf '[OK] Backup (database, files, configuration, SSL): %s\n' "$archive"
        fi
        exit "$result"
    }
    trap cleanup_backup EXIT
    stage=$(mktemp -d "$base/.mooship-backup.XXXXXX")
    partial=$(mktemp "$base/.mooship-archive.XXXXXX")
    cd "$PROJECT_DIR"
    # Freeze application writers and certificate renewal, then restore exactly the running services.
    running=$(docker compose ps --status running --services)
    while IFS= read -r service; do
        case "$service" in php|cron|nginx|certbot_renew) resume+=("$service") ;; esac
    done <<< "$running"
    if ((${#resume[@]})); then docker compose stop --timeout 30 "${resume[@]}"; fi

    local db_type native name user password port
    native=$(mooship_read_env "$PROJECT_DIR/.env" DB_NATIVE)
    name=$(mooship_read_env "$PROJECT_DIR/.env" DB_POSTGRES_NAME)
    if [[ -n "$name" ]]; then db_type=postgres; else db_type=mysql; fi
    if [[ "$native" == true ]]; then
        port=$(mooship_read_env "$PROJECT_DIR/.env" DB_PORT)
        if [[ "$db_type" == postgres ]]; then
            command -v pg_dump >/dev/null || mooship_die "A native database requires pg_dump"
            # The root shell intentionally owns the private output file.
            # shellcheck disable=SC2024
            sudo -u postgres pg_dump --port="$port" --format=custom --dbname="$name" > "$stage/database.dump"
        else
            command -v mysqldump >/dev/null || mooship_die "A native database requires mysqldump"
            name=$(mooship_read_env "$PROJECT_DIR/.env" DB_MYSQL_NAME)
            user=$(mooship_read_env "$PROJECT_DIR/.env" DB_MYSQL_USER)
            password=$(mooship_read_env "$PROJECT_DIR/.env" DB_MYSQL_PASSWORD)
            MYSQL_PWD="$password" mysqldump --protocol=TCP --host=127.0.0.1 --port="$port" \
                --user="$user" --single-transaction --no-tablespaces --set-gtid-purged=OFF \
                --routines --events --triggers "$name" > "$stage/database.dump"
        fi
    elif [[ "$db_type" == postgres ]]; then
        docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump --format=custom -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$stage/database.dump"
    else
        docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysqldump --user="$MYSQL_USER" --single-transaction --no-tablespaces --set-gtid-purged=OFF --routines --events --triggers "$MYSQL_DATABASE"' > "$stage/database.dump"
    fi
    [[ -s "$stage/database.dump" ]] || mooship_die "The database dump is empty"
    docker compose run --rm -T --no-deps --entrypoint tar nginx -C /etc/letsencrypt -cf - . > "$stage/certificates.tar"
    cp -a -- "$PROJECT_DIR" "$stage/project"
    python3 "$SCRIPT_DIR/lib/state.py" manifest "$stage" "$SLUG"
    tar -C "$stage" -czf "$partial" project database.dump certificates.tar manifest.json
    chmod 600 -- "$partial"
    # A hard link publishes the complete archive atomically without overwriting an existing backup.
    ln -- "$partial" "$archive"
)

backup_main() {
    local SLUG="" archive=""
    while (($#)); do
        case "$1" in
            --slug) SLUG="${2:?A value is required for --slug}"; shift 2 ;;
            --archive) archive="${2:?A value is required for --archive}"; shift 2 ;;
            -h|--help) printf 'Mooship: sudo bash backup.sh --slug SLUG [--archive /path/backup.tar.gz]\n'; return ;;
            *) mooship_die "Unknown argument: $1" ;;
        esac
    done
    [[ $EUID == 0 ]] || mooship_die "Root privileges are required (sudo)"
    mooship_validate_slug "$SLUG"
    mooship_require_docker
    archive="${archive:-/var/backups/mooship/${SLUG}_$(date +%Y%m%d_%H%M%S).tar.gz}"
    backup_project "$SLUG" "$archive"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then backup_main "$@"; fi
