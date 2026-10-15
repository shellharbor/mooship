#!/bin/bash

# ============================================================
# deactivate.sh — deactivate/shut down a project without deleting it
# ============================================================
# Usage:
#   sudo bash deactivate.sh --slug cp
#
# What the script does:
#   1. Stop project containers (docker compose down)
#   2. Disable the site config: nginxproxy/sites/<slug>.conf → <slug>.conf.disabled
#   3. Comment out slug entries in nginxproxy/docker-compose.yml
#   4. Apply proxy Compose changes and restart nginxproxy
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

# ==================== Stop project containers =
stop_project_containers() {
    info "Stopping containers for project ${SLUG}..."
    cd "${PROJECT_DIR}" || error "Cannot enter ${PROJECT_DIR}"
    
    if docker compose down; then
        info "Containers for project ${SLUG} stopped"
    else
        error "Problems occurred while stopping containers"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Disable the nginxproxy site config ====
# Project containers are stopped: leaving sites/<slug>.conf would prevent nginx
# from resolving upstream <slug>_nginx and starting, taking all sites offline
disable_site_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"

    if [[ -f "$SITE_CONF" ]]; then
        mv "$SITE_CONF" "${SITE_CONF}.disabled"
        info "Config ${SLUG}.conf disabled (renamed to ${SLUG}.conf.disabled)"
    else
        warn "Config ${SITE_CONF} not found, skipping."
    fi
}

# ==================== Comment out docker-compose.yml entries ====
comment_in_docker_compose() {
    local COMPOSE_FILE="${PROXY_DIR}/docker-compose.yml"
    
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "docker-compose.yml not found: ${COMPOSE_FILE}"
    fi
    
    info "Commenting out ${SLUG} entries in docker-compose.yml..."
    
    python3 "$SCRIPT_DIR/lib/proxy.py" deactivate "${COMPOSE_FILE}" "${SLUG}"

    if [[ $? -eq 0 ]]; then
        info "docker-compose.yml updated successfully"
    else
        error "Failed to update docker-compose.yml"
    fi
}

# ==================== Restart nginxproxy ========
restart_nginxproxy() {
    info "Applying nginxproxy/docker-compose.yml and restarting the proxy..."
    
    # Recreate when necessary to detach the disabled site's network and volume.
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
    info "Project deactivation completed!"
    echo "============================================================"
    echo ""
    echo "PROJECT: ${SLUG}"
    echo "  Status:         DEACTIVATED"
    echo ""
    echo "Completed actions:"
    echo "  ✓ Project containers stopped (docker compose down)"
    echo "  ✓ Config nginxproxy/sites/${SLUG}.conf disabled (.disabled)"
    echo "  ✓ Entries commented out in nginxproxy/docker-compose.yml"
    echo "  ✓ nginxproxy restarted"
    echo ""
    echo "To activate the project, use:"
    echo "  sudo bash activate.sh --slug ${SLUG}"
    echo ""
    echo "To permanently remove the project, use:"
    echo "  sudo bash remove.sh --slug ${SLUG} --domain <domain>"
    echo ""
    echo "============================================================"
    echo ""
}

# ==================== MAIN ==============================
main() {
    check_root
    parse_args "$@"
    mooship_require_docker
    
    info "Starting deactivation of project ${SLUG}..."
    echo ""
    
    stop_project_containers
    disable_site_conf
    comment_in_docker_compose
    restart_nginxproxy
    
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
