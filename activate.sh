#!/bin/bash

# ============================================================
# activate.sh — activate a deactivated project
# ============================================================
# Usage:
#   sudo bash activate.sh --slug cp
#
# What the script does:
#   1. Start project containers (docker compose up -d --build)
#   2. Restore site configuration: nginxproxy/sites/<slug>.conf.disabled → <slug>.conf
#   3. Uncomment slug entries in nginxproxy/docker-compose.yml
#   4. Restart project php (if present) and nginx containers
#   5. Apply nginxproxy/docker-compose.yml and restart the proxy
#
# Options:
#   --slug SLUG           Project slug (required)
# ============================================================

set -euo pipefail
umask 077

# ==================== Variables ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
source "$SCRIPT_DIR/lib/common.sh"
SLUG=""

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
            *) error "Unknown argument: $1" ;;
        esac
    done

    [[ -z "$SLUG" ]] && error "Missing --slug"

    mooship_require_project
}

# ==================== Start project containers =
start_project_containers() {
    info "Starting containers for project ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Cannot enter ${PROJECT_DIR}"
    
    local services
    services=$(docker compose config --services)
    if grep -qx php <<< "$services"; then
        mooship_require_project_runtime
        docker compose build --pull php cron || error "Could not build patched PHP images"
        mooship_verify_project_php || error "PHP security verification failed before activation"
    fi
    if docker compose up -d --build; then
        info "Project ${SLUG} containers started"
    else
        error "Failed to start containers"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Enable site configuration in nginxproxy ====
# deactivate.sh renames the configuration to <slug>.conf.disabled
enable_site_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    if [[ -f "${SITE_CONF}.disabled" ]]; then
        mv "${SITE_CONF}.disabled" "$SITE_CONF"
        info "Configuration ${SLUG}.conf enabled"
    elif [[ ! -f "$SITE_CONF" ]]; then
        error "Configuration ${SITE_CONF} not found"
    fi
}

# ==================== Uncomment docker-compose.yml entries ====
uncomment_in_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "docker-compose.yml not found: ${COMPOSE_FILE}"
    fi
    
    info "Uncommenting ${SLUG} entries in docker-compose.yml..."
    
    python3 "$SCRIPT_DIR/lib/proxy.py" activate "${COMPOSE_FILE}" "${SLUG}"

    if [[ $? -eq 0 ]]; then
        info "docker-compose.yml updated successfully"
    else
        error "Failed to update docker-compose.yml"
    fi
}

# ==================== Restart project containers =
restart_project_services() {
    cd "${PROJECT_DIR}" || error "Cannot enter ${PROJECT_DIR}"

    # HTML projects have no php service; restart only existing services
    local SERVICES
    SERVICES=$(docker compose config --services 2>/dev/null | grep -xE 'php|nginx' | tr '\n' ' ' || true)
    info "Restarting ${SERVICES:-nginx }for project ${SLUG}..."

    # shellcheck disable=SC2086
    if docker compose restart ${SERVICES:-nginx}; then
        info "Project ${SLUG} containers ${SERVICES:-nginx }restarted"
    else
        error "Failed to restart containers"
    fi

    cd "${SCRIPT_DIR}" || true
}

verify_project_services() {
    local services running service
    cd "${PROJECT_DIR}"
    services=$(docker compose config --services)
    running=$(docker compose ps --status running --services)
    for service in php nginx; do
        if grep -qx "$service" <<< "$services"; then
            grep -qx "$service" <<< "$running" || error "Service $service is not running"
        fi
    done
    docker compose exec -T nginx nginx -t || error "Project nginx configuration check failed"
    cd "${SCRIPT_DIR}"
}

# ==================== Restart nginxproxy ========
restart_nginxproxy() {
    info "Applying nginxproxy/docker-compose.yml and restarting the proxy..."

    # up -d reconnects the proxy to the uncommented project network;
    # restart reloads site configurations
    if (cd "${PROXY_DIR}" && docker compose up -d) && docker restart nginxproxy; then
        docker exec nginxproxy nginx -t || error "nginxproxy configuration check failed"
        info "nginxproxy restarted successfully"
    else
        error "Failed to restart nginxproxy"
    fi
}

# ==================== Final summary =====
print_summary() {
    echo ""
    echo "============================================================"
    info "Project activation completed!"
    echo "============================================================"
    echo ""
    echo "PROJECT: ${SLUG}"
    echo "  Status:         ACTIVATED"
    echo ""
    echo "Completed actions:"
    echo "  ✓ Project containers started (docker compose up -d --build)"
    echo "  ✓ nginxproxy/sites/${SLUG}.conf enabled"
    echo "  ✓ Entries uncommented in nginxproxy/docker-compose.yml"
    echo "  ✓ Project php (if present) and nginx containers restarted"
    echo "  ✓ nginxproxy restarted"
    echo ""
    echo "The project is available at the address in its configuration"
    echo ""
    echo "To deactivate the project, run:"
    echo "  sudo bash deactivate.sh --slug ${SLUG}"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    mooship_require_docker
    
    info "Starting activation of project ${SLUG}..."
    echo ""
    
    start_project_containers
    restart_project_services
    verify_project_services
    enable_site_conf
    uncomment_in_docker_compose
    restart_nginxproxy
    
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
