#!/bin/bash
set -euo pipefail

# ============================================================
# 08-basic-auth.sh — a site protected by HTTP Basic Authentication
# ============================================================
# Scenario:
#   A test or demo environment protected from outsiders
#   with an additional browser login/password.
#
# Result:
#   - project /var/www/staging, site https://staging.example.com
#   - .config/nginx/.htpasswd (created through docker run httpd:alpine htpasswd)
#   - auth_basic in the project's nginx HTTPS server block protects EVERYTHING,
#     including .php, /admin, web services, and the mobile app
#   - AUTH_USER / AUTH_PASSWORD saved in /var/www/staging/.env
#   - Basic Auth protects the application on HTTPS (and on HTTP with --no-ssl)
#     while ACME challenges remain public
#
# Before running, replace:
#   - staging / staging.example.com → your slug and domain
#   - reviewer / ChangeMe_Basic_2026 → your login and REAL password
#     (characters A-Za-z0-9@%_+-), or omit both flags to generate them
#   - admin@example.com → your email
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/08-basic-auth.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug staging \
  --domain staging.example.com \
  --db-type postgres \
  --enable-basic-auth \
  --auth-user reviewer \
  --auth-password 'ChangeMe_Basic_2026' \
  --ssl-email admin@example.com
