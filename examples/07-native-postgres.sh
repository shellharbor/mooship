#!/bin/bash
set -euo pipefail

# ============================================================
# 07-native-postgres.sh — PostgreSQL on the host (--db-native)
# ============================================================
# Scenario:
#   Use PostgreSQL installed on the server itself instead of a database container.
#   The script creates a user and database through `sudo -u postgres psql`.
#
# Result:
#   - project /var/www/nativepg, site https://nativepg.example.com
#   - no db container; config.php: dbhost=172.17.0.1, dbport=5432
#   - generated database name, user, and password (or specify
#     --db-postgres-name / --db-postgres-user / --db-postgres-password)
#
# Before running (once, on the host):
#   - PostgreSQL is installed and running: systemctl status postgresql
#   - postgresql.conf: listen_addresses = 'localhost,172.17.0.1'
#   - pg_hba.conf:     host  all  all  172.16.0.0/12  scram-sha-256
#     (project containers use their own 172.18+.x.x network, not 172.17.0.0/16)
#   - systemctl restart postgresql
#   - if ufw is enabled: ufw allow from 172.16.0.0/12 to any port 5432 proto tcp
#   - existing databases and roles are rejected before the project is created
#
# Before running, replace:
#   - nativepg / nativepg.example.com → your slug and domain
#   - admin@example.com → your email
#   - if PostgreSQL is not listening on 5432 → add --port-postgres <port>
#
# Run on the server from the mooship directory (for example, /opt/mooship):
#   bash examples/07-native-postgres.sh
# DEPLOY_DIR is the directory containing deploy-moodle.sh; it defaults to the
# parent of examples/ (override: DEPLOY_DIR=/path bash …)
# ============================================================

DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

sudo bash "$DEPLOY_DIR/deploy-moodle.sh" \
  --slug nativepg \
  --domain nativepg.example.com \
  --db-type postgres \
  --db-native \
  --ssl-email admin@example.com
