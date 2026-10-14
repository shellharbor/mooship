#!/bin/bash
set -euo pipefail

# ============================================================
# 10-production-full.sh — production: the full set of parameters
# ============================================================
# Scenario:
#   A production site with predefined credentials and ports,
#   project registration in an external system (--endpoint), and
#   a complete project backup after deployment (--create-backup),
#   outgoing mail through SMTP, and a fixed resource profile.
#
# Result:
#   - project /var/www/academy, site https://academy.example.com
#   - Moodle 4.5.15 (an exact release, reproducible) + PHP 8.3, PostgreSQL 17 in container academy_db:
#     database moodle_prod, user moodle_user; host database port 5601
#   - PHP-FPM on 127.0.0.1:9101, Redis on host port 6501 with a specified password
#   - administrator lmsadmin <lms-admin@example.com>, site "Academy" (ACAD)
#   - mail through smtp.example.com:587 (STARTTLS) from noreply@example.com;
#     the SMTP password goes to Moodle's settings, not to .env
#   - medium resource profile: 16 PHP-FPM workers, PostgreSQL tuned for about 4 GB
#   - PUT request with project JSON to https://api.example.com/deployments
#     (database and Redis passwords are sent as plain text in the payload; use HTTPS only)
#   - complete backup /var/backups/mooship/academy_<YYYYMMDD_HHMMSS>.tar.gz
#     (database, files, configuration, SSL; mode 600)
#
# Before running, replace:
#   - academy / academy.example.com → your slug and domain
#   - all ChangeMe_* → REAL passwords using characters A-Za-z0-9@%_+-
#   - ports 5601 / 9101 / 6501 → free ports on this server (the script
#     does not check availability of explicitly specified ports)
#   - https://api.example.com/deployments → your endpoint
#   - admin@example.com, lms-admin@example.com, noreply@example.com → your addresses
#   - smtp.example.com and the SMTP credentials → your mail provider
#   Redis, database, and PHP-FPM ports are published only on 127.0.0.1.
#   --create-dhparam is omitted: client TLS terminates at nginxproxy, so dhparam
#   would only affect the internal proxy-to-project connection.
#   Afterwards, schedule daily backups:
#     sudo bash "$DEPLOY_DIR/schedule-backup.sh" --slug academy --keep 14
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/10-production-full.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug academy \
  --domain academy.example.com \
  --moodle-version 4.5.15 \
  --db-type postgres \
  --db-postgres-name moodle_prod \
  --db-postgres-user moodle_user \
  --db-postgres-password 'ChangeMe_Pg_2026' \
  --port-postgres 5601 \
  --port-php 9101 \
  --port-redis 6501 \
  --redis-password 'ChangeMe_Redis_2026' \
  --moodle-admin-user lmsadmin \
  --moodle-admin-password 'ChangeMe_Admin_2026' \
  --moodle-admin-email lms-admin@example.com \
  --moodle-site-fullname "Academy" \
  --moodle-site-shortname "ACAD" \
  --smtp-host smtp.example.com:587 \
  --smtp-user lms@example.com \
  --smtp-password 'ChangeMe_Smtp_2026' \
  --noreply-email noreply@example.com \
  --profile medium \
  --endpoint https://api.example.com/deployments \
  --create-backup \
  --ssl-email admin@example.com
