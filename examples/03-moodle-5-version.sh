#!/bin/bash
set -euo pipefail

# ============================================================
# 03-moodle-5-version.sh — a specific Moodle 5.x version
# ============================================================
# Scenario:
#   Install Moodle 5.1.x. PHP version is omitted: for Moodle 5+,
#   the script selects PHP 8.4 automatically.
#
# Result:
#   - project /var/www/edu5, site https://edu5.example.com
#   - Moodle 5.1.4 + PHP 8.4, PostgreSQL 17 in a container
#   - in 5.1+, web files are in public/: the script switches the nginx document root
#     to /var/www/html/public; config.php, admin/cli, and cron remain at the code root
#
# Before running, replace:
#   - edu5 / edu5.example.com → your slug and domain
#   - 5.1.4 → your release (5.0.x uses the old layout without public/);
#     tag v<version> must exist:
#       curl -sIL -o /dev/null -w '%{http_code}\n' \
#         https://github.com/moodle/moodle/archive/refs/tags/v5.1.4.zip   # 200
#   - admin@example.com → your email
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/03-moodle-5-version.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug edu5 \
  --domain edu5.example.com \
  --moodle-version 5.1.4 \
  --db-type postgres \
  --ssl-email admin@example.com
