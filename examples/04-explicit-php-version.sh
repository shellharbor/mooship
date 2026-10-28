#!/bin/bash
set -euo pipefail

# ============================================================
# 04-explicit-php-version.sh — an explicit PHP version
# ============================================================
# Scenario:
#   Use a specific PHP version instead of the script's automatic selection
#   (for example, for compatibility with third-party plugins).
#   Moodle 4.5 defaults to PHP 8.3; this example uses patched PHP 8.2.
#
# Result:
#   - project /var/www/school, site https://school.example.com
#   - Moodle 4.5.15 + PHP 8.2 (image from moodle/.docker/php/php82.Dockerfile,
#     settings from moodle/.config/php/php82.ini)
#
# Before running, replace:
#   - school / school.example.com → your slug and domain
#   - 4.5.15 / 8.2 → your versions. Only patched PHP 8.2–8.4 are available (format: 8.2 or 82).
#     The script checks PHP/Moodle version compatibility; incompatible pairs
#     are rejected before creating deployment resources.
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
  --moodle-version 4.5.15 \
  --php-version 8.2 \
  --db-type postgres \
  --ssl-email admin@example.com
