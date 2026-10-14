#!/bin/bash
set -uo pipefail

# ============================================================
# doctor.sh — read-only health check of Mooship sites
# ============================================================
# Usage:
#   sudo bash doctor.sh                 # every Moodle project in /var/www
#   sudo bash doctor.sh --slug lms      # one project (repeatable)
#   sudo bash doctor.sh --security      # also run Moodle's security checks
#
# Checks: Docker, nginxproxy and its configuration, disk usage, and for each site its
# containers, the login page through nginxproxy, the certificate, Moodle's status checks
# (admin/cli/checks.php: cron, failed tasks, ...), outgoing mail, and backups.
#
# Exit code (Nagios/Icinga compatible): 0 OK, 1 WARNING, 2 CRITICAL.
# Nothing is changed; only Docker inspection, nginx -t, HTTP requests, and Moodle CLI reads.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WWW_DIR="${WWW_DIR:-/var/www}"
PROXY_DIR="${WWW_DIR}/nginxproxy"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/mooship}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
source "$SCRIPT_DIR/lib/common.sh"

# Thresholds
DISK_WARN_PERCENT=85
DISK_FAIL_PERCENT=95
CERT_WARN_DAYS=14
CERT_FAIL_DAYS=3
BACKUP_WARN_HOURS=48

STATUS=0  # 0 OK, 1 WARNING, 2 CRITICAL

usage() {
    awk 'NR < 5 { next } !/^#/ { exit } /^# =+$/ { next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# report OK|INFO|WARN|FAIL message
report() {
    local level="$1"
    shift
    case "$level" in
        WARN) if ((STATUS < 1)); then STATUS=1; fi ;;
        FAIL) STATUS=2 ;;
    esac
    printf '  [%-4s] %s\n' "$level" "$*"
}

# ==================== Server checks ====================
check_docker() {
    if docker info >/dev/null 2>&1; then
        report OK "Docker daemon is running"
        return 0
    fi
    report FAIL "Docker daemon is unavailable: systemctl status docker"
    return 1
}

check_proxy() {
    local state output
    state=$(docker inspect -f '{{.State.Status}}' nginxproxy 2>/dev/null) || state=missing
    if [[ "$state" != running ]]; then
        report FAIL "nginxproxy is ${state}: docker logs --tail 50 nginxproxy"
        return
    fi
    if output=$(docker exec nginxproxy nginx -t 2>&1); then
        report OK "nginxproxy is running; configuration is valid"
    else
        report FAIL "nginxproxy configuration is invalid: $(printf '%s\n' "$output" | grep -m1 emerg || printf '%s\n' "$output" | tail -n 1)"
    fi
}

check_disk() {
    local path line mount use seen=" "
    for path in "$WWW_DIR" /var/lib/docker "$BACKUP_DIR"; do
        [[ -e "$path" ]] || continue
        line=$(df -P -- "$path" 2>/dev/null | awk 'NR == 2 { sub("%", "", $5); print $6, $5 }') || continue
        read -r mount use <<< "$line"
        [[ -n "$mount" && "$use" =~ ^[0-9]+$ && "$seen" != *" $mount "* ]] || continue
        seen+="$mount "
        if ((use >= DISK_FAIL_PERCENT)); then
            report FAIL "Disk ${mount}: ${use}% used"
        elif ((use >= DISK_WARN_PERCENT)); then
            report WARN "Disk ${mount}: ${use}% used"
        else
            report OK "Disk ${mount}: ${use}% used"
        fi
    done
}

# ==================== Site checks ====================
check_containers() {
    local services service state
    local -a running=() problems=()
    services=$(docker compose --project-directory "$PROJECT_DIR" -f "$PROJECT_DIR/docker-compose.yml" \
        config --services 2>/dev/null) || {
        report FAIL "Cannot read ${PROJECT_DIR}/docker-compose.yml (docker compose config)"
        return
    }
    while IFS= read -r service; do
        # One-off services exit after their job
        case "$service" in ""|certbot|permissions) continue ;; esac
        state=$(docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' \
            "${SLUG}_${service}" 2>/dev/null) || state=missing
        case "$state" in
            running|running/healthy) running+=("$service") ;;
            *) problems+=("${service}: ${state}") ;;
        esac
    done <<< "$services"
    if ((${#problems[@]})); then
        report FAIL "Containers not running: ${problems[*]} (cd ${PROJECT_DIR} && docker compose ps -a)"
    else
        report OK "Containers running: ${running[*]}"
    fi
}

check_http() {
    local port=443 url output code
    [[ "$SCHEME" == https ]] || port=80
    url="${SCHEME}://${DOMAIN}/login/index.php"
    # Through the local nginxproxy, independent of public DNS
    if ! output=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
            --resolve "${DOMAIN}:${port}:127.0.0.1" "$url" 2>&1); then
        report FAIL "${url}: ${output//$'\n'/ }"
        return
    fi
    code="${output: -3}"
    case "$code" in
        200) report OK "${url} answers 200" ;;
        401)
            if [[ -n "$AUTH_USER" ]]; then report OK "${url} answers 401 (Basic Auth enabled)"
            else report WARN "${url} answers 401 without Basic Auth configured"; fi ;;
        503) report WARN "${url} answers 503 (maintenance mode or overload)" ;;
        5??) report FAIL "${url} answers ${code}: docker compose logs --tail 50 php nginx" ;;
        *) report WARN "${url} answers ${code}" ;;
    esac
}

check_certificate() {
    local output expires days
    if ! output=$(docker exec "${SLUG}_nginx" openssl x509 -enddate -noout \
            -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" 2>&1); then
        report FAIL "No certificate for ${DOMAIN} in the project (see README, \"SSL certificate not obtained\")"
        return
    fi
    if ! expires=$(date -u -d "${output#notAfter=}" +%s 2>/dev/null); then
        report WARN "Cannot read the certificate expiry: ${output}"
        return
    fi
    days=$(( (expires - $(date -u +%s)) / 86400 ))
    if ((days < CERT_FAIL_DAYS)); then
        report FAIL "Certificate for ${DOMAIN} expires in ${days} days: docker compose logs certbot_renew"
    elif ((days < CERT_WARN_DAYS)); then
        report WARN "Certificate for ${DOMAIN} expires in ${days} days; renewal is overdue: docker compose logs certbot_renew"
    else
        report OK "Certificate for ${DOMAIN} is valid for ${days} more days"
    fi
}

check_moodle() {
    local type="$1" output code summary
    if ! docker exec "${SLUG}_php" test -f /var/www/html/admin/cli/checks.php 2>/dev/null; then
        report INFO "Moodle ${type} checks are unavailable (admin/cli/checks.php needs Moodle 3.9+)"
        return
    fi
    if output=$(docker exec "${SLUG}_php" php /var/www/html/admin/cli/checks.php --type="$type" 2>&1); then
        code=0
    else
        code=$?
    fi
    summary=$(printf '%s\n' "$output" | head -n 1)
    case "$code" in
        0) report OK "Moodle ${type} checks: ${summary}" ;;
        1) report WARN "Moodle ${type} checks: ${summary} (docker exec ${SLUG}_php php admin/cli/checks.php --type=${type} -v)" ;;
        2) report FAIL "Moodle ${type} checks: ${summary} (docker exec ${SLUG}_php php admin/cli/checks.php --type=${type} -v)" ;;
        *) report WARN "Moodle ${type} checks could not run (exit ${code}): ${summary}" ;;
    esac
}

check_mail() {
    local smtp
    smtp=$(docker exec -i "${SLUG}_php" php <<'PHP' 2>/dev/null
<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
echo (string) get_config('core', 'smtphosts');
PHP
) || {
        report WARN "Cannot read Moodle's mail settings"
        return
    }
    if [[ -n "$smtp" ]]; then
        report OK "Outgoing mail through SMTP ${smtp}"
    else
        report WARN "No SMTP server: Moodle cannot deliver email from the container (Site administration > Server > Email)"
    fi
}

check_backups() {
    local newest stamp name age unit
    # Only archives named by backup.sh; the slug pattern excludes other projects (lms vs lms2)
    newest=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${SLUG}_*.tar.gz" -printf '%T@ %f\n' 2>/dev/null |
        grep -E " ${SLUG}_[0-9]{8}_[0-9]{6}\.tar\.gz$" | sort -n | tail -n 1 || true)
    unit=$(mooship_backup_unit "$SLUG")
    if [[ -e "$UNIT_DIR/$unit.service" ]] && systemctl is-failed --quiet "$unit.service" 2>/dev/null; then
        report FAIL "The last scheduled backup failed: journalctl -u ${unit}.service"
    fi
    if [[ -z "$newest" ]]; then
        report WARN "No backups in ${BACKUP_DIR} (backup.sh, schedule-backup.sh)"
        return
    fi
    read -r stamp name <<< "$newest"
    age=$(( ($(date +%s) - ${stamp%%.*}) / 3600 ))
    if ((age > BACKUP_WARN_HOURS)); then
        report WARN "Last backup is ${age} hours old: ${BACKUP_DIR}/${name}"
    else
        report OK "Last backup ${age} hours ago: ${BACKUP_DIR}/${name}"
    fi
    if [[ -e "$UNIT_DIR/$unit.timer" ]]; then
        report INFO "Daily backups scheduled (${unit}.timer)"
    else
        report INFO "Backups are not scheduled (schedule-backup.sh --slug ${SLUG})"
    fi
}

doctor_project() {
    SLUG="$1"
    local security="$2"
    if ! PROJECT_DIR=$(mooship_project_path "$SLUG" 2>/dev/null) || [[ ! -f "$PROJECT_DIR/.env" ]]; then
        printf '\n%s\n' "$SLUG"
        report FAIL "Not a Mooship project: ${WWW_DIR}/${SLUG}"
        return
    fi
    DOMAIN=$(mooship_read_env "$PROJECT_DIR/.env" SITE_HOST)
    SCHEME=$(mooship_read_env "$PROJECT_DIR/.env" SITE_SCHEME)
    SCHEME="${SCHEME:-https}"
    AUTH_USER=$(mooship_read_env "$PROJECT_DIR/.env" AUTH_USER)
    printf '\n%s (%s://%s)\n' "$SLUG" "$SCHEME" "$DOMAIN"

    if [[ -e "$PROXY_DIR/sites/$SLUG.conf.disabled" && ! -e "$PROXY_DIR/sites/$SLUG.conf" ]]; then
        report INFO "Deactivated (deactivate.sh); runtime checks skipped"
        check_backups
        return
    fi
    if [[ ! -e "$PROXY_DIR/sites/$SLUG.conf" ]]; then
        report FAIL "Not published in nginxproxy: ${PROXY_DIR}/sites/${SLUG}.conf is missing"
    fi
    check_containers
    check_http
    if [[ "$SCHEME" == https ]]; then check_certificate; fi
    check_moodle status
    if [[ "$security" == true ]]; then check_moodle security; fi
    check_mail
    check_backups
}

# Moodle projects: directories with docker-compose.yml and public_html/config.php
list_projects() {
    local dir
    for dir in "$WWW_DIR"/*/; do
        dir="${dir%/}"
        [[ "$(basename "$dir")" != nginxproxy && -f "$dir/docker-compose.yml" &&
           -f "$dir/public_html/config.php" ]] && basename "$dir"
    done
    return 0
}

doctor_main() {
    local security=false slug
    local -a slugs=()
    while (($#)); do
        case "$1" in
            --slug) slugs+=("${2:?A value is required for --slug}"); shift 2 ;;
            --security) security=true; shift ;;
            -h|--help) usage; return 0 ;;
            *) mooship_die "Unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ $EUID == 0 ]] || mooship_die "Root privileges are required (sudo)"
    for slug in "${slugs[@]}"; do mooship_validate_slug "$slug"; done
    if ((${#slugs[@]} == 0)); then
        mapfile -t slugs < <(list_projects)
    fi

    printf 'Mooship doctor, %s\n\nServer\n' "$(date '+%Y-%m-%d %H:%M %Z')"
    if check_docker; then
        check_proxy
    fi
    check_disk
    if ((${#slugs[@]} == 0)); then
        report INFO "No Moodle projects in ${WWW_DIR}"
    elif docker info >/dev/null 2>&1; then
        for slug in "${slugs[@]}"; do doctor_project "$slug" "$security"; done
    fi

    local -a labels=(OK WARNING CRITICAL)
    printf '\nResult: %s\n' "${labels[$STATUS]}"
    return "$STATUS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    doctor_main "$@"
    exit $?
fi
