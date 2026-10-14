#!/bin/bash
set -euo pipefail

# ============================================================
# schedule-backup.sh — daily full backups through a systemd timer
# ============================================================
# Usage:
#   sudo bash schedule-backup.sh --slug lms [--at 03:30] [--keep 7] [--post-hook /path/hook]
#   sudo bash schedule-backup.sh --slug lms --status
#   sudo bash schedule-backup.sh --slug lms --disable
#
# Creates mooship-backup-<slug>.service and .timer in /etc/systemd/system. The service runs
# backup.sh --slug <slug> --keep N (and --post-hook) at the given time, with up to 15 minutes
# of random delay so several sites do not pause at once; a missed run (server off) starts after
# the next boot. Each backup pauses the site's PHP, cron, and nginx during the snapshot.
#
# Options:
#   --slug SLUG        Project slug (required)
#   --at HH:MM         Daily start time, server time zone (default 03:30)
#   --keep N           Archives to keep in /var/backups/mooship (default 7)
#   --post-hook PATH   Executable run as PATH <archive> <slug> after each backup
#                      (owned by root, not writable by others); see README for an rclone example
#   --status           Show the timer and the last run
#   --disable          Remove the schedule (existing archives are kept)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WWW_DIR="${WWW_DIR:-/var/www}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    awk 'NR < 5 { next } !/^#/ { exit } /^# =+$/ { next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# systemd treats %, quotes, and backslashes specially in ExecStart; Mooship paths never need them
systemd_safe_path() {
    local unsafe='[%"\\[:space:]]'
    [[ ! "$1" =~ $unsafe ]] ||
        mooship_die "Paths in the systemd unit cannot contain spaces, quotes, backslashes, or %: $1"
}

write_unit() {
    local target="$1" temporary
    temporary=$(mktemp "${target}.XXXXXX")
    cat > "$temporary"
    chmod 644 "$temporary"
    mv -f -- "$temporary" "$target"
}

enable_schedule() {
    local slug="$1" at="$2" keep="$3" hook="$4" unit exec
    unit=$(mooship_backup_unit "$slug")
    mooship_require_project
    [[ -f "$PROJECT_DIR/public_html/config.php" ]] || mooship_die "Moodle is not installed in $PROJECT_DIR"
    [[ "$at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || mooship_die "--at must be HH:MM (24-hour), received: $at"
    [[ "$keep" =~ ^[1-9][0-9]{0,3}$ ]] || mooship_die "--keep must be a positive number"
    systemd_safe_path "$SCRIPT_DIR"
    exec="/bin/bash $SCRIPT_DIR/backup.sh --slug $slug --keep $keep"
    if [[ -n "$hook" ]]; then
        mooship_validate_hook "$hook"
        systemd_safe_path "$hook"
        exec+=" --post-hook $hook"
    fi
    mkdir -p -- "$UNIT_DIR"

    write_unit "$UNIT_DIR/$unit.service" <<EOF
# Managed by Mooship schedule-backup.sh
[Unit]
Description=Mooship full backup of ${slug}
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=${exec}
# Keep the snapshot from competing with the sites for CPU and disk
Nice=10
IOSchedulingClass=idle
EOF

    write_unit "$UNIT_DIR/$unit.timer" <<EOF
# Managed by Mooship schedule-backup.sh
[Unit]
Description=Daily Mooship backup of ${slug}

[Timer]
OnCalendar=*-*-* ${at}:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$unit.timer"
    printf '[OK] Daily backup of %s at %s (+ up to 15 min), keeping %s archives.\n' "$slug" "$at" "$keep"
    printf '     Check with: sudo bash %s/schedule-backup.sh --slug %s --status\n' "$SCRIPT_DIR" "$slug"
}

show_status() {
    local unit
    unit=$(mooship_backup_unit "$1")
    if [[ ! -e "$UNIT_DIR/$unit.timer" ]]; then
        printf 'No backup schedule for %s.\n' "$1"
        return 0
    fi
    systemctl list-timers --all --no-pager "$unit.timer" || true
    systemctl status --no-pager --lines 10 "$unit.service" || true
}

schedule_main() {
    local slug="" at="03:30" keep=7 hook="" action=enable
    while (($#)); do
        case "$1" in
            --slug) slug="${2:?A value is required for --slug}"; shift 2 ;;
            --at) at="${2:?A value is required for --at}"; shift 2 ;;
            --keep) keep="${2:?A value is required for --keep}"; shift 2 ;;
            --post-hook) hook="${2:?A path is required for --post-hook}"; shift 2 ;;
            --status) action=status; shift ;;
            --disable) action=disable; shift ;;
            -h|--help) usage; return 0 ;;
            *) mooship_die "Unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ $EUID == 0 ]] || mooship_die "Root privileges are required (sudo)"
    mooship_validate_slug "$slug"
    SLUG="$slug"
    case "$action" in
        enable) enable_schedule "$slug" "$at" "$keep" "$hook" ;;
        status) show_status "$slug" ;;
        disable) mooship_unschedule_backup "$slug" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then schedule_main "$@"; fi
