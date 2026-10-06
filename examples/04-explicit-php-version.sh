#!/bin/bash
set -euo pipefail

# ============================================================
# 04-explicit-php-version.sh — an explicit PHP version
# ============================================================
# Scenario:
#   Use a specific PHP version instead of the script's automatic selection
#   (for example, for compatibility with third-party plugins).
#   Moodle 4.4 defaults to PHP 8.2; this example uses 8.1.
#
# Result:
#   - project /var/www/school, site https://school.example.com
#   - Moodle 4.4.0 + PHP 8.1 (image from moodle/.docker/php/php81.Dockerfile,
#     settings from moodle/.config/php/php81.ini)
#
# Before running, replace:
#   - school / school.example.com → your slug and domain
#   - 4.4.0 / 8.1 → your versions. PHP 7.4 and 8.0–8.4 are available (format: 8.1 or 81).
#     The script DOES NOT check PHP/Moodle version compatibility; if they
#     are incompatible, the installation environment check will fail.
#   - admin@example.com → your email
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/04-explicit-php-version.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug school \
  --domain school.example.com \
  --moodle-version 4.4.0 \
  --php-version 8.1 \
  --db-type postgres \
  --ssl-email admin@example.com
