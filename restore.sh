#!/bin/bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# Reuse the same project/proxy setup; sourcing never deploys a site.
source "$SCRIPT_DIR/deploy-moodle.sh"

restore_database() {
    local dump="$1"
    if [[ "$DB_NATIVE" == true ]]; then
        if [[ "$DB_TYPE" == postgres ]]; then
            sudo -u postgres pg_restore --port="$PORT_POSTGRES" --exit-on-error \
                --no-owner --no-privileges --role="$DB_POSTGRES_USER" --dbname="$DB_POSTGRES_NAME" < "$dump"
        else
            MYSQL_PWD="$DB_MYSQL_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 \
                --port="$PORT_MYSQL" --user="$DB_MYSQL_USER" "$DB_MYSQL_NAME" < "$dump"
        fi
    elif [[ "$DB_TYPE" == postgres ]]; then
        docker compose exec -T db sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_restore --exit-on-error --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$dump"
    else
        docker compose exec -T db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql --user="$MYSQL_USER" "$MYSQL_DATABASE"' < "$dump"
    fi
}

restore_main() (
    local archive="" restore_slug="" stage="" confirmation key has_ssl=true
    while (($#)); do
        case "$1" in
            --slug) restore_slug="${2:?A value is required for --slug}"; shift 2 ;;
            --archive) archive="${2:?A value is required for --archive}"; shift 2 ;;
            --db-root-password) DB_ROOT_PASSWORD="${2:?A root password is required}"; shift 2 ;;
            -h|--help) printf 'Mooship: sudo bash restore.sh --slug SLUG --archive /path/backup.tar.gz [--db-root-password PASS]\n'; return ;;
            *) error "Unknown argument: $1" ;;
        esac
    done
    check_root
    SLUG="$restore_slug"
    mooship_validate_slug "$SLUG"
    mooship_require_new_project
    [[ -f "$archive" && ! -L "$archive" ]] || error "--archive must specify an existing regular file"
    archive=$(realpath -e -- "$archive")
    mooship_require_docker
    mooship_require_unused_resources
    ensure_www_dir
    stage=$(mktemp -d "$WWW_DIR/.mooship-restore.XXXXXX")
    cleanup_restore() {
        local result=$?
        trap - EXIT
        [[ "$stage" != "$WWW_DIR/.mooship-restore."* ]] || rm -rf -- "$stage"
        exit "$result"
    }
    trap cleanup_restore EXIT
    python3 "$SCRIPT_DIR/lib/state.py" extract "$archive" "$stage" "$SLUG"
    for key in SITE_HOST SITE_SCHEME DB_NATIVE DB_HOST PHP_VERSION MOODLE_VERSION DB_PORT \
               DB_POSTGRES_NAME DB_POSTGRES_USER DB_POSTGRES_PASSWORD \
               DB_MYSQL_NAME DB_MYSQL_USER DB_MYSQL_PASSWORD DB_MYSQL_PASSWORD_ROOT AUTH_USER; do
        printf -v "$key" '%s' "$(mooship_read_env "$stage/project/.env" "$key")"
    done
    DOMAIN="$SITE_HOST"
    mooship_require_project_runtime "$stage/project"
    # Archives created before HTTP support default to their original HTTPS behavior.
    case "${SITE_SCHEME:-https}" in
        http) OBTAIN_SSL=false ;;
        https) OBTAIN_SSL=true ;;
        *) error "Invalid site scheme in the archive" ;;
    esac
    [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || error "Invalid domain in the archive"
    mooship_validate_port "$DB_PORT"
    DB_MYSQL_ROOT_PASSWORD="$DB_MYSQL_PASSWORD_ROOT"
    if [[ -n "$DB_POSTGRES_NAME" ]]; then DB_TYPE=postgres; PORT_POSTGRES="$DB_PORT";
    else DB_TYPE=mysql; PORT_MYSQL="$DB_PORT"; fi
    mooship_validate_database_settings
    if [[ "$DB_NATIVE" == true ]]; then
        # Old archives contain the original bridge address in config.php.
        NATIVE_DB_HOST="${DB_HOST:-172.17.0.1}"
        mooship_validate_db_host "$NATIVE_DB_HOST"
        [[ "$DB_TYPE" != mysql || -n "$DB_ROOT_PASSWORD" ]] || error "Native MySQL requires --db-root-password"
        mooship_require_new_native_database
    fi

    printf 'Restoring %s (%s) to new directory %s/%s. Existing projects are not replaced.\n' "$SLUG" "$DOMAIN" "$WWW_DIR" "$SLUG"
    read -r -p "Enter the slug to confirm: " confirmation
    [[ "$confirmation" == "$SLUG" ]] || error "Restore canceled"
    mooship_require_new_project
    PROJECT_DIR=$(mooship_project_path "$SLUG")
    mv -T -- "$stage/project" "$PROJECT_DIR"
    # Ownership is established by the new CREATE, never inherited from the source server.
    rm -f -- "$PROJECT_DIR/.mooship-native-database"
    chmod 600 "$PROJECT_DIR/.env"
    if [[ -f "$PROJECT_DIR/.config/nginx/.htpasswd" ]]; then
        chmod 644 "$PROJECT_DIR/.config/nginx/.htpasswd"
    fi
    init_nginxproxy
    ensure_logrotate
    create_native_database
    ensure_project_docker_resources
    docker compose config --quiet
    docker compose build --pull php nginx cron
    mooship_verify_project_php || error "PHP security verification failed before database import"
    if [[ "$DB_NATIVE" != true ]]; then
        docker compose up -d db
        mooship_wait_database || error "The database is not ready for restore"
    fi
    restore_database "$stage/database.dump"
    docker compose run --rm -T --no-deps --entrypoint tar certbot -C /etc/letsencrypt -xf - < "$stage/certificates.tar"
    docker compose run --rm -T --no-deps permissions
    if [[ "$OBTAIN_SSL" == false ]]; then
        # Restore the archived HTTP routes verbatim, including later manual changes.
        has_ssl=false
    elif ! docker compose run --rm -T --no-deps --entrypoint test nginx -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"; then
        has_ssl=false
        comment_ssl_blocks
    fi
    build_and_start_project
    start_moodle_cron
    update_proxy_nginx_conf
    update_proxy_docker_compose
    if [[ "$has_ssl" == false ]]; then comment_ssl_blocks; fi
    restart_nginxproxy
    success "Mooship: project $SLUG restored from $archive"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then restore_main "$@"; fi
