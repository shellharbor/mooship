#!/bin/bash
set -euo pipefail

# ============================================================
# 02-mysql-explicit-slug.sh — Moodle + MySQL with an explicit slug
# ============================================================
# Scenario:
#   Standard deployment with a clear project name and MySQL in a container.
#   With --slug, the domain is used as provided.
#
# Result:
#   - project /var/www/lms, site https://lms.example.com
#   - MySQL 9.1 in container lms_db (config.php: dbhost=lms_db, dbport=3306)
#   - Moodle 4.5.0 + PHP 8.3, generated passwords and database names
#
# Before running, replace:
#   - lms / lms.example.com → your slug (lowercase letters and digits) and domain
#     (the domain's A record must point to this server)
#   - admin@example.com     → your email for Let's Encrypt
#   If /var/www/lms already exists, the command refuses to proceed and preserves data.
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/02-mysql-explicit-slug.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug lms \
  --domain lms.example.com \
  --db-type mysql \
  --ssl-email admin@example.com
