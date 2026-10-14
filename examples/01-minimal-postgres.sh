#!/bin/bash
set -euo pipefail

# ============================================================
# 01-minimal-postgres.sh — minimal Moodle + PostgreSQL
# ============================================================
# Scenario:
#   The shortest invocation: required flags only. --slug is omitted,
#   so the script generates a slug and PREPENDS it to the domain.
#
# Result:
#   - slug of 8 random characters [a-z0-9], domain <slug>.example.com
#   - the newest Moodle 4.5.x release (default) + PHP 8.3 (selected automatically)
#   - PostgreSQL 17 in container <slug>_db, Redis, cron, certbot
#   - generated passwords and database names; credentials in /var/www/<slug>/.env,
#     with passwords hidden from normal output
#
# Before running, replace:
#   - example.com       → your domain; a wildcard DNS record *.<domain> must
#                         point to this server (the slug is not known in advance)
#   - admin@example.com → your email for Let's Encrypt
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/01-minimal-postgres.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --domain example.com \
  --db-type postgres \
  --ssl-email admin@example.com
