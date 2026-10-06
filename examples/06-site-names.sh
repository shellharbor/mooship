#!/bin/bash
set -euo pipefail

# ============================================================
# 06-site-names.sh — full and short site names
# ============================================================
# Scenario:
#   Set Moodle site names during installation instead of the defaults
#   ("Moodle Site - <slug>" and "<slug>").
#
# Result:
#   - project /var/www/portal, site https://portal.example.com
#   - full name "Corporate Learning Portal", short name "Portal"
#   - administrator admin with a generated password
#
# Before running, replace:
#   - portal / portal.example.com → your slug and domain
#   - site names (quote values containing spaces);
#     these can later be changed in Site home settings
#   - admin@example.com → your email
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/06-site-names.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug portal \
  --domain portal.example.com \
  --db-type postgres \
  --moodle-site-fullname "Corporate Learning Portal" \
  --moodle-site-shortname "Portal" \
  --ssl-email admin@example.com
