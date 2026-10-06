#!/bin/bash
set -euo pipefail

# ============================================================
# 09-no-ssl.sh — deploy a working HTTP site without a certificate
# ============================================================
# Scenario:
#   Serve a development site over HTTP, with a certificate optionally issued later.
#   DNS must point to the server, or resolve the domain locally while testing.
#   --ssl-email is not required with --no-ssl.
#
# Result:
#   - project /var/www/draft, Moodle installed through CLI
#   - config.php: wwwroot = http://draft.example.com; .env: SITE_SCHEME=http
#   - the application is available at http://draft.example.com through nginxproxy
#   - HTTPS blocks remain disabled; ACME challenges remain public
#   - HTTP traffic is unencrypted; use HTTPS for production
#   - to switch later, follow README.md's HTTP-to-HTTPS migration procedure
#
# Before running, replace:
#   - draft / draft.example.com → your slug and domain
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/09-no-ssl.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug draft \
  --domain draft.example.com \
  --db-type postgres \
  --no-ssl
