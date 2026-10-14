#!/bin/bash
set -euo pipefail

# ============================================================
# 03-moodle-5-version.sh — a Moodle 5.x branch
# ============================================================
# Scenario:
#   Install the newest Moodle 5.3 LTS release. PHP version is omitted: for Moodle 5+,
#   the script selects PHP 8.4 automatically.
#
# Result:
#   - project /var/www/edu5, site https://edu5.example.com
#   - the newest Moodle 5.3.x + PHP 8.4, PostgreSQL 17 in a container
#   - in 5.1+, web files are in public/: the script switches the nginx document root
#     to /var/www/html/public; config.php, admin/cli, and cron remain at the code root
#
# Before running, replace:
#   - edu5 / edu5.example.com → your slug and domain
#   - 5.3 → another branch (X.Y selects its newest release) or an exact X.Y.Z release
#     (5.0.x uses the old layout without public/); list the available releases with:
#       git ls-remote --tags --refs https://github.com/moodle/moodle 'refs/tags/v5.3.*'
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
  --moodle-version 5.3 \
  --db-type postgres \
  --ssl-email admin@example.com
