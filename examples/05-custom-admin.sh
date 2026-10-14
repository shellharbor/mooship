#!/bin/bash
set -euo pipefail

# ============================================================
# 05-custom-admin.sh — a custom administrator login, password, and email
# ============================================================
# Scenario:
#   Create the Moodle administrator with a specified login, password, and email
#   instead of admin / a generated password / admin@<domain>.
#
# Result:
#   - project /var/www/campus, site https://campus.example.com
#   - administrator lmsadmin with the specified password;
#     and email it-team@example.com (password resets and notifications go there)
#   - administrator credentials appended to /var/www/campus/.env (MOODLE_ADMIN_*)
#
# Before running, replace:
#   - campus / campus.example.com → your slug and domain
#   - lmsadmin → login (lowercase Latin letters and digits)
#   - ChangeMe_Admin_2026 → a REAL password; characters A-Za-z0-9@%_+- only
#     (or omit --moodle-admin-password to generate a password)
#   - it-team@example.com → a mailbox that exists (default: <login>@<domain>)
#   - admin@example.com → your email for Let's Encrypt
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/05-custom-admin.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug campus \
  --domain campus.example.com \
  --db-type postgres \
  --moodle-admin-user lmsadmin \
  --moodle-admin-password 'ChangeMe_Admin_2026' \
  --moodle-admin-email it-team@example.com \
  --ssl-email admin@example.com
