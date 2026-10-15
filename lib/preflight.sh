#!/bin/bash
# Deployment preflight, bounded readiness checks, and ordered service startup.

mooship_port_available() {
    local port="$1"
    [[ " ${MOOSHIP_ASSIGNED_PORTS:-} " != *" $port "* ]] || return 1
    ! grep -Eq ":${port}->" <<< "${MOOSHIP_DOCKER_PORTS:-}" || return 1
    python3 - "$port" <<'PY'
import socket
import sys

try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
        connection.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
PY
}

mooship_validate_db_host() {
    [[ "$1" =~ ^[A-Za-z0-9_:][A-Za-z0-9_.:-]*$ ]] ||
        mooship_die "Invalid native database host; use a hostname or IP address"
}

mooship_wait_service() {
    local service="$1" state health attempt status
    local attempts="${MOOSHIP_READY_ATTEMPTS:-90}"
    [[ "$attempts" =~ ^[0-9]{1,4}$ ]] && ((10#$attempts > 0)) ||
        mooship_die "MOOSHIP_READY_ATTEMPTS must be a positive integer"
    for ((attempt = 0; attempt < 10#$attempts; attempt++)); do
        status=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${SLUG}_${service}") || return 1
        read -r state health <<< "$status"
        if [[ "$state" == exited || "$state" == dead ]]; then
            printf '[ERROR] Service %s exited before becoming ready\n' "$service" >&2
            return 1
        fi
        if [[ "$state" == running && "$health" == healthy ]]; then return 0; fi
        if [[ "$state" == running && "$health" == none ]]; then
            # Older archives have no health metadata; check the actual process/configuration.
            case "$service" in
                php) docker compose exec -T php php -r '$s = @fsockopen("127.0.0.1", 9000, $n, $e, 2); exit($s ? 0 : 1);' && return 0 ;;
                nginx) docker compose exec -T nginx nginx -t >/dev/null 2>&1 && return 0 ;;
                redis)
                    REDISCLI_AUTH="$(mooship_read_env "$PROJECT_DIR/.env" REDIS_PASSWORD)" \
                        docker compose exec -T -e REDISCLI_AUTH redis redis-cli ping | grep -qx PONG && return 0 ;;
                cron|certbot_renew) return 0 ;;
            esac
        fi
        sleep 2
    done
    printf '[ERROR] Service %s did not become ready within %s seconds\n' "$service" "$((10#$attempts * 2))" >&2
    return 1
}

mooship_check_database() {
    local mode="${1:-connect}" host port name user password
    if [[ "$DB_TYPE" == postgres ]]; then
        port=5432; name="$DB_POSTGRES_NAME"; user="$DB_POSTGRES_USER"; password="$DB_POSTGRES_PASSWORD"
        [[ "$DB_NATIVE" != true ]] || port="$PORT_POSTGRES"
    else
        port=3306; name="$DB_MYSQL_NAME"; user="$DB_MYSQL_USER"; password="$DB_MYSQL_PASSWORD"
        [[ "$DB_NATIVE" != true ]] || port="$PORT_MYSQL"
    fi
    host="${SLUG}_db"
    [[ "$DB_NATIVE" != true ]] || host="${NATIVE_DB_HOST:-host.docker.internal}"
    # Export secrets only to the Docker client environment, never as command arguments.
    MOOSHIP_DB_TYPE="$DB_TYPE" MOOSHIP_DB_HOST="$host" MOOSHIP_DB_PORT="$port" \
    MOOSHIP_DB_NAME="$name" MOOSHIP_DB_USER="$user" MOOSHIP_DB_PASSWORD="$password" \
    MOOSHIP_DB_CHECK="$mode" docker compose exec -T \
        -e MOOSHIP_DB_TYPE -e MOOSHIP_DB_HOST -e MOOSHIP_DB_PORT \
        -e MOOSHIP_DB_NAME -e MOOSHIP_DB_USER -e MOOSHIP_DB_PASSWORD -e MOOSHIP_DB_CHECK \
        php php < "$SCRIPT_DIR/lib/check-database.php"
}

start_moodle_cron() {
    (cd "$PROJECT_DIR" && docker compose up -d cron &&
        mooship_wait_service cron) || error "Moodle cron did not start"
}

reload_project_nginx() {
    (cd "$PROJECT_DIR" && docker compose exec -T nginx nginx -t &&
        docker compose exec -T nginx nginx -s reload) || error "Could not apply the project's nginx configuration"
}
