#!/bin/bash
# Shared safety boundaries for Mooship's host scripts.

mooship_die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

mooship_validate_slug() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ && "${1,,}" != nginxproxy ]] ||
        mooship_die "Invalid or reserved slug: $1"
}

mooship_project_path() {
    local slug="$1" base target
    mooship_validate_slug "$slug"
    base=$(realpath -m -- "$WWW_DIR")
    target=$(realpath -m -- "$WWW_DIR/$slug")
    [[ "$target" == "$base/$slug" && ! -L "$WWW_DIR/$slug" ]] ||
        mooship_die "The project path is outside $WWW_DIR or is a symlink"
    printf '%s\n' "$target"
}

mooship_require_project() {
    PROJECT_DIR=$(mooship_project_path "$SLUG")
    [[ -d "$PROJECT_DIR" && -f "$PROJECT_DIR/docker-compose.yml" &&
       ! -L "$PROJECT_DIR/docker-compose.yml" ]] ||
        mooship_die "Managed project not found: $PROJECT_DIR"
}

mooship_require_new_project() {
    local path
    path=$(mooship_project_path "$SLUG")
    [[ ! -e "$path" && ! -L "$path" ]] ||
        mooship_die "Project $SLUG already exists. Data preserved; use activate.sh or explicitly run remove.sh before reinstalling."
}

mooship_require_docker() {
    docker info >/dev/null 2>&1 || mooship_die "Docker daemon is unavailable"
    docker compose version >/dev/null 2>&1 || mooship_die "Docker Compose plugin is not installed"
}

mooship_require_unused_resources() {
    local object
    for object in "${SLUG}_db" "${SLUG}_db_postgres" "${SLUG}_db_mysql" \
                  "${SLUG}_ssl_certificates" "${SLUG}_certbot_www" "${SLUG}_redis_data"; do
        if docker volume inspect "$object" >/dev/null 2>&1; then
            mooship_die "Volume $object still exists. Automatic reuse is prohibited; handle the previous project first."
        fi
    done
    if docker network inspect "$SLUG" >/dev/null 2>&1 ||
       [[ -e "$PROXY_DIR/sites/$SLUG.conf" || -e "$PROXY_DIR/sites/$SLUG.conf.disabled" ]]; then
        mooship_die "A network or proxy configuration already exists for $SLUG"
    fi
    for object in php nginx db db_postgres db_mysql cron redis certbot certbot_renew permissions; do
        if docker container inspect "${SLUG}_${object}" >/dev/null 2>&1; then
            mooship_die "Container ${SLUG}_${object} already exists"
        fi
    done
}

# Hooks run with the caller's privileges (root in production), so only that user may change them.
mooship_validate_hook() {
    local hook="$1" owner mode
    [[ "$hook" == /* && -f "$hook" && -x "$hook" && ! -L "$hook" ]] ||
        mooship_die "The hook must be an absolute path to an executable regular file: $hook"
    read -r owner mode < <(stat -c '%u %a' -- "$hook")
    [[ "$owner" == "$EUID" ]] && (( (8#$mode & 8#022) == 0 )) ||
        mooship_die "The hook must be owned by the user running Mooship (root) and not writable by group or others: $hook"
}

# systemd units created by schedule-backup.sh: mooship-backup-<slug>.service and .timer
mooship_backup_unit() { printf 'mooship-backup-%s' "$1"; }

# Remove a backup schedule; does nothing when the project has none.
mooship_unschedule_backup() {
    local unit directory="${UNIT_DIR:-/etc/systemd/system}"
    unit=$(mooship_backup_unit "$1")
    [[ -e "$directory/$unit.timer" || -e "$directory/$unit.service" ]] || return 0
    systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
    rm -f -- "$directory/$unit.timer" "$directory/$unit.service"
    systemctl daemon-reload
    printf '[INFO] Removed the backup schedule %s.timer\n' "$unit"
}

mooship_read_env() {
    python3 "$SCRIPT_DIR/lib/state.py" env "$1" "$2"
}

mooship_validate_database_identifiers() {
    local engine="$1" name="$2" user="$3" value
    for value in "$name" "$user"; do
        [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_]*$ && ${#value} -le 63 ]] ||
            mooship_die "Invalid database or user name"
    done
    case "$engine:$name" in
        postgres:postgres|postgres:template0|postgres:template1|mysql:mysql|mysql:sys|mysql:information_schema|mysql:performance_schema)
            mooship_die "System databases are prohibited" ;;
    esac
    case "$engine:$user" in postgres:postgres|mysql:root) mooship_die "System database users are prohibited" ;; esac
}

mooship_validate_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 > 0 && 10#$1 <= 65535)) ||
        mooship_die "Invalid port: expected an integer from 1 to 65535"
}

mooship_validate_database_settings() {
    if [[ "$DB_TYPE" == postgres ]]; then
        mooship_validate_database_identifiers postgres "$DB_POSTGRES_NAME" "$DB_POSTGRES_USER"
        [[ "$DB_POSTGRES_PASSWORD" =~ ^[A-Za-z0-9@%_+-]+$ ]] || mooship_die "The PostgreSQL password contains unsupported characters"
    else
        mooship_validate_database_identifiers mysql "$DB_MYSQL_NAME" "$DB_MYSQL_USER"
        [[ "$DB_MYSQL_PASSWORD" =~ ^[A-Za-z0-9@%_+-]+$ ]] || mooship_die "The MySQL password contains unsupported characters"
    fi
}

mooship_require_new_native_database() {
    local found
    if [[ "$DB_TYPE" == postgres ]]; then
        found=$(sudo -u postgres psql --port="$PORT_POSTGRES" -At -v ON_ERROR_STOP=1 \
            -v name="$DB_POSTGRES_NAME" -v username="$DB_POSTGRES_USER" <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'name'
UNION ALL SELECT 1 FROM pg_roles WHERE rolname = :'username';
SQL
)
    else
        found=$(MYSQL_PWD="$DB_ROOT_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 \
            --port="$PORT_MYSQL" --user=root --batch --skip-column-names <<SQL
SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${DB_MYSQL_NAME}';
SELECT 1 FROM mysql.user WHERE User = '${DB_MYSQL_USER}';
SQL
)
    fi
    [[ -z "$found" ]] || mooship_die "The native database or user already exists; automatic reuse is prohibited"
}

mooship_wait_database() {
    local state attempt
    for ((attempt = 0; attempt < 90; attempt++)); do
        state=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${SLUG}_db") || return 1
        [[ "$state" == healthy ]] && return 0
        [[ "$state" != exited && "$state" != dead ]] || return 1
        sleep 2
    done
    printf '[ERROR] The database was not ready within 180 seconds\n' >&2
    return 1
}
