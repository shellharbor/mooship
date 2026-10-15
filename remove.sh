#!/bin/bash

# ============================================================
# remove.sh — permanently remove a project
# ============================================================
# Usage:
#   sudo bash remove.sh --slug cp --domain cp.lentrade.pro
#
# What the script does:
#   1. Remove all project entries from nginxproxy docker-compose.yml
#   2. Remove the site config nginxproxy/sites/<slug>.conf
#   3. Apply nginxproxy configuration (docker compose up -d)
#   4. Stop project containers (docker compose down)
#   5. Remove all project volumes
#   6. Remove the project network
#   7. Restart nginxproxy (docker restart nginxproxy)
#   8. Remove the project directory
#
# Options:
#   --slug SLUG           Project slug (required)
#   --domain DOMAIN       Project domain (required)
#   --db-root-password P  Native MySQL root password (needed to remove its database and user)
# ============================================================

set -euo pipefail
umask 077

# ==================== Variables ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
source "$SCRIPT_DIR/lib/common.sh"
SLUG=""
DOMAIN=""
DB_ROOT_PASSWORD=""

# ==================== Colored output ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ==================== Root check =================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Run this script as root (sudo)"
    fi
}

# ==================== Argument parsing ============
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)    SLUG="$2";    shift 2 ;;
            --domain)  DOMAIN="$2";  shift 2 ;;
            --db-root-password) DB_ROOT_PASSWORD="$2"; shift 2 ;;
            *) error "Unknown argument: $1" ;;
        esac
    done

    [[ -z "$SLUG" ]]   && error "--slug is required"
    [[ -z "$DOMAIN" ]] && error "--domain is required"

    mooship_require_project
}

# ==================== Confirm removal ========
confirm_deletion() {
    echo ""
    echo -e "${RED}============================================================${NC}"
    echo -e "${RED}                   ⚠️  WARNING! ⚠️${NC}"
    echo -e "${RED}============================================================${NC}"
    echo ""
    echo -e "${YELLOW}You are about to PERMANENTLY REMOVE the project:${NC}"
    echo ""
    echo -e "  Slug:           ${RED}${SLUG}${NC}"
    echo -e "  Domain:         ${RED}${DOMAIN}${NC}"
    echo -e "  Path:           ${RED}${PROJECT_DIR}${NC}"
    echo ""
    echo -e "${YELLOW}The following will be removed:${NC}"
    echo "  • All project containers"
    echo "  • All volumes (including database data)"
    echo "  • Project network"
    echo "  • nginxproxy configuration"
    echo "  • Backups will be retained"
    echo "  • Project directory and all its files"
    echo ""
    echo -e "${RED}⚠️  THIS ACTION IS IRREVERSIBLE! ⚠️${NC}"
    echo ""
    echo -e "${RED}============================================================${NC}"
    echo ""
    
    # Request confirmation
    read -p "Enter 'yes' to confirm removal: " CONFIRMATION
    
    if [[ "$CONFIRMATION" != "yes" ]]; then
        echo ""
        info "Removal canceled by the user"
        exit 0
    fi
    
    echo ""
    info "Confirmation received. Starting removal..."
}

# ==================== Remove the site config ====
remove_from_nginx_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    # After deactivate.sh, the config is named <slug>.conf.disabled
    if [[ ! -f "$SITE_CONF" && ! -f "${SITE_CONF}.disabled" ]]; then
        warn "Config ${SITE_CONF} not found, skipping."
        return
    fi

    info "Removing config ${SLUG}.conf..."

    rm -f "$SITE_CONF" "${SITE_CONF}.disabled"
    
    if [[ $? -eq 0 ]]; then
        info "Config ${SLUG}.conf removed"
    else
        error "Could not remove config ${SLUG}.conf"
    fi
}

# ==================== Remove docker-compose.yml entries ====
remove_from_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "docker-compose.yml not found: ${COMPOSE_FILE}"
    fi
    
    info "Removing ${SLUG} entries from docker-compose.yml..."
    
    python3 "$SCRIPT_DIR/lib/proxy.py" remove "${COMPOSE_FILE}" "${SLUG}"

    if [[ $? -eq 0 ]]; then
        info "docker-compose.yml updated successfully"
    else
        error "Failed to update docker-compose.yml"
    fi
}

# ==================== Apply nginxproxy configuration ====
apply_proxy_config() {
    info "Applying nginxproxy configuration..."
    cd "${PROXY_DIR}" || error "Could not change to ${PROXY_DIR}"
    
    docker compose up -d
    
    if [[ $? -eq 0 ]]; then
        info "nginxproxy configuration applied"
    else
        warn "Problems occurred while applying nginxproxy configuration"
    fi
    
    cd "${SCRIPT_DIR}" || true
}

# ==================== Stop project containers =
stop_project_containers() {
    info "Stopping containers for project ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Cannot enter ${PROJECT_DIR}"
    
    docker compose down
    
    if [[ $? -eq 0 ]]; then
        info "Containers for project ${SLUG} stopped"
    else
        warn "Problems occurred while stopping containers"
    fi
    
    cd "${SCRIPT_DIR}" || true
}

# ==================== Remove project volumes =======
remove_project_volumes() {
    info "Removing volumes for project ${SLUG}..."
    
    # Get the volume list from the project's docker-compose.yml
    cd "${PROJECT_DIR}" || error "Cannot enter ${PROJECT_DIR}"
    
    local VOLUMES
    VOLUMES=$(grep -E "^  ${SLUG}_" docker-compose.yml | sed 's/://g' | awk '{print $1}' || true)
    
    if [[ -z "$VOLUMES" ]]; then
        info "No volumes found in docker-compose.yml"
    else
        for volume in $VOLUMES; do
            info "Removing volume: ${volume}"
            docker volume rm "${volume}" 2>/dev/null || warn "Volume ${volume} not found or already removed"
        done
        info "All project volumes removed"
    fi
    
    cd "${SCRIPT_DIR}" || true
}

# ==================== Remove the project network =======
remove_project_network() {
    info "Removing network for project ${SLUG}..."
    
    docker network rm "${SLUG}" 2>/dev/null || warn "Network ${SLUG} not found or already removed"
    
    info "Project network removed"
}

# ==================== Restart nginxproxy ========
restart_nginxproxy() {
    info "Restarting nginxproxy..."
    
    docker restart nginxproxy
    
    if [[ $? -eq 0 ]]; then
        info "nginxproxy restarted successfully"
    else
        warn "Problems occurred while restarting nginxproxy"
    fi
}

# ==================== Remove the native database ===========
remove_native_database() {
    # Check for the project's .env file
    local ENV_FILE="${PROJECT_DIR}/.env"
    if [[ ! -f "$ENV_FILE" ]]; then
        info ".env file not found, skipping the native database check"
        return
    fi
    
    # Read only known database keys as data; never import PATH or shell settings.
    local DB_NATIVE DB_PORT DB_POSTGRES_NAME DB_POSTGRES_USER DB_MYSQL_NAME DB_MYSQL_USER
    DB_NATIVE=$(mooship_read_env "$ENV_FILE" DB_NATIVE)
    DB_PORT=$(mooship_read_env "$ENV_FILE" DB_PORT)
    DB_POSTGRES_NAME=$(mooship_read_env "$ENV_FILE" DB_POSTGRES_NAME)
    DB_POSTGRES_USER=$(mooship_read_env "$ENV_FILE" DB_POSTGRES_USER)
    DB_MYSQL_NAME=$(mooship_read_env "$ENV_FILE" DB_MYSQL_NAME)
    DB_MYSQL_USER=$(mooship_read_env "$ENV_FILE" DB_MYSQL_USER)

    # Project without a database (HTML)
    if [[ -z "${DB_POSTGRES_NAME:-}" && -z "${DB_MYSQL_NAME:-}" ]]; then
        info "The project has no database, skipping native database removal"
        return
    fi

    # Check whether a native database is used
    # Method 1: DB_NATIVE flag (written by all deployment scripts)
    local IS_NATIVE=false
    if [[ "${DB_NATIVE:-}" == "true" ]]; then
        IS_NATIVE=true
    fi

    # Method 2: flag absent (old projects); check for a database service in docker-compose.yml.
    # deploy renames the service to "db", so check db, db_postgres, and db_mysql
    if [[ -z "${DB_NATIVE:-}" && -f "${PROJECT_DIR}/docker-compose.yml" ]]; then
        if ! grep -qE '^  db(_postgres|_mysql)?:' "${PROJECT_DIR}/docker-compose.yml" 2>/dev/null; then
            IS_NATIVE=true
            info "Native database detected (no db container in docker-compose.yml)"
        fi
    fi
    
    if [[ "$IS_NATIVE" != true ]]; then
        info "The project uses a container database, skipping native database removal"
        return
    fi
    
    local owned_type owned_name owned_user owned_port
    if [[ -n "$DB_POSTGRES_NAME" ]]; then
        owned_type=postgres; owned_name="$DB_POSTGRES_NAME"; owned_user="$DB_POSTGRES_USER"; owned_port="${DB_PORT:-5432}"
    else
        owned_type=mysql; owned_name="$DB_MYSQL_NAME"; owned_user="$DB_MYSQL_USER"; owned_port="${DB_PORT:-3306}"
    fi
    mooship_validate_database_identifiers "$owned_type" "$owned_name" "$owned_user"
    mooship_validate_port "$owned_port"
    local ownership_file="$PROJECT_DIR/.mooship-native-database"
    if [[ ! -f "$ownership_file" || -L "$ownership_file" ]] ||
       [[ "$(cat "$ownership_file")" != "$owned_type:$owned_name:$owned_user:$owned_port" ]]; then
        NATIVE_DATABASE_RETAINED=true
        warn "There is no proof that this native database was created by the Mooship project. Database and user retained; inspect them and remove manually if necessary."
        return
    fi
    info "Native database with verified ownership detected, removing..."
    
    # Determine the database type from available variables
    if [[ -n "${DB_POSTGRES_NAME:-}" ]]; then
        mooship_validate_database_identifiers postgres "$DB_POSTGRES_NAME" "$DB_POSTGRES_USER"
        mooship_validate_port "${DB_PORT:-5432}"
        # Remove the PostgreSQL database and user
        info "Removing PostgreSQL database: ${DB_POSTGRES_NAME}"
        
        if command -v psql &> /dev/null; then
            # Terminate all active connections
            sudo -u postgres psql --port="${DB_PORT:-5432}" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_POSTGRES_NAME}';" 2>/dev/null || true
            
            # Remove the database
            sudo -u postgres psql --port="${DB_PORT:-5432}" -c "DROP DATABASE IF EXISTS \"${DB_POSTGRES_NAME}\";" 2>/dev/null && \
                info "Database ${DB_POSTGRES_NAME} removed" || \
                error "Could not remove database ${DB_POSTGRES_NAME}"
            
            # Remove the user
            sudo -u postgres psql --port="${DB_PORT:-5432}" -c "DROP USER IF EXISTS \"${DB_POSTGRES_USER:-}\";" 2>/dev/null && \
                info "User ${DB_POSTGRES_USER:-} removed" || \
                error "Could not remove user ${DB_POSTGRES_USER:-}"
        else
            error "PostgreSQL client is not installed; native database removal was not performed"
        fi
        
    elif [[ -n "${DB_MYSQL_NAME:-}" ]]; then
        mooship_validate_database_identifiers mysql "$DB_MYSQL_NAME" "$DB_MYSQL_USER"
        mooship_validate_port "${DB_PORT:-3306}"
        # Remove the MySQL database and user
        info "Removing MySQL database: ${DB_MYSQL_NAME}"

        if command -v mysql &> /dev/null; then
            # The system MySQL root password is not stored in .env; supply it through --db-root-password
            local ROOT_PW="${DB_ROOT_PASSWORD:-}"
            if [[ -n "$ROOT_PW" ]]; then
                # Remove the database
                MYSQL_PWD="$ROOT_PW" mysql --protocol=TCP --host=127.0.0.1 --port="${DB_PORT:-3306}" -u root -e "DROP DATABASE IF EXISTS \`${DB_MYSQL_NAME}\`;" 2>/dev/null && \
                    info "Database ${DB_MYSQL_NAME} removed" || \
                    error "Could not remove database ${DB_MYSQL_NAME}"

                # Remove the user (deploy creates 'user'@'%'; old versions created 'user'@'localhost')
                MYSQL_PWD="$ROOT_PW" mysql --protocol=TCP --host=127.0.0.1 --port="${DB_PORT:-3306}" -u root -e "DROP USER IF EXISTS '${DB_MYSQL_USER:-}'@'%', '${DB_MYSQL_USER:-}'@'localhost';" 2>/dev/null && \
                    info "User ${DB_MYSQL_USER:-} removed" || \
                    error "Could not remove user ${DB_MYSQL_USER:-}"

                MYSQL_PWD="$ROOT_PW" mysql --protocol=TCP --host=127.0.0.1 --port="${DB_PORT:-3306}" -u root -e "FLUSH PRIVILEGES;" 2>/dev/null || true
            else
                NATIVE_DATABASE_RETAINED=true
                warn "MySQL root password not supplied (--db-root-password); database not removed. Remove it manually:"
                warn "  DROP DATABASE \`${DB_MYSQL_NAME}\`; DROP USER '${DB_MYSQL_USER:-}'@'%';"
            fi
        else
            error "MySQL client is not installed; native database removal was not performed"
        fi
    fi
}

# ==================== Retain backup archives =========
remove_backup_archive() {
    info "Backups retained. Removing the project does not remove archives."
    # A schedule left behind would fail every night for the missing project
    mooship_unschedule_backup "$SLUG"
}

# ==================== Remove the project directory =========
remove_project_directory() {
    info "Removing project directory ${PROJECT_DIR}..."
    
    local CHECKED_DIR
    CHECKED_DIR=$(mooship_project_path "$SLUG")
    [[ "$PROJECT_DIR" == "$CHECKED_DIR" ]] || error "The project path changed; removal is prohibited"
    rm -rf -- "$CHECKED_DIR"
    
    if [[ $? -eq 0 ]]; then
        info "Project directory removed"
    else
        error "Could not remove the project directory"
    fi
}

# ==================== Final summary =====
print_summary() {
    echo ""
    echo "============================================================"
    info "Project removal completed!"
    echo "============================================================"
    echo ""
    echo "PROJECT: ${SLUG}"
    echo "  Domain:         ${DOMAIN}"
    if [[ "${NATIVE_DATABASE_RETAINED:-false}" == true ]]; then
        echo "  Status:         DIRECTORY REMOVED, NATIVE DATABASE AND USER RETAINED"
    else
        echo "  Status:         PERMANENTLY REMOVED"
    fi
    echo ""
    echo "What was removed:"
    echo "  ✓ Configuration nginxproxy/sites/${SLUG}.conf"
    echo "  ✓ Entries from nginxproxy/docker-compose.yml"
    echo "  ✓ Project containers stopped"
    echo "  ✓ All project volumes removed"
    echo "  ✓ Project network removed"
    echo "  ✓ Backups retained; backup schedule (schedule-backup.sh) removed"
    echo "  ✓ Project directory ${PROJECT_DIR} removed"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    mooship_require_docker
    
    # Request removal confirmation
    confirm_deletion
    
    remove_from_docker_compose
    remove_from_nginx_conf
    apply_proxy_config
    stop_project_containers
    remove_project_volumes
    remove_project_network
    restart_nginxproxy
    remove_native_database
    remove_backup_archive
    remove_project_directory
    
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
