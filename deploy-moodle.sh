#!/bin/bash
set -euo pipefail
umask 077

# ============================================================
# deploy-moodle.sh — deploy Moodle in Docker
# ============================================================
# Usage:
#   sudo bash deploy-moodle.sh \
#     --slug lms \
#     --domain lms.example.com \
#     --moodle-version 4.5 \
#     --db-type postgres \
#     --ssl-email admin@example.com
#
# All passwords and database names are generated automatically unless explicitly provided.
#
# Required arguments:
#   --domain DOMAIN              Site domain (a random slug is prepended unless --slug is set)
#   --db-type postgres|mysql     Database type
#   --ssl-email EMAIL            Email for Let's Encrypt (not required with --no-ssl)
#
# Project:
#   --slug SLUG                  Project identifier (random by default)
#   --create-backup              Full project backup in /var/backups/mooship (tar.gz)
#   --endpoint URL               Send project data (JSON, PUT) to URL
#
# Moodle:
#   --moodle-version X.Y[.Z]     Moodle release (GitHub tag vX.Y.Z); X.Y selects the newest
#                                X.Y.Z release (default 4.5)
#   --php-version X.Y            PHP branch: 8.2, 8.3 or 8.4 (patched security baseline) (defaults according to Moodle version)
#   --moodle-admin-user USER     Administrator login (default admin)
#   --moodle-admin-password PASS Administrator password (generated if omitted)
#   --moodle-admin-email EMAIL   Administrator email (default <admin-user>@<domain>)
#   --moodle-site-fullname NAME  Full site name (default "Moodle Site - <slug>")
#   --moodle-site-shortname NAME Short site name (default <slug>)
#
# Database:
#   --db-native                  Use a database on the host instead of a container
#   --db-root-password PASS      Native MySQL root password (required with --db-native + mysql)
#   --db-mysql-name, --db-mysql-user, --db-mysql-password, --db-mysql-root-password
#   --db-postgres-name, --db-postgres-user, --db-postgres-password
#
# Ports (default: a random free port from the range):
#   --port-http      8100–8400      --port-php       9100–9600
#   --port-https     4100–4300      --port-redis     6500–6800
#   --port-mysql     3400–3600      --port-postgres  5500–5800
#   Native databases default to port 3306 / 5432.
#
# Outgoing mail (without SMTP, Moodle cannot deliver mail from the container):
#   --smtp-host HOST[:PORT]      SMTP server, for example smtp.example.com:587
#   --smtp-secure tls|ssl|none   Encryption (default: ssl for port 465, otherwise tls)
#   --smtp-user USER             SMTP username (omit for an unauthenticated relay)
#   --smtp-password PASS         SMTP password (stored only in Moodle's settings)
#   --noreply-email EMAIL        No-reply sender address (Moodle default: noreply@<domain>)
#
# Resources:
#   --profile auto|small|medium|large
#                                PHP-FPM workers and database memory per site (default auto:
#                                host RAM divided among Mooship projects; see README)
#
# Other options:
#   --redis-password PASS        Redis password (also used for Moodle sessions)
#   --db-host HOST              Native DB address reachable from PHP (default host.docker.internal)
#   --create-dhparam             Create dhparam.pem for SSL (takes several minutes)
#   --enable-basic-auth          Enable HTTP Basic Authentication
#   --auth-user USER             Basic Auth username (generated if omitted)
#   --auth-password PASS         Basic Auth password (generated if omitted)
#   --no-ssl                     Serve the site over HTTP without an SSL certificate
#   -h, --help                   Show this help
#
# The script must be next to the moodle/ and nginxproxy/ template directories.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WWW_DIR="/var/www"
PROXY_DIR="${WWW_DIR}/nginxproxy"
LOGROTATE_DIR="/etc/logrotate.d"
MEMINFO_FILE="/proc/meminfo"
APP_TYPE="moodle"
TEMPLATE_DIR="${SCRIPT_DIR}/${APP_TYPE}"
MOODLE_REPOSITORY="https://github.com/moodle/moodle"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

# ======================== Colors =============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }

# Print this file's header as help
usage() {
    awk 'NR < 5 { next } !/^#/ { exit } /^# =+$/ { next } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

# ==================== Generate random credentials ====================
# random_string <character set for tr> <length>
random_string() {
    local CHARSET=$1
    local LENGTH=$2
    local RESULT=""
    # head closes the pipe before tr (SIGPIPE); pipefail makes this a failure, hence || true
    RESULT=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$CHARSET" | head -c "$LENGTH") || true
    echo "$RESULT"
}

# generate_random_name - generate a name (15 characters)
# Always start with a letter for SQL compatibility
generate_random_name() {
    echo "$(random_string 'a-z' 1)$(random_string 'a-z0-9' 14)"
}

# generate_random_password - generate a strong password (15 characters)
# Exclude characters that break sed (&, |, /, \), .env, and docker compose ($, #, =, quotes)
generate_random_password() {
    random_string 'A-Za-z0-9@%_+-' 15
}

# generate_random_slug - generate a random slug (8 characters)
generate_random_slug() {
    random_string 'a-z0-9' 8
}

# Escape a string for the right-hand side of a sed replacement (s|...|HERE|)
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# ==================== Find a free port ====================
# find_free_port <min> <max> <description>
# Select a random free port in the range [min, max]
find_free_port() {
    local MIN=$1
    local MAX=$2
    local DESC=$3
    local RANGE=$((MAX - MIN + 1))
    local ATTEMPTS=0
    local MAX_ATTEMPTS=100

    while [[ $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
        local PORT=$(( RANDOM % RANGE + MIN ))
        # Exclude selected ports, occupied TCP sockets, and Docker publications.
        if [[ "$PORT" != 80 && "$PORT" != 443 ]] && mooship_port_available "$PORT"; then
            echo "$PORT"
            return 0
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
    done

    error "Could not find a free port for ${DESC} in the range ${MIN}-${MAX}"
}

# ==================== Install missing packages ====================
ensure_packages() {
    local MISSING=()
    local PKG
    for PKG in "$@"; do
        command -v "$PKG" &>/dev/null || MISSING+=("$PKG")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        warn "Not installed: ${MISSING[*]}. Installing..."
        apt-get update -qq && apt-get install -y -qq "${MISSING[@]}"
    fi
}

# ==================== Root check =================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)."
    fi
}

# ==================== Check/create /var/www ====
ensure_www_dir() {
    if [[ ! -d "$WWW_DIR" ]]; then
        info "Directory ${WWW_DIR} does not exist, creating..."
        mkdir -p "$WWW_DIR" || error "Could not create directory ${WWW_DIR}"
        info "Directory ${WWW_DIR} created successfully"
    else
        info "Directory ${WWW_DIR} already exists"
    fi
}

# ==================== Install Docker ======================
install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker is already installed: $(docker --version)"
        return
    fi

    info "Installing Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    info "Docker installed: $(docker --version)"
}

# ==================== Initialize nginxproxy ===============
init_nginxproxy() {
    if [[ -d "${PROXY_DIR}" ]]; then
        info "Directory ${PROXY_DIR} already exists, skipping initialization."
        return
    fi

    info "Creating ${PROXY_DIR} from the template..."
    mkdir -p "${PROXY_DIR}/sites"
    cp "${SCRIPT_DIR}/nginxproxy/nginx.Dockerfile"   "${PROXY_DIR}/nginx.Dockerfile"
    cp "${SCRIPT_DIR}/nginxproxy/nginx.conf"         "${PROXY_DIR}/nginx.conf"
    cp "${SCRIPT_DIR}/nginxproxy/site-template.conf" "${PROXY_DIR}/site-template.conf"

    # Base proxy docker-compose.yml: networks/volumes are added for each site
    cat > "${PROXY_DIR}/docker-compose.yml" <<'DCEOF'
# cd /var/www/nginxproxy && docker compose up -d && docker restart nginxproxy
x-common-networks: &common-networks
  networks: []
services:
  nginxproxy:
    container_name: nginxproxy
    restart: always
    # Bound the proxy's stdout/stderr logs, which receive the access and error logs of all sites
    logging: {driver: json-file, options: {max-size: "10m", max-file: "3"}}
    build:
      context: .
      dockerfile: nginx.Dockerfile
    # Reload the configuration every 6 hours to pick up renewed site certificates
    command: /bin/sh -c 'while :; do sleep 21600 & wait $${!}; nginx -s reload; done & exec nginx -g "daemon off;"'
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./sites:/etc/nginx/sites:ro
    <<: *common-networks
networks:
volumes:
DCEOF

    info "nginxproxy initialized in ${PROXY_DIR}"
}

# ==================== Rotate project nginx logs ====================
# Project nginx writes its logs to the host (nginxproxy/logs/<slug>) through a bind mount,
# where Docker's log limits do not apply. copytruncate avoids signalling each container.
ensure_logrotate() {
    local CONFIG="${LOGROTATE_DIR}/mooship"

    if [[ ! -d "$LOGROTATE_DIR" ]]; then
        warn "logrotate is not installed; rotate ${PROXY_DIR}/logs/*/*.log manually"
        return 0
    fi
    if [[ -e "$CONFIG" ]]; then
        info "logrotate configuration already exists: ${CONFIG}"
        return 0
    fi

    info "Creating logrotate configuration ${CONFIG}..."
    cat > "$CONFIG" <<EOF
# Managed by Mooship: project nginx logs written through bind mounts.
${PROXY_DIR}/logs/*/*.log {
    daily
    rotate 14
    maxsize 100M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
EOF
    chmod 644 "$CONFIG"
}

# ==================== Create dhparam.pem ===================
create_dhparam() {
    local DHPARAM_FILE="${PROXY_DIR}/dhparam.pem"

    if [[ "$CREATE_DHPARAM" != true ]]; then
        return
    fi

    if [[ -f "$DHPARAM_FILE" ]]; then
        info "File dhparam.pem already exists: ${DHPARAM_FILE}"
        return
    fi

    info "Creating dhparam.pem (this will take several minutes)..."
    docker run --rm -v "${PROXY_DIR}:/output" alpine/openssl dhparam -out /output/dhparam.pem 2048

    if [[ -f "$DHPARAM_FILE" ]]; then
        info "dhparam.pem created successfully: ${DHPARAM_FILE}"
    else
        error "Could not create dhparam.pem"
    fi
}

# ==================== Parse arguments ====================
SLUG=""
DOMAIN=""
# A MAJOR.MINOR branch is resolved to its newest release by resolve_moodle_version
MOODLE_VERSION="4.5"
PHP_VERSION=""
PORT_HTTP=""
PORT_HTTPS=""
PORT_PHP=""
PORT_REDIS=""
REDIS_PASSWORD=""
DB_TYPE=""
PORT_MYSQL=""
PORT_POSTGRES=""
DB_MYSQL_NAME=""
DB_MYSQL_USER=""
DB_MYSQL_PASSWORD=""
DB_MYSQL_ROOT_PASSWORD=""
DB_POSTGRES_NAME=""
DB_POSTGRES_USER=""
DB_POSTGRES_PASSWORD=""
DB_NATIVE=false
NATIVE_DB_HOST=""
DB_ROOT_PASSWORD=""
CREATE_DHPARAM=false
ENABLE_BASIC_AUTH=false
AUTH_USER=""
AUTH_PASSWORD=""
OBTAIN_SSL=true
SSL_EMAIL=""
ENDPOINT=""
MOODLE_ADMIN_USER=""
MOODLE_ADMIN_PASSWORD=""
MOODLE_ADMIN_EMAIL=""
MOODLE_SITE_FULLNAME=""
MOODLE_SITE_SHORTNAME=""
SMTP_HOST=""
SMTP_SECURE=""
SMTP_USER=""
SMTP_PASSWORD=""
NOREPLY_EMAIL=""
PROFILE="auto"
PHP_FPM_MAX_CHILDREN=""
PHP_FPM_START_SERVERS=""
PHP_FPM_MIN_SPARE_SERVERS=""
PHP_FPM_MAX_SPARE_SERVERS=""
PG_SHARED_BUFFERS=""
PG_EFFECTIVE_CACHE_SIZE=""
PG_WORK_MEM=""
PG_MAINTENANCE_WORK_MEM=""
DB_SHM_SIZE=""
MYSQL_INNODB_BUFFER_POOL_SIZE=""
CREATE_BACKUP=false
BACKUP_FILE_PATH=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --slug)                   SLUG="$2";                   shift 2 ;;
            --domain)                 DOMAIN="$2";                 shift 2 ;;
            --type)
                # Compatibility with calls to the old deploy.sh
                [[ "$2" == "$APP_TYPE" ]] || error "This script deploys Moodle only. For '$2', use deploy-$2.sh"
                shift 2 ;;
            --moodle-version)         MOODLE_VERSION="$2";         shift 2 ;;
            --php-version)            PHP_VERSION="$2";            shift 2 ;;
            --moodle-admin-user)      MOODLE_ADMIN_USER="$2";      shift 2 ;;
            --moodle-admin-password)  MOODLE_ADMIN_PASSWORD="$2";  shift 2 ;;
            --moodle-site-fullname)   MOODLE_SITE_FULLNAME="$2";   shift 2 ;;
            --moodle-site-shortname)  MOODLE_SITE_SHORTNAME="$2";  shift 2 ;;
            --moodle-admin-email)     MOODLE_ADMIN_EMAIL="$2";     shift 2 ;;
            --smtp-host)              SMTP_HOST="$2";              shift 2 ;;
            --smtp-secure)            SMTP_SECURE="$2";            shift 2 ;;
            --smtp-user)              SMTP_USER="$2";              shift 2 ;;
            --smtp-password)          SMTP_PASSWORD="$2";          shift 2 ;;
            --noreply-email)          NOREPLY_EMAIL="$2";          shift 2 ;;
            --profile)                PROFILE="$2";                shift 2 ;;
            --create-backup)          CREATE_BACKUP=true;          shift 1 ;;
            --port-http)              PORT_HTTP="$2";              shift 2 ;;
            --port-https)             PORT_HTTPS="$2";             shift 2 ;;
            --port-php)               PORT_PHP="$2";               shift 2 ;;
            --port-redis)             PORT_REDIS="$2";             shift 2 ;;
            --port-postgres)          PORT_POSTGRES="$2";          shift 2 ;;
            --port-mysql)             PORT_MYSQL="$2";             shift 2 ;;
            --redis-password)         REDIS_PASSWORD="$2";         shift 2 ;;
            --db-type)                DB_TYPE="$2";                shift 2 ;;
            --db-mysql-name)          DB_MYSQL_NAME="$2";          shift 2 ;;
            --db-mysql-user)          DB_MYSQL_USER="$2";          shift 2 ;;
            --db-mysql-password)      DB_MYSQL_PASSWORD="$2";      shift 2 ;;
            --db-mysql-root-password) DB_MYSQL_ROOT_PASSWORD="$2"; shift 2 ;;
            --db-postgres-name)       DB_POSTGRES_NAME="$2";       shift 2 ;;
            --db-postgres-user)       DB_POSTGRES_USER="$2";       shift 2 ;;
            --db-postgres-password)   DB_POSTGRES_PASSWORD="$2";   shift 2 ;;
            --db-native)              DB_NATIVE=true;              shift 1 ;;
            --db-host)                NATIVE_DB_HOST="$2";          shift 2 ;;
            --db-root-password)       DB_ROOT_PASSWORD="$2";       shift 2 ;;
            --create-dhparam)         CREATE_DHPARAM=true;         shift 1 ;;
            --enable-basic-auth)      ENABLE_BASIC_AUTH=true;      shift 1 ;;
            --auth-user)              AUTH_USER="$2";              shift 2 ;;
            --auth-password)          AUTH_PASSWORD="$2";          shift 2 ;;
            --obtain-ssl)             OBTAIN_SSL=true;             shift 1 ;;
            --no-ssl)                 OBTAIN_SSL=false;            shift 1 ;;
            --ssl-email)              SSL_EMAIL="$2";              shift 2 ;;
            --endpoint)               ENDPOINT="$2";               shift 2 ;;
            *) error "Unknown argument: $1 (see --help)" ;;
        esac
    done

    [[ -z "$DOMAIN" ]]  && error "--domain is required"
    [[ -z "$DB_TYPE" ]] && error "--db-type is required"
    if [[ -n "$NATIVE_DB_HOST" ]]; then
        [[ "$DB_NATIVE" == true ]] || error "--db-host requires --db-native"
        mooship_validate_db_host "$NATIVE_DB_HOST"
    fi

    if [[ "$DB_TYPE" != "postgres" && "$DB_TYPE" != "mysql" ]]; then
        error "Database type must be 'postgres' or 'mysql', received: ${DB_TYPE}"
    fi

    # --- Check the root password for native MySQL ---
    if [[ "$DB_NATIVE" == true && "$DB_TYPE" == "mysql" && -z "$DB_ROOT_PASSWORD" ]]; then
        error "A native MySQL database requires --db-root-password"
    fi

    if [[ "$OBTAIN_SSL" == true && -z "$SSL_EMAIL" ]]; then
        error "Obtaining an SSL certificate requires --ssl-email"
    fi

    # --- Generate a slug if omitted ---
    if [[ -z "$SLUG" ]]; then
        SLUG=$(generate_random_slug)
        DOMAIN="${SLUG}.${DOMAIN}"
        info "Generated slug: ${SLUG}"
        info "Updated domain: ${DOMAIN}"
    fi

    mooship_validate_slug "$SLUG"
    if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
        error "Invalid domain: ${DOMAIN}"
    fi

    # --- Validate the Moodle version (MAJOR.MINOR is needed to select PHP) ---
    if ! [[ "$MOODLE_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        error "Invalid Moodle version format: ${MOODLE_VERSION}. Expected X.Y or X.Y.Z (for example: 4.5 or 4.5.15)"
    fi

    mooship_runtime_selection "$MOODLE_VERSION" "$PHP_VERSION" >/dev/null || error "Prohibited Moodle/PHP version"

    # --- Generate a Redis password if omitted ---
    if [[ -z "$REDIS_PASSWORD" ]]; then
        REDIS_PASSWORD=$(generate_random_password)
        info "Generated Redis password (will be saved in .env)"
    fi

    # --- Generate MySQL credentials if omitted ---
    if [[ "$DB_TYPE" == "mysql" ]]; then
        if [[ -z "$DB_MYSQL_NAME" ]]; then
            DB_MYSQL_NAME=$(generate_random_name)
            info "Generated MySQL database name: ${DB_MYSQL_NAME}"
        fi
        if [[ -z "$DB_MYSQL_USER" ]]; then
            DB_MYSQL_USER=$(generate_random_name)
            info "Generated MySQL username: ${DB_MYSQL_USER}"
        fi
        if [[ -z "$DB_MYSQL_PASSWORD" ]]; then
            DB_MYSQL_PASSWORD=$(generate_random_password)
            info "Generated MySQL password (will be saved in .env)"
        fi
        if [[ -z "$DB_MYSQL_ROOT_PASSWORD" ]]; then
            DB_MYSQL_ROOT_PASSWORD=$(generate_random_password)
            info "Generated MySQL root password (will be saved in .env)"
        fi
    fi

    # --- Generate PostgreSQL credentials if omitted ---
    if [[ "$DB_TYPE" == "postgres" ]]; then
        if [[ -z "$DB_POSTGRES_NAME" ]]; then
            DB_POSTGRES_NAME=$(generate_random_name)
            info "Generated PostgreSQL database name: ${DB_POSTGRES_NAME}"
        fi
        if [[ -z "$DB_POSTGRES_USER" ]]; then
            DB_POSTGRES_USER=$(generate_random_name)
            info "Generated PostgreSQL username: ${DB_POSTGRES_USER}"
        fi
        if [[ -z "$DB_POSTGRES_PASSWORD" ]]; then
            DB_POSTGRES_PASSWORD=$(generate_random_password)
            info "Generated PostgreSQL password (will be saved in .env)"
        fi
    fi

    # --- Generate Basic Auth credentials if omitted ---
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        if [[ -z "$AUTH_USER" ]]; then
            AUTH_USER=$(generate_random_name)
            info "Generated Basic Auth username: ${AUTH_USER}"
        fi
        if [[ -z "$AUTH_PASSWORD" ]]; then
            AUTH_PASSWORD=$(generate_random_password)
            info "Generated Basic Auth password (will be saved in .env)"
        fi
    fi

    mooship_validate_database_settings
    # The Redis password is written into config.php for Moodle sessions
    [[ "$REDIS_PASSWORD" =~ ^[A-Za-z0-9@%_+-]+$ ]] ||
        error "The Redis password contains unsupported characters (allowed: A-Za-z0-9@%_+-)"
    validate_mail_settings
    case "$PROFILE" in
        auto|small|medium|large) ;;
        *) error "--profile must be auto, small, medium, or large, received: ${PROFILE}" ;;
    esac
    if [[ -n "$ENDPOINT" && "$ENDPOINT" != https://* ]]; then
        error "An endpoint receiving credentials must use HTTPS"
    fi
    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        error "Template directory not found: ${TEMPLATE_DIR}"
    fi
}

# ==================== Validate mail settings ====================
validate_email() {
    [[ "$2" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || error "$1 must be an email address: $2"
}

validate_mail_settings() {
    [[ -z "$MOODLE_ADMIN_EMAIL" ]] || validate_email --moodle-admin-email "$MOODLE_ADMIN_EMAIL"
    [[ -z "$NOREPLY_EMAIL" ]] || validate_email --noreply-email "$NOREPLY_EMAIL"
    if [[ -z "$SMTP_HOST" ]]; then
        [[ -z "${SMTP_USER}${SMTP_PASSWORD}${SMTP_SECURE}" ]] ||
            error "--smtp-user, --smtp-password, and --smtp-secure require --smtp-host"
        return 0
    fi
    [[ "$SMTP_HOST" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] ||
        error "Invalid --smtp-host: ${SMTP_HOST} (expected HOST or HOST:PORT)"
    if [[ -z "$SMTP_SECURE" ]]; then
        # Port 465 uses implicit TLS; submission ports (587, 25) use STARTTLS
        if [[ "$SMTP_HOST" == *:465 ]]; then SMTP_SECURE=ssl; else SMTP_SECURE=tls; fi
    fi
    case "$SMTP_SECURE" in
        tls|ssl|none) ;;
        *) error "--smtp-secure must be tls, ssl, or none, received: ${SMTP_SECURE}" ;;
    esac
    if [[ -n "$SMTP_USER" ]]; then
        [[ "$SMTP_USER" =~ ^[A-Za-z0-9._%+@=-]+$ ]] || error "The SMTP username contains unsupported characters"
    fi
    [[ -z "$SMTP_PASSWORD" || -n "$SMTP_USER" ]] || error "--smtp-password requires --smtp-user"
    [[ "$SMTP_PASSWORD" != *$'\n'* ]] || error "The SMTP password must not contain line breaks"
}

# ==================== Resource profile ====================
# Mooship projects on this host (directories with docker-compose.yml), plus the new one
count_projects() {
    local COUNT=1 DIR
    for DIR in "$WWW_DIR"/*/; do
        if [[ -f "${DIR}docker-compose.yml" && "$(basename "$DIR")" != nginxproxy ]]; then
            COUNT=$((COUNT + 1))
        fi
    done
    echo "$COUNT"
}

# Size PHP-FPM and the database for the memory one site can expect:
# small ~2 GB, medium ~4 GB, large 8 GB or more. auto divides host RAM among projects.
select_resource_profile() {
    if [[ "$PROFILE" == auto ]]; then
        local MEMORY_MIB PROJECTS SHARE
        MEMORY_MIB=$(awk '/^MemTotal:/ { print int($2 / 1024) }' "$MEMINFO_FILE" 2>/dev/null || true)
        if [[ ! "$MEMORY_MIB" =~ ^[0-9]+$ ]]; then
            warn "Could not read host memory from ${MEMINFO_FILE}; using the small profile"
            PROFILE=small
        else
            PROJECTS=$(count_projects)
            SHARE=$((MEMORY_MIB / PROJECTS))
            if ((SHARE < 3072)); then PROFILE=small
            elif ((SHARE < 6144)); then PROFILE=medium
            else PROFILE=large; fi
            info "Resource profile: ${PROFILE} (${MEMORY_MIB} MiB RAM shared by ${PROJECTS} project(s))"
        fi
    else
        info "Resource profile: ${PROFILE}"
    fi

    case "$PROFILE" in
        small)
            PHP_FPM_MAX_CHILDREN=8
            PG_SHARED_BUFFERS=256MB; PG_EFFECTIVE_CACHE_SIZE=768MB
            PG_WORK_MEM=8MB; PG_MAINTENANCE_WORK_MEM=64MB; DB_SHM_SIZE=256mb
            MYSQL_INNODB_BUFFER_POOL_SIZE=256M ;;
        medium)
            PHP_FPM_MAX_CHILDREN=16
            PG_SHARED_BUFFERS=512MB; PG_EFFECTIVE_CACHE_SIZE=1536MB
            PG_WORK_MEM=16MB; PG_MAINTENANCE_WORK_MEM=128MB; DB_SHM_SIZE=512mb
            MYSQL_INNODB_BUFFER_POOL_SIZE=768M ;;
        large)
            PHP_FPM_MAX_CHILDREN=32
            PG_SHARED_BUFFERS=1GB; PG_EFFECTIVE_CACHE_SIZE=4GB
            PG_WORK_MEM=32MB; PG_MAINTENANCE_WORK_MEM=256MB; DB_SHM_SIZE=1gb
            MYSQL_INNODB_BUFFER_POOL_SIZE=2G ;;
    esac
    PHP_FPM_START_SERVERS=$((PHP_FPM_MAX_CHILDREN / 4))
    PHP_FPM_MIN_SPARE_SERVERS=$((PHP_FPM_MAX_CHILDREN / 8))
    PHP_FPM_MAX_SPARE_SERVERS=$((PHP_FPM_MAX_CHILDREN / 2))
}

# ==================== Assign ports ====================
# Keep manually specified ports; select the remaining ports from their ranges
assign_ports() {
    info "Selecting free ports..."
    local variable port db_variable
    local -a variables=(PORT_HTTP PORT_HTTPS PORT_PHP PORT_REDIS)
    if [[ "$DB_TYPE" == mysql ]]; then db_variable=PORT_MYSQL; else db_variable=PORT_POSTGRES; fi
    variables+=("$db_variable")
    if [[ "$DB_NATIVE" == true && -z "${!db_variable}" ]]; then
        if [[ "$DB_TYPE" == mysql ]]; then PORT_MYSQL=3306; else PORT_POSTGRES=5432; fi
    fi
    # Validate every explicit input before probing or creating anything, even unused DB flags.
    for variable in PORT_HTTP PORT_HTTPS PORT_PHP PORT_REDIS PORT_MYSQL PORT_POSTGRES; do
        port="${!variable}"
        [[ -n "$port" ]] || continue
        mooship_validate_port "$port"
        printf -v "$variable" '%s' "$((10#$port))"
    done
    MOOSHIP_ASSIGNED_PORTS=""
    MOOSHIP_DOCKER_PORTS=$(docker ps --format '{{.Ports}}' 2>/dev/null || true)
    for variable in "${variables[@]}"; do
        port="${!variable}"
        [[ -n "$port" ]] || continue
        [[ "$port" != 80 && "$port" != 443 ]] || error "Port $port is reserved for the shared proxy"
        [[ " $MOOSHIP_ASSIGNED_PORTS " != *" $port "* ]] || error "Duplicate service port: $port"
        if [[ "$DB_NATIVE" != true || "$variable" != "$db_variable" ]]; then
            mooship_port_available "$port" || error "Port $port is already in use"
        fi
        MOOSHIP_ASSIGNED_PORTS+=" $port"
    done

    if [[ -z "$PORT_HTTP" ]]; then
        PORT_HTTP=$(find_free_port 8100 8400 "HTTP")
        MOOSHIP_ASSIGNED_PORTS+=" $PORT_HTTP"
    fi
    info "  HTTP:       ${PORT_HTTP}"

    if [[ -z "$PORT_HTTPS" ]]; then
        PORT_HTTPS=$(find_free_port 4100 4300 "HTTPS")
        MOOSHIP_ASSIGNED_PORTS+=" $PORT_HTTPS"
    fi
    info "  HTTPS:      ${PORT_HTTPS}"

    if [[ -z "$PORT_PHP" ]]; then
        PORT_PHP=$(find_free_port 9100 9600 "PHP-FPM")
        MOOSHIP_ASSIGNED_PORTS+=" $PORT_PHP"
    fi
    info "  PHP-FPM:    ${PORT_PHP}"

    if [[ -z "$PORT_REDIS" ]]; then
        PORT_REDIS=$(find_free_port 6500 6800 "Redis")
        MOOSHIP_ASSIGNED_PORTS+=" $PORT_REDIS"
    fi
    info "  Redis:      ${PORT_REDIS}"

    if [[ "$DB_TYPE" == "mysql" ]]; then
        if [[ "$DB_NATIVE" == true ]]; then
            PORT_MYSQL="${PORT_MYSQL:-3306}"
            info "  MySQL:      ${PORT_MYSQL} (native database)"
        else
            if [[ -z "$PORT_MYSQL" ]]; then
                PORT_MYSQL=$(find_free_port 3400 3600 "MySQL")
            fi
            info "  MySQL:      ${PORT_MYSQL}"
        fi
    else
        if [[ "$DB_NATIVE" == true ]]; then
            PORT_POSTGRES="${PORT_POSTGRES:-5432}"
            info "  PostgreSQL: ${PORT_POSTGRES} (native database)"
        else
            if [[ -z "$PORT_POSTGRES" ]]; then
                PORT_POSTGRES=$(find_free_port 5500 5800 "PostgreSQL")
            fi
            info "  PostgreSQL: ${PORT_POSTGRES}"
        fi
    fi
}

# ==================== Resolve the Moodle release ==============
# MAJOR.MINOR selects the newest stable release tag of that branch (vX.Y.Z, no beta/rc);
# an explicit X.Y.Z is used as-is.
resolve_moodle_version() {
    if ! [[ "$MOODLE_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
        info "Moodle version ${MOODLE_VERSION} will be installed"
        return 0
    fi

    ensure_packages git
    info "Looking up the latest Moodle ${MOODLE_VERSION} release..."
    local TAGS LATEST
    TAGS=$(git ls-remote --tags --refs "$MOODLE_REPOSITORY" "refs/tags/v${MOODLE_VERSION}.*") ||
        error "Could not list Moodle release tags from ${MOODLE_REPOSITORY}"
    LATEST=$(awk -v prefix="refs/tags/v${MOODLE_VERSION}." '
        index($2, prefix) == 1 && substr($2, length(prefix) + 1) ~ /^[0-9]+$/ {
            print substr($2, length("refs/tags/v") + 1)
        }' <<< "$TAGS" | sort -V | tail -n 1)
    [[ -n "$LATEST" ]] || error "No stable Moodle ${MOODLE_VERSION}.x release found in ${MOODLE_REPOSITORY}"

    MOODLE_VERSION="$LATEST"
    info "Moodle version ${MOODLE_VERSION} (latest ${MOODLE_VERSION%.*} release) will be installed"
}

# ==================== Select the PHP version for Moodle ==============
select_php_version_for_moodle() {
    PHP_VERSION=$(mooship_runtime_selection "$MOODLE_VERSION" "$PHP_VERSION") ||
        error "The requested Moodle/PHP combination violates the runtime security policy"
    [[ -f "${TEMPLATE_DIR}/.docker/php/php${PHP_VERSION}.Dockerfile" ]] || error "Missing patched PHP Dockerfile"
    [[ -f "${TEMPLATE_DIR}/.config/php/php${PHP_VERSION}.ini" ]] || error "Missing PHP configuration"
    success "Selected patched PHP $(php_version_label) for Moodle ${MOODLE_VERSION}"
}

# 84 → 8.4 (for display)
php_version_label() {
    echo "${PHP_VERSION:0:1}.${PHP_VERSION:1}"
}

# ==================== Configure the database in docker-compose.yml ======
# Remove the unused database container (and the selected one for a native database),
# its volumes and dependencies, and rename the selected database to db / <slug>_db
configure_compose_db() {
    local COMPOSE_FILE="$1"

    if [[ "$DB_NATIVE" == true ]]; then
        info "Removing database containers from docker-compose.yml (using a native database)..."
    else
        info "Configuring docker-compose.yml for database type ${DB_TYPE}..."
    fi

    python3 - "$COMPOSE_FILE" "$SLUG" "$DB_TYPE" "$DB_NATIVE" "${NATIVE_DB_HOST:-host.docker.internal}" <<'PYEOF'
import re
import sys

path, slug, db_type, native = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == 'true'
native_host = sys.argv[5]
other = 'mysql' if db_type == 'postgres' else 'postgres'

drop_services = {f'db_{other}'}
drop_volumes = {f'{slug}_db_{other}'}
if native:
    drop_services.add(f'db_{db_type}')
    drop_volumes.add(f'{slug}_db_{db_type}')

with open(path) as f:
    lines = f.read().splitlines()

# --- 1. Remove service and volume blocks ---
result = []
section = None
skipping = False
for line in lines:
    top = re.match(r'^([A-Za-z][\w-]*):', line)
    if top:
        section = top.group(1)
        skipping = False
        result.append(line)
        continue

    key = re.match(r'''^  (["']?)([\w.-]+)\1:\s*$''', line)
    if key:
        name = key.group(2)
        skipping = (section == 'services' and name in drop_services) or \
                   (section == 'volumes' and name in drop_volumes)
        if not skipping:
            result.append(line)
        continue

    if skipping:
        # Within a removed block: blank lines and anything indented more than 2 spaces
        if line.strip() == '' or len(line) - len(line.lstrip()) > 2:
            continue
        skipping = False

    result.append(line)

# --- 2. Native database: remove dependencies on the database container ---
if native:
    db_names = {'db', 'db_postgres', 'db_mysql'}
    cleaned = []
    i = 0
    while i < len(result):
        line = result[i]
        if line.strip() == 'depends_on:':
            indent = len(line) - len(line.lstrip())
            items = []
            i += 1
            while i < len(result) and re.match(r'^\s+-\s+', result[i]) \
                    and len(result[i]) - len(result[i].lstrip()) > indent:
                if result[i].strip()[1:].strip() not in db_names:
                    items.append(result[i])
                i += 1
            if items:
                cleaned.append(line)
                cleaned.extend(items)
            continue
        cleaned.append(line)
        i += 1
    result = cleaned

# --- 3. Rename the selected database: db_postgres → db, <slug>_db_postgres → <slug>_db ---
result = [re.sub(rf'\bdb_{db_type}\b', 'db', l.replace(f'{slug}_db_{db_type}', f'{slug}_db'))
          for l in result]
if native and native_host == 'host.docker.internal':
    mapped = []
    for line in result:
        mapped.append(line)
        if re.match(r'^  (php|cron):\s*$', line):
            mapped.extend(['    extra_hosts:', '      - "host.docker.internal:host-gateway"'])
    result = mapped

with open(path, 'w') as f:
    f.write('\n'.join(result) + '\n')
PYEOF
}

# ==================== Generate the project .env ======================
site_scheme() {
    if [[ "$OBTAIN_SSL" == false ]]; then printf 'http'; else printf 'https'; fi
}

enable_http_site() {
    python3 "$SCRIPT_DIR/lib/web.py" "$PROJECT_DIR/.config/nginx/_site.conf"
}

write_project_env() {
    local ENV_FILE="${PROJECT_DIR}/.env"

    info "Generating .env for ${SLUG}..."
    {
        echo "SITE_HOST=${DOMAIN}"
        echo "SITE_SCHEME=$(site_scheme)"
        echo "SITE_PORT_HTTP=${PORT_HTTP}"
        echo "SITE_PORT_HTTPS=${PORT_HTTPS}"
        echo ""
        echo "PHP_PORT=${PORT_PHP}"
        echo ""
        echo "REDIS_PORT=${PORT_REDIS}"
        echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
        echo ""
        if [[ "$DB_TYPE" == "postgres" ]]; then
            echo "DB_PORT=${PORT_POSTGRES}"
            echo "DB_POSTGRES_NAME=${DB_POSTGRES_NAME}"
            echo "DB_POSTGRES_USER=${DB_POSTGRES_USER}"
            echo "DB_POSTGRES_PASSWORD=${DB_POSTGRES_PASSWORD}"
        else
            echo "DB_PORT=${PORT_MYSQL}"
            echo "DB_MYSQL_NAME=${DB_MYSQL_NAME}"
            echo "DB_MYSQL_USER=${DB_MYSQL_USER}"
            echo "DB_MYSQL_PASSWORD=${DB_MYSQL_PASSWORD}"
            echo "DB_MYSQL_PASSWORD_ROOT=${DB_MYSQL_ROOT_PASSWORD}"
        fi
        echo ""
        echo "DB_NATIVE=${DB_NATIVE}"
        if [[ "$DB_NATIVE" == true ]]; then
            echo "DB_HOST=${NATIVE_DB_HOST:-host.docker.internal}"
        fi
        echo "PHP_VERSION=${PHP_VERSION}"
        echo "MOODLE_VERSION=${MOODLE_VERSION}"
        echo ""
        echo "# Resource profile: edit the values below, then run docker compose up -d"
        echo "MOOSHIP_PROFILE=${PROFILE}"
        echo "PHP_FPM_MAX_CHILDREN=${PHP_FPM_MAX_CHILDREN}"
        echo "PHP_FPM_START_SERVERS=${PHP_FPM_START_SERVERS}"
        echo "PHP_FPM_MIN_SPARE_SERVERS=${PHP_FPM_MIN_SPARE_SERVERS}"
        echo "PHP_FPM_MAX_SPARE_SERVERS=${PHP_FPM_MAX_SPARE_SERVERS}"
        if [[ "$DB_NATIVE" != true && "$DB_TYPE" == "postgres" ]]; then
            echo "PG_SHARED_BUFFERS=${PG_SHARED_BUFFERS}"
            echo "PG_EFFECTIVE_CACHE_SIZE=${PG_EFFECTIVE_CACHE_SIZE}"
            echo "PG_WORK_MEM=${PG_WORK_MEM}"
            echo "PG_MAINTENANCE_WORK_MEM=${PG_MAINTENANCE_WORK_MEM}"
            echo "DB_SHM_SIZE=${DB_SHM_SIZE}"
        elif [[ "$DB_NATIVE" != true ]]; then
            echo "MYSQL_INNODB_BUFFER_POOL_SIZE=${MYSQL_INNODB_BUFFER_POOL_SIZE}"
        fi
        if [[ -n "$SMTP_HOST" ]]; then
            echo ""
            echo "# Outgoing mail; the SMTP password is stored only in Moodle's settings"
            echo "SMTP_HOST=${SMTP_HOST}"
            echo "SMTP_SECURE=${SMTP_SECURE}"
            echo "SMTP_USER=${SMTP_USER}"
        fi
        if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
            echo ""
            echo "AUTH_USER=${AUTH_USER}"
            echo "AUTH_PASSWORD=${AUTH_PASSWORD}"
        fi
    } > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# ==================== Create the project ======================
create_project() {
    mooship_require_new_project
    PROJECT_DIR=$(mooship_project_path "$SLUG")

    info "Creating project ${SLUG} (${APP_TYPE}) in ${PROJECT_DIR}..."
    mkdir -p "${PROJECT_DIR}"

    # Copy all template contents
    cp -a "${TEMPLATE_DIR}/." "${PROJECT_DIR}/"

    # --- Organize Dockerfiles into subdirectories ---
    if [[ -d "${PROJECT_DIR}/.docker" ]]; then
        mkdir -p "${PROJECT_DIR}/.docker/php"
        mkdir -p "${PROJECT_DIR}/.docker/nginx"
        mkdir -p "${PROJECT_DIR}/.docker/init/postgres"

        if ls "${PROJECT_DIR}/.docker"/php*.Dockerfile 1> /dev/null 2>&1; then
            mv "${PROJECT_DIR}/.docker"/php*.Dockerfile "${PROJECT_DIR}/.docker/php/" 2>/dev/null || true
        fi
        if ls "${PROJECT_DIR}/.docker"/nginx*.Dockerfile 1> /dev/null 2>&1; then
            mv "${PROJECT_DIR}/.docker"/nginx*.Dockerfile "${PROJECT_DIR}/.docker/nginx/" 2>/dev/null || true
        fi
    fi

    # --- Replace {SLUG} → slug in docker-compose.yml ---
    sed -i "s/{SLUG}/${SLUG}/g" "${PROJECT_DIR}/docker-compose.yml"

    # --- Substitute the PHP version (Dockerfile and php.ini) in docker-compose.yml ---
    sed -i "s/\${PHP_VERSION}/${PHP_VERSION}/g" "${PROJECT_DIR}/docker-compose.yml"

    # --- Database container: selected type or native database ---
    configure_compose_db "${PROJECT_DIR}/docker-compose.yml"

    # --- Project .env ---
    write_project_env

    # --- Replace MYSITE.COM → domain in _site.conf ---
    if [[ -f "${PROJECT_DIR}/.config/nginx/_site.conf" ]]; then
        sed -i "s/MYSITE\.COM/${DOMAIN}/g" "${PROJECT_DIR}/.config/nginx/_site.conf"
        sed -i "s/{SLUG}/${SLUG}/g" "${PROJECT_DIR}/.config/nginx/_site.conf"
    fi

    # --- Uncomment dhparam.pem in docker-compose.yml and _site.conf ---
    if [[ "$CREATE_DHPARAM" == true ]]; then
        info "Uncommenting the dhparam.pem line in docker-compose.yml..."
        # The project is in /var/www/<slug> and the proxy in /var/www/nginxproxy, hence ../nginxproxy
        sed -i 's|^\s*#\s*-\s*\(\.\./\)\{1,2\}nginxproxy/dhparam\.pem:/etc/ssl/certs/dhparam\.pem.*|      - ../nginxproxy/dhparam.pem:/etc/ssl/certs/dhparam.pem:ro|' "${PROJECT_DIR}/docker-compose.yml"

        info "Uncommenting the ssl_dhparam line in _site.conf..."
        sed -i 's|^\s*#ssl_dhparam /etc/ssl/certs/dhparam\.pem;|        ssl_dhparam /etc/ssl/certs/dhparam.pem;|' "${PROJECT_DIR}/.config/nginx/_site.conf"
    fi

    # --- Create .htpasswd for Basic Auth ---
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        info "Creating the .htpasswd file for Basic Authentication..."
        mkdir -p "${PROJECT_DIR}/.config/nginx"
        printf '%s\n' "$AUTH_PASSWORD" | docker run --rm -i httpd:2.4-alpine htpasswd -ni "$AUTH_USER" > "${PROJECT_DIR}/.config/nginx/.htpasswd"
        chmod 644 "${PROJECT_DIR}/.config/nginx/.htpasswd"

        if [[ -s "${PROJECT_DIR}/.config/nginx/.htpasswd" ]]; then
            info ".htpasswd file created: ${PROJECT_DIR}/.config/nginx/.htpasswd"

            info "Uncommenting the .htpasswd line in docker-compose.yml..."
            sed -i 's|^\s*#\s*-\s*\./.config/nginx/\.htpasswd:/etc/nginx/\.htpasswd:ro|      - ./.config/nginx/.htpasswd:/etc/nginx/.htpasswd:ro|' "${PROJECT_DIR}/docker-compose.yml"

            info "Uncommenting Basic Auth lines in _site.conf..."
            sed -i 's|^#\s*auth_basic "Restricted Access";|            auth_basic "Restricted Access";|' "${PROJECT_DIR}/.config/nginx/_site.conf"
            sed -i 's|^#\s*auth_basic_user_file /etc/nginx/\.htpasswd;|            auth_basic_user_file /etc/nginx/.htpasswd;|' "${PROJECT_DIR}/.config/nginx/_site.conf"
        else
            error "Could not create the .htpasswd file"
        fi
    fi

    if [[ "$OBTAIN_SSL" == false ]]; then enable_http_site; fi
    info "Project ${SLUG} created in ${PROJECT_DIR}"
}

# ==================== Create the nginxproxy site config ======
update_proxy_nginx_conf() {
    local SITE_CONF="${PROXY_DIR}/sites/${SLUG}.conf"
    local TEMPLATE="${PROXY_DIR}/site-template.conf"

    mkdir -p "${PROXY_DIR}/sites"

    # Copy the template if missing
    if [[ ! -f "$TEMPLATE" ]]; then
        info "Copying site-template.conf to nginxproxy..."
        local SOURCE_TEMPLATE="${SCRIPT_DIR}/nginxproxy/site-template.conf"

        if [[ ! -f "$SOURCE_TEMPLATE" ]]; then
            error "Template not found: ${SOURCE_TEMPLATE}. SCRIPT_DIR=${SCRIPT_DIR}"
        fi

        cp "$SOURCE_TEMPLATE" "$TEMPLATE"
    fi
    # The proxy keeps its own copy of the template so local changes are never overwritten
    if ! cmp -s "$TEMPLATE" "${SCRIPT_DIR}/nginxproxy/site-template.conf"; then
        warn "${TEMPLATE} differs from the bundled template; the new site uses the local copy."
        warn "See README, \"Updating an existing server\", to adopt the current proxy template."
    fi

    # Check whether the sites directory is mounted in docker-compose.yml
    if ! grep -q "./sites:/etc/nginx/sites:ro" "${PROXY_DIR}/docker-compose.yml"; then
        info "Adding the sites directory mount to nginxproxy docker-compose.yml..."
        sed -i '/- \.\/nginx\.conf:\/etc\/nginx\/nginx\.conf:ro/a\      - ./sites:/etc/nginx/sites:ro' "${PROXY_DIR}/docker-compose.yml"
    fi

    if [[ -f "$SITE_CONF" ]]; then
        warn "Config ${SITE_CONF} already exists, skipping."
        return
    fi

    info "Creating config ${SLUG}.conf from the template..."
    sed -e "s/SLUG/${SLUG}/g" \
        -e "s/DOMAIN/${DOMAIN}/g" \
        "$TEMPLATE" > "$SITE_CONF"

    info "Config ${SLUG}.conf created in ${PROXY_DIR}/sites/"
}

# ==================== Update nginxproxy/docker-compose.yml
update_proxy_docker_compose() {
    local DC="${PROXY_DIR}/docker-compose.yml"

    # Check whether this slug already exists in the networks section
    if grep -q "^  ${SLUG}:$" "$DC"; then
        info "Network ${SLUG} already added to ${DC}"
        return
    fi

    info "Adding ${SLUG} to ${DC}..."

    python3 - "$DC" "$SLUG" <<'PYEOF'
import sys
import re

def in_service(lines, idx, name):
    """Line idx belongs to service name when the nearest preceding key with two-space indentation is name."""
    for j in range(idx - 1, -1, -1):
        m = re.match(r'^  ([\w.-]+):', lines[j])
        if m:
            return m.group(1) == name
        if re.match(r'^[^\s#]', lines[j]):
            return False
    return False

dc_path = sys.argv[1]
slug = sys.argv[2]

with open(dc_path) as f:
    content = f.read()

lines = content.splitlines()
result = []
i = 0

# Collect existing keys to check for duplicates
existing_networks = set()
existing_volumes = set()
existing_network_refs = set()
existing_volume_mounts = set()

for line in lines:
    # Networks in x-common-networks
    match = re.match(r'^\s+-\s+([\w-]+)$', line)
    if match:
        existing_network_refs.add(match.group(1))
    # Top-level networks
    match = re.match(r'^\s{2}([\w-]+):\s*$', line)
    if match:
        existing_networks.add(match.group(1))
    # Top-level volumes
    match = re.match(r'^\s{2}([\w-]+_ssl_certificates):\s*$', line)
    if match:
        existing_volumes.add(match.group(1))
    # Volume mounts in the service
    match = re.match(r'^\s+-\s+([\w-]+_ssl_certificates):/etc/letsencrypt/', line)
    if match:
        existing_volume_mounts.add(match.group(1))

while i < len(lines):
    line = lines[i]

    # --- x-common-networks: add the network to the list ---
    if line.strip().startswith("networks:") and i > 0 and "x-common-networks" in lines[i-1]:
        if line.strip() == "networks: []":
            # Replace inline syntax with multiple lines including the new network
            result.append("  networks:")
            if slug not in existing_network_refs:
                result.append(f"    - {slug}")
            i += 1
        else:
            result.append(line)
            i += 1
            while i < len(lines) and lines[i].strip().startswith("-"):
                result.append(lines[i])
                i += 1
            if slug not in existing_network_refs:
                result.append(f"    - {slug}")
        continue

    # --- volumes: add the SSL volume in the nginxproxy service ---
    if re.match(r'^\s+volumes:\s*$', line) and in_service(lines, i, "nginxproxy"):
        result.append(line)
        i += 1
        while i < len(lines) and lines[i].strip().startswith("-"):
            result.append(lines[i])
            i += 1
        volume_key = f"{slug}_ssl_certificates"
        if volume_key not in existing_volume_mounts:
            result.append(f"      - {volume_key}:/etc/letsencrypt/{slug}")
        continue

    # --- networks: at the top level ---
    if re.match(r'^networks:\s*(\{\})?$', line):
        result.append("networks:")
        i += 1
        while i < len(lines) and lines[i].startswith('  ') and not re.match(r'^[a-z]', lines[i]):
            result.append(lines[i])
            i += 1
        if slug not in existing_networks:
            result.append(f"  {slug}:")
            result.append(f"    name: {slug}")
            result.append(f"    external: true")
        continue

    # --- volumes: at the top level ---
    if re.match(r'^volumes:\s*(\{\})?$', line):
        result.append("volumes:")
        i += 1
        while i < len(lines) and lines[i].startswith('  ') and not re.match(r'^[a-z]', lines[i]):
            result.append(lines[i])
            i += 1
        volume_key = f"{slug}_ssl_certificates"
        if volume_key not in existing_volumes:
            result.append(f"  {volume_key}:")
            result.append(f"    name: {volume_key}")
            result.append(f"    external: true")
        continue

    result.append(line)
    i += 1

with open(dc_path, 'w') as f:
    f.write("\n".join(result) + "\n")
PYEOF

    info "${SLUG} added to the proxy docker-compose.yml"
}

# ==================== Comment/uncomment SSL blocks ==============
# toggle_ssl_blocks comment|uncomment
# Operates on the "listen 443" server block in the project's _site.conf and nginxproxy/sites/<slug>.conf
toggle_ssl_blocks() {
    local MODE="$1"
    local FILES=()
    local FILE

    for FILE in "${PROJECT_DIR}/.config/nginx/_site.conf" "${PROXY_DIR}/sites/${SLUG}.conf"; do
        [[ -f "$FILE" ]] && FILES+=("$FILE")
    done
    [[ ${#FILES[@]} -eq 0 ]] && return 0

    python3 - "$MODE" "${FILES[@]}" <<'PYEOF'
import sys
import re

mode, paths = sys.argv[1], sys.argv[2:]

for conf_path in paths:
    with open(conf_path) as f:
        lines = f.read().splitlines()

    result = []
    in_ssl_block = False
    brace_count = 0

    for idx, line in enumerate(lines):
        if not in_ssl_block:
            window = lines[idx:idx + 10]
            if mode == 'comment':
                starts = re.match(r'^\s*server\s*\{', line) and any('listen 443' in l for l in window)
            else:
                starts = re.match(r'^#\s*server\s*\{', line) and \
                    any(l.startswith('#') and 'listen 443' in l for l in window)
            if starts:
                in_ssl_block = True
                brace_count = 1
                result.append('#' + line if mode == 'comment' else line[1:])
            else:
                result.append(line)
            continue

        if mode == 'comment':
            body = line
            result.append('#' + line)
        else:
            body = line[1:] if line.startswith('#') else line
            result.append(body)

        brace_count += body.count('{') - body.count('}')
        if brace_count == 0:
            in_ssl_block = False

    with open(conf_path, 'w') as f:
        f.write('\n'.join(result) + '\n')
PYEOF

    for FILE in "${FILES[@]}"; do
        if [[ "$MODE" == "comment" ]]; then
            info "SSL block commented out in ${FILE}"
        else
            info "SSL block uncommented in ${FILE}"
        fi
    done
}

comment_ssl_blocks() {
    info "Commenting out SSL blocks until the certificate is obtained..."
    toggle_ssl_blocks comment
}

uncomment_ssl_blocks() {
    info "Uncommenting SSL blocks after obtaining the certificate..."
    toggle_ssl_blocks uncomment
}

# ==================== Create a native database ==============
create_native_database() {
    if [[ "$DB_NATIVE" != true ]]; then
        return
    fi

    info "Creating a native ${DB_TYPE} database..."
    if [[ "$DB_TYPE" == postgres ]]; then mooship_validate_port "$PORT_POSTGRES";
    else mooship_validate_port "$PORT_MYSQL"; fi
    mooship_require_new_native_database

    if [[ "$DB_TYPE" == "postgres" ]]; then
        if ! command -v psql &> /dev/null; then
            error "PostgreSQL is not installed on the server. Install PostgreSQL or use a container database (remove --db-native)"
        fi

        if ! sudo -u postgres psql --port="$PORT_POSTGRES" -v ON_ERROR_STOP=1 -c "SELECT 1;" &> /dev/null; then
            error "The PostgreSQL server is stopped or unavailable. Start PostgreSQL: sudo systemctl start postgresql"
        fi

        info "Creating PostgreSQL user: ${DB_POSTGRES_USER}"
        sudo -u postgres psql --port="$PORT_POSTGRES" -v ON_ERROR_STOP=1 <<< "CREATE USER \"${DB_POSTGRES_USER}\" WITH PASSWORD '${DB_POSTGRES_PASSWORD}';" 2>/dev/null || \
            error "Could not create the PostgreSQL user"

        info "Creating PostgreSQL database: ${DB_POSTGRES_NAME}"
        sudo -u postgres psql --port="$PORT_POSTGRES" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${DB_POSTGRES_NAME}\" OWNER \"${DB_POSTGRES_USER}\";" 2>/dev/null || \
            error "Could not create the PostgreSQL database"

        sudo -u postgres psql --port="$PORT_POSTGRES" -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_POSTGRES_NAME}\" TO \"${DB_POSTGRES_USER}\";"

        success "PostgreSQL database ${DB_POSTGRES_NAME} created"

    elif [[ "$DB_TYPE" == "mysql" ]]; then
        if ! command -v mysql &> /dev/null; then
            error "MySQL is not installed on the server. Install MySQL or use a container database (remove --db-native)"
        fi

        if ! MYSQL_PWD="$DB_ROOT_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port="$PORT_MYSQL" -u root -e "SELECT 1;" &> /dev/null; then
            error "The MySQL server is unavailable or the root password is incorrect. Check: 1) MySQL is running (sudo systemctl start mysql), 2) --db-root-password is correct"
        fi

        info "Creating MySQL database: ${DB_MYSQL_NAME}"
        MYSQL_PWD="$DB_ROOT_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port="$PORT_MYSQL" -u root -e "CREATE DATABASE \`${DB_MYSQL_NAME}\`;" || \
            error "Could not create the MySQL database. Check the root password."

        # The application connects from a container (through the Docker bridge), rather than localhost
        info "Creating MySQL user: ${DB_MYSQL_USER}"
        MYSQL_PWD="$DB_ROOT_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port="$PORT_MYSQL" -u root <<SQL
CREATE USER '${DB_MYSQL_USER}'@'%' IDENTIFIED BY '${DB_MYSQL_PASSWORD}';
SQL
        MYSQL_PWD="$DB_ROOT_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port="$PORT_MYSQL" -u root -e "GRANT ALL PRIVILEGES ON \`${DB_MYSQL_NAME}\`.* TO '${DB_MYSQL_USER}'@'%';"
        MYSQL_PWD="$DB_ROOT_PASSWORD" mysql --protocol=TCP --host=127.0.0.1 --port="$PORT_MYSQL" -u root -e "FLUSH PRIVILEGES;"

        success "MySQL database ${DB_MYSQL_NAME} created"
    fi
    # Record only a completed creation; a failed deploy must never authorize DROP of another DB.
    local owned_name owned_user owned_port
    if [[ "$DB_TYPE" == postgres ]]; then
        owned_name="$DB_POSTGRES_NAME"; owned_user="$DB_POSTGRES_USER"; owned_port="$PORT_POSTGRES"
    else
        owned_name="$DB_MYSQL_NAME"; owned_user="$DB_MYSQL_USER"; owned_port="$PORT_MYSQL"
    fi
    printf '%s:%s:%s:%s\n' "$DB_TYPE" "$owned_name" "$owned_user" "$owned_port" > "$PROJECT_DIR/.mooship-native-database"
    chmod 600 "$PROJECT_DIR/.mooship-native-database"
}

# ==================== Build and start Docker ==============
ensure_project_docker_resources() {
    cd "${PROJECT_DIR}" || error "Could not change to directory ${PROJECT_DIR}"

    # Create the external network if missing
    if ! docker network inspect "${SLUG}" >/dev/null 2>&1; then
        info "Creating external network ${SLUG}..."
        if docker network create "${SLUG}" \
            --label "com.docker.compose.project=${SLUG}" \
            --label "com.docker.compose.network=${SLUG}"; then
            info "Network ${SLUG} created successfully"
        else
            error "Could not create network ${SLUG}"
        fi
    else
        info "Network ${SLUG} already exists"
    fi

    info "Checking and creating required volumes..."
    local VOLUMES=("${SLUG}_ssl_certificates" "${SLUG}_certbot_www" "${SLUG}_redis_data")
    if [[ "$DB_NATIVE" != true ]]; then
        VOLUMES=("${SLUG}_db" "${VOLUMES[@]}")
    fi

    local VOLUME
    for VOLUME in "${VOLUMES[@]}"; do
        if ! docker volume inspect "${VOLUME}" >/dev/null 2>&1; then
            info "Creating volume ${VOLUME}..."
            docker volume create "${VOLUME}"
        else
            info "Volume ${VOLUME} already exists"
        fi
    done
}

build_and_start_project() {
    info "Building and starting the project's Docker containers..."
    ensure_project_docker_resources

    info "Running: docker compose up -d --build"
    docker compose build --pull php cron || error "Could not build patched PHP images"
    mooship_verify_project_php || error "PHP security verification failed"
    if ! docker compose up -d --build php nginx redis certbot_renew; then
        error "Could not build/start the project. Check logs: cd ${PROJECT_DIR} && docker compose logs"
    fi

    info "The docker compose command completed successfully"

    info "Waiting for PHP-FPM, nginx, Redis, and the database to become ready..."

    info "Checking container status..."
    local RUNNING
    local ALL
    RUNNING=$(docker ps --filter "name=${SLUG}_" --format "{{.Names}}" | wc -l)
    ALL=$(docker ps -a --filter "name=${SLUG}_" --format "{{.Names}}" | wc -l)

    info "Running containers: ${RUNNING} of ${ALL}"

    if [[ $RUNNING -eq 0 ]]; then
        error "Containers are not running: cd ${PROJECT_DIR} && docker compose logs"
    else
        info "Container status:"
        docker ps -a --filter "name=${SLUG}_" --format "table {{.Names}}\t{{.Status}}"

        # Check critical containers (php, nginx, db)
        local CRITICAL_RUNNING
        CRITICAL_RUNNING=$(docker ps --filter "name=${SLUG}_php" --filter "name=${SLUG}_nginx" --filter "name=${SLUG}_db" --format "{{.Names}}" | wc -l)
        if [[ $CRITICAL_RUNNING -ge 2 ]]; then
            info "Main containers (php, nginx, db) are running"
        else
            error "Some critical containers did not start. Check the logs."
        fi
    fi

    local SERVICE
    for SERVICE in php nginx redis certbot_renew; do
        mooship_wait_service "$SERVICE" || error "Service ${SERVICE} is not ready"
    done
    if [[ "$DB_NATIVE" != true ]]; then
        mooship_wait_database || error "The database is not ready"
    else
        mooship_check_database tcp || error "Native DB is unreachable; check --db-host, database listeners and firewall"
    fi
    cd "${SCRIPT_DIR}" || true
}

# Moodle code has been downloaded: version.php is at the root (before 5.1) or in public/ (5.1+)
moodle_code_present() {
    [[ -f "${PROJECT_DIR}/public_html/version.php" || -f "${PROJECT_DIR}/public_html/public/version.php" ]]
}

# ==================== Install Moodle using wget ==============
install_moodle() {
    info "Installing Moodle version ${MOODLE_VERSION}..."
    cd "${PROJECT_DIR}" || error "Could not change to directory ${PROJECT_DIR}"

    # Check whether Moodle is already installed (config.php or version.php exists)
    if [[ -f "${PROJECT_DIR}/public_html/config.php" ]] || moodle_code_present; then
        warn "Moodle is already installed in ${PROJECT_DIR}/public_html/"
        info "Skipping Moodle installation"
        cd "${SCRIPT_DIR}" || true
        return
    fi

    ensure_packages wget unzip

    local TEMP_DIR="${PROJECT_DIR}/temp_moodle"
    mkdir -p "${TEMP_DIR}" "${PROJECT_DIR}/public_html"

    # URL for downloading Moodle from GitHub
    local MOODLE_URL="${MOODLE_REPOSITORY}/archive/refs/tags/v${MOODLE_VERSION}.zip"

    info "Downloading Moodle from ${MOODLE_URL}..."
    if ! wget -q "${MOODLE_URL}" -O "${TEMP_DIR}/moodle.zip"; then
        rm -rf "${TEMP_DIR}"
        error "Could not download Moodle from ${MOODLE_URL}. Check version ${MOODLE_VERSION}"
    fi

    info "Moodle downloaded successfully, extracting..."
    cd "${TEMP_DIR}" || error "Could not change to ${TEMP_DIR}"
    unzip -q moodle.zip || error "Could not extract Moodle"

    # GitHub creates a moodle-<version> directory
    local EXTRACTED_DIR
    EXTRACTED_DIR=$(find . -maxdepth 1 -type d -name "moodle-*" | head -n 1)
    if [[ -z "$EXTRACTED_DIR" ]]; then
        error "Could not find the extracted Moodle directory"
    fi

    info "Moodle extracted, moving files..."
    mv "${EXTRACTED_DIR}"/* "${PROJECT_DIR}/public_html/" 2>/dev/null || true
    mv "${EXTRACTED_DIR}"/.[!.]* "${PROJECT_DIR}/public_html/" 2>/dev/null || true

    cd "${PROJECT_DIR}" || error "Could not change to directory ${PROJECT_DIR}"
    rm -rf "${TEMP_DIR}"

    if ! moodle_code_present; then
        error "version.php not found in the Moodle ${MOODLE_VERSION} archive"
    fi
    mooship_require_project_runtime

    # Moodle 5.1+: web files moved to public/ (config.php, lib/, and admin/cli remain at the root)
    if [[ -f "${PROJECT_DIR}/public_html/public/version.php" ]]; then
        info "Moodle 5.1+: nginx document root → /var/www/html/public"
        python3 "$SCRIPT_DIR/lib/web.py" --public-root "${PROJECT_DIR}/.config/nginx/_site.conf" ||
            error "Could not select the Moodle public document root"
    fi

    success "Moodle ${MOODLE_VERSION} installed successfully!"

    mkdir -p "${PROJECT_DIR}/moodledata"

    info "Setting permissions..."
    docker compose run --rm permissions

    info "Moodle is ready for configuration in ${PROJECT_DIR}/public_html/"
    info "Moodledata is located in ${PROJECT_DIR}/moodledata/"

    cd "${SCRIPT_DIR}" || true
}

# ==================== Configure Moodle config.php ==============
configure_moodle_config() {
    local MOODLE_CONFIG="${PROJECT_DIR}/public_html/config.php"
    local SITE_SCHEME
    SITE_SCHEME=$(site_scheme)

    if [[ -f "$MOODLE_CONFIG" ]]; then
        warn "config.php already exists: ${MOODLE_CONFIG}"
        info "Skipping config.php creation"
        return
    fi

    if ! moodle_code_present; then
        error "Moodle is not installed (version.php is missing)"
    fi

    info "Creating config.php for Moodle..."

    local DB_TYPE_MOODLE=""
    local DB_HOST_VALUE=""
    local DB_NAME=""
    local DB_USER=""
    local DB_PASS=""
    local DB_PORT_VALUE=""

    if [[ "$DB_TYPE" == "postgres" ]]; then
        DB_TYPE_MOODLE="pgsql"
        DB_NAME="$DB_POSTGRES_NAME"
        DB_USER="$DB_POSTGRES_USER"
        DB_PASS="$DB_POSTGRES_PASSWORD"
    else
        DB_TYPE_MOODLE="mysqli"
        DB_NAME="$DB_MYSQL_NAME"
        DB_USER="$DB_MYSQL_USER"
        DB_PASS="$DB_MYSQL_PASSWORD"
    fi

    # Native database: container-reachable host address and host port.
    # Container database: container name and internal port (the external .env port does not listen inside the network)
    if [[ "$DB_NATIVE" == true ]]; then
        DB_HOST_VALUE="${NATIVE_DB_HOST:-host.docker.internal}"
        if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT_VALUE="$PORT_POSTGRES"; else DB_PORT_VALUE="$PORT_MYSQL"; fi
    else
        DB_HOST_VALUE="${SLUG}_db"
        if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT_VALUE="5432"; else DB_PORT_VALUE="3306"; fi
    fi

    cat > "$MOODLE_CONFIG" <<EOF
<?php  // Moodle configuration file

unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = '${DB_TYPE_MOODLE}';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = '${DB_HOST_VALUE}';
\$CFG->dbname    = '${DB_NAME}';
\$CFG->dbuser    = '${DB_USER}';
\$CFG->dbpass    = '${DB_PASS}';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array (
  'dbpersist' => 0,
  'dbport' => '${DB_PORT_VALUE}',
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

\$CFG->wwwroot   = '${SITE_SCHEME}://${DOMAIN}';
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

// nginx serves moodledata files (location ^~ /dataroot/ in .config/nginx/_site.conf).
\$CFG->xsendfile = 'X-Accel-Redirect';
\$CFG->xsendfilealiases = array('/dataroot/' => \$CFG->dataroot);

// nginx sends unknown paths to r.php (Moodle 4.5+ routing engine); older releases ignore this.
\$CFG->routerconfigured = true;

// PHP sessions in the project's Redis container (password: REDIS_PASSWORD in .env).
\$CFG->session_handler_class = '\core\session\redis';
\$CFG->session_redis_host = '${SLUG}_redis';
\$CFG->session_redis_port = 6379;
\$CFG->session_redis_auth = '${REDIS_PASSWORD}';
\$CFG->session_redis_prefix = 'mdl_session_';

require_once(__DIR__ . '/lib/setup.php');

// There is no php closing tag in this file,
// it is intentional because it prevents trailing whitespace problems!
EOF

    chown 1000:1000 "$MOODLE_CONFIG"
    chmod 600 "$MOODLE_CONFIG"

    if [[ -f "$MOODLE_CONFIG" ]]; then
        success "config.php created successfully!"
        info "Database settings saved in ${MOODLE_CONFIG}:"
        info "  DB_TYPE: ${DB_TYPE_MOODLE}"
        info "  DB_HOST: ${DB_HOST_VALUE}"
        info "  DB_PORT: ${DB_PORT_VALUE}"
        info "  DB_NAME: ${DB_NAME}"
        info "  DB_USER: ${DB_USER}"
        info "  WWW_ROOT: ${SITE_SCHEME}://${DOMAIN}"
        info "  DATA_ROOT: /var/www/moodledata"
    else
        error "Could not create config.php"
    fi
}

# ==================== Install Moodle automatically through CLI ==============
install_moodle_database() {
    local MOODLE_CONFIG="${PROJECT_DIR}/public_html/config.php"

    if [[ ! -f "$MOODLE_CONFIG" ]]; then
        error "config.php not found; Moodle installation was not performed"
    fi

    info "Checking whether Moodle is installed..."
    cd "${PROJECT_DIR}" || error "Could not change to directory ${PROJECT_DIR}"

    local CHECK_STATUS=0
    mooship_check_database installed || CHECK_STATUS=$?
    if [[ "$CHECK_STATUS" == 0 ]]; then
        info "Moodle is already installed, skipping database installation"
        cd "${SCRIPT_DIR}" || true
        return
    fi
    [[ "$CHECK_STATUS" == 3 ]] || error "Could not verify the Moodle installation state"

    info "Starting automatic Moodle installation through CLI..."
    info "This may take several minutes..."

    local ADMIN_USER="${MOODLE_ADMIN_USER:-admin}"
    local ADMIN_PASSWORD="${MOODLE_ADMIN_PASSWORD:-$(generate_random_password)}"
    local ADMIN_EMAIL="${MOODLE_ADMIN_EMAIL:-${ADMIN_USER}@${DOMAIN}}"

    local SITE_FULLNAME="${MOODLE_SITE_FULLNAME:-Moodle Site - ${SLUG}}"
    local SITE_SHORTNAME="${MOODLE_SITE_SHORTNAME:-${SLUG}}"

    if [[ -n "$MOODLE_ADMIN_USER" ]]; then
        info "Using the specified administrator login: ${ADMIN_USER}"
    else
        info "Generating the default administrator login: ${ADMIN_USER}"
    fi

    if [[ -n "$MOODLE_ADMIN_PASSWORD" ]]; then
        info "Using the specified administrator password"
    else
        info "Generating a random administrator password"
    fi

    if [[ -n "$MOODLE_SITE_FULLNAME" ]]; then
        info "Using the specified full site name: ${SITE_FULLNAME}"
    else
        info "Generating the default site name: ${SITE_FULLNAME}"
    fi

    if [[ -n "$MOODLE_SITE_SHORTNAME" ]]; then
        info "Using the specified short site name: ${SITE_SHORTNAME}"
    else
        info "Generating the default short site name: ${SITE_SHORTNAME}"
    fi

    if docker compose exec -T php php /var/www/html/admin/cli/install_database.php \
        --agree-license \
        --lang=en \
        --adminuser="${ADMIN_USER}" \
        --adminpass="${ADMIN_PASSWORD}" \
        --adminemail="${ADMIN_EMAIL}" \
        --fullname="${SITE_FULLNAME}" \
        --shortname="${SITE_SHORTNAME}" 2>&1; then

        success "Moodle installed successfully!"

        info "Saving administrator credentials to .env..."
        {
            echo ""
            echo "# Moodle Administrator Credentials"
            echo "MOODLE_ADMIN_USER=${ADMIN_USER}"
            echo "MOODLE_ADMIN_PASSWORD=${ADMIN_PASSWORD}"
            echo "MOODLE_ADMIN_EMAIL=${ADMIN_EMAIL}"
        } >> "${PROJECT_DIR}/.env"

        echo ""
        echo "============================================================"
        echo "MOODLE ADMINISTRATOR:"
        echo "============================================================"
        echo "  URL:      $(site_scheme)://${DOMAIN}/login/"
        echo "  Username: ${ADMIN_USER}"
        echo "  Password: saved in .env (MOODLE_ADMIN_PASSWORD)"
        echo "  Email:    ${ADMIN_EMAIL}"
        echo "============================================================"
        echo ""

        # For output in print_summary
        MOODLE_ADMIN_USER="${ADMIN_USER}"
        MOODLE_ADMIN_PASSWORD="${ADMIN_PASSWORD}"
        MOODLE_ADMIN_EMAIL="${ADMIN_EMAIL}"
    else
        error "Could not install Moodle through CLI. Deployment failed; check the project logs."
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Configure outgoing mail ==============
# Regular Moodle settings, editable later in Site administration > Server > Email.
# Values travel as environment variables of docker exec, never as command-line arguments,
# so the SMTP password does not appear in process listings.
configure_moodle_mail() {
    [[ -n "$SMTP_HOST" || -n "$NOREPLY_EMAIL" ]] || return 0

    info "Configuring Moodle outgoing mail..."
    local SECURE="$SMTP_SECURE"
    [[ "$SECURE" != none ]] || SECURE=""
    MOOSHIP_SMTPHOSTS="$SMTP_HOST" MOOSHIP_SMTPSECURE="$SECURE" MOOSHIP_SMTPUSER="$SMTP_USER" \
    MOOSHIP_SMTPPASS="$SMTP_PASSWORD" MOOSHIP_NOREPLYADDRESS="$NOREPLY_EMAIL" \
        docker exec -i -e MOOSHIP_SMTPHOSTS -e MOOSHIP_SMTPSECURE -e MOOSHIP_SMTPUSER \
            -e MOOSHIP_SMTPPASS -e MOOSHIP_NOREPLYADDRESS "${SLUG}_php" php <<'PHP' ||
<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
if (getenv('MOOSHIP_SMTPHOSTS') !== '') {
    foreach (['smtphosts', 'smtpsecure', 'smtpuser', 'smtppass'] as $name) {
        set_config($name, (string) getenv('MOOSHIP_' . strtoupper($name)));
    }
}
if (getenv('MOOSHIP_NOREPLYADDRESS') !== '') {
    set_config('noreplyaddress', getenv('MOOSHIP_NOREPLYADDRESS'));
}
PHP
        error "Could not configure outgoing mail. Set it in Site administration > Server > Email > Outgoing mail configuration"

    if [[ -n "$SMTP_HOST" ]]; then
        success "Moodle sends mail through ${SMTP_HOST} (${SMTP_SECURE})"
    fi
}

# ==================== Obtain an SSL certificate ===========
obtain_ssl_certificate() {
    if [[ "$OBTAIN_SSL" != true ]]; then
        info "Skipping SSL certificate acquisition (--no-ssl specified)"
        return
    fi

    info "Obtaining an SSL certificate for domain ${DOMAIN}..."
    cd "${PROJECT_DIR}" || error "Could not change to directory ${PROJECT_DIR}"

    # SSL is required: do not report a successful deployment if acquisition fails.
    if docker compose run --rm certbot certonly \
        --webroot -w /var/www/certbot \
        -d "${DOMAIN}" \
        --email "${SSL_EMAIL}" \
        --agree-tos \
        --non-interactive; then
        info "SSL certificate obtained successfully for ${DOMAIN}!"

        uncomment_ssl_blocks

        docker compose exec -T nginx nginx -t || error "The project's nginx SSL configuration is invalid"
        info "Restarting the project's nginx to apply SSL configuration..."
        docker compose restart nginx

        info "Restarting nginxproxy to apply SSL configuration..."
        cd "${PROXY_DIR}" || error "Could not change to ${PROXY_DIR}"
        docker compose exec -T nginxproxy nginx -t || error "The nginxproxy SSL configuration is invalid"
        docker compose restart

        info "SSL configuration applied successfully!"
    else
        warn "Could not obtain an SSL certificate. Check:"
        warn "  - DNS records for ${DOMAIN} point to this server"
        warn "  - Ports 80 and 443 are open and accessible"
        warn "  - nginxproxy is running and working"
        warn "  - The project's nginx is working correctly"
        error "SSL certificate was not obtained; deployment is incomplete"
    fi

    cd "${SCRIPT_DIR}" || true
}

# ==================== Restart nginxproxy ===================
restart_nginxproxy() {
    info "Restarting nginxproxy to apply changes..."
    cd "${PROXY_DIR}" || error "Could not change to ${PROXY_DIR}"

    if ! docker network inspect "${SLUG}" >/dev/null 2>&1; then
        error "Network ${SLUG} not found; nginxproxy is not configured"
    fi

    if docker compose up -d; then
        info "nginxproxy restarted successfully"

        sleep 3

        if docker ps --filter "name=nginxproxy" --format "{{.Names}}" | grep -q "nginxproxy"; then
            info "nginxproxy is running"
        else
            error "nginxproxy is not running: cd ${PROXY_DIR} && docker compose logs"
        fi
    else
        error "Could not apply nginxproxy configuration"
    fi
    docker compose exec -T nginxproxy nginx -t || error "nginxproxy configuration validation failed"

    cd "${SCRIPT_DIR}" || true
}

# ==================== Send project data to an endpoint ====================
send_project_data() {
    if [[ -z "$ENDPOINT" ]]; then
        return
    fi

    info "Sending project data to endpoint: ${ENDPOINT}..."

    local DB_PORT_VALUE=""
    local DB_NAME=""
    local DB_USER=""
    local DB_PASS=""

    if [[ "$DB_TYPE" == "postgres" ]]; then
        DB_PORT_VALUE="$PORT_POSTGRES"
        DB_NAME="$DB_POSTGRES_NAME"
        DB_USER="$DB_POSTGRES_USER"
        DB_PASS="$DB_POSTGRES_PASSWORD"
    else
        DB_PORT_VALUE="$PORT_MYSQL"
        DB_NAME="$DB_MYSQL_NAME"
        DB_USER="$DB_MYSQL_USER"
        DB_PASS="$DB_MYSQL_PASSWORD"
    fi

    local JSON_DATA RESPONSE HTTP_CODE
    JSON_DATA=$(SLUG="$SLUG" DOMAIN="$DOMAIN" APP_TYPE="$APP_TYPE" \
        MOODLE_VERSION="$MOODLE_VERSION" PHP_VERSION="$(php_version_label)" \
        DB_TYPE="$DB_TYPE" DB_PORT_VALUE="$DB_PORT_VALUE" DB_NAME="$DB_NAME" \
        DB_USER="$DB_USER" DB_PASS="$DB_PASS" REDIS_PASSWORD="$REDIS_PASSWORD" \
        PORT_HTTP="$PORT_HTTP" PORT_HTTPS="$PORT_HTTPS" PORT_PHP="$PORT_PHP" \
        PORT_REDIS="$PORT_REDIS" ENABLE_BASIC_AUTH="$ENABLE_BASIC_AUTH" \
        AUTH_USER="$AUTH_USER" AUTH_PASSWORD="$AUTH_PASSWORD" \
        OBTAIN_SSL="$OBTAIN_SSL" SSL_EMAIL="$SSL_EMAIL" WWW_DIR="$WWW_DIR" python3 - <<'PYEOF'
import json
import os
e = os.environ
print(json.dumps({
    "slug": e["SLUG"], "domain": e["DOMAIN"], "app_type": e["APP_TYPE"],
    "moodle_version": e["MOODLE_VERSION"], "php_version": e["PHP_VERSION"],
    "db_type": e["DB_TYPE"],
    "ports": {name: int(e[key]) for name, key in (
        ("http", "PORT_HTTP"), ("https", "PORT_HTTPS"),
        ("php", "PORT_PHP"), ("redis", "PORT_REDIS"))},
    "redis": {"password": e["REDIS_PASSWORD"]},
    "database": {"type": e["DB_TYPE"], "port": int(e["DB_PORT_VALUE"]),
                 "name": e["DB_NAME"], "user": e["DB_USER"], "password": e["DB_PASS"]},
    "basic_auth": {"enabled": e["ENABLE_BASIC_AUTH"] == "true",
                   "user": e["AUTH_USER"], "password": e["AUTH_PASSWORD"]},
    "ssl": {"enabled": e["OBTAIN_SSL"] == "true", "email": e["SSL_EMAIL"]},
    "project_path": e["WWW_DIR"] + "/" + e["SLUG"],
}))
PYEOF
)
    RESPONSE=$(printf '%s' "$JSON_DATA" | curl -X PUT \
        --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 \
        -H "Content-Type: application/json" --data-binary @- \
        -o /dev/null -w '%{http_code}' -s "$ENDPOINT") || true
    HTTP_CODE="$RESPONSE"
    if [[ "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
        success "Data sent to the endpoint (HTTP ${HTTP_CODE})"
    else
        warn "The endpoint did not accept the data (HTTP ${HTTP_CODE:-unavailable})"
    fi
}

# ==================== Create a project backup archive ====================
create_project_backup() {
    [[ "$CREATE_BACKUP" == true ]] || return 0
    local BACKUP_PATH
    BACKUP_PATH="/var/backups/mooship/${SLUG}_$(date +%Y%m%d_%H%M%S).tar.gz"
    source "$SCRIPT_DIR/backup.sh"
    backup_project "$SLUG" "$BACKUP_PATH"
    BACKUP_FILE_PATH="$BACKUP_PATH"
    printf '\n# Backup Archive\nBACKUP_ARCHIVE_PATH=%s\n' "$BACKUP_PATH" >> "$PROJECT_DIR/.env"
}

# ==================== Display summary information ====================
print_summary() {
    echo ""
    echo "============================================================"
    info "Deployment completed!"
    echo "============================================================"
    echo ""
    echo "PROJECT:"
    echo "  Slug:           ${SLUG}"
    echo "  Domain:         ${DOMAIN}"
    echo "  Type:           ${APP_TYPE}"
    echo "  Moodle:         ${MOODLE_VERSION}"
    echo "  PHP:            $(php_version_label)"
    echo "  DB Type:        ${DB_TYPE}$([[ "$DB_NATIVE" == true ]] && echo " (native)")"
    echo "  Project Path:   ${WWW_DIR}/${SLUG}"
    echo "  .env:           ${WWW_DIR}/${SLUG}/.env"
    echo ""
    echo "PORTS:"
    echo "  HTTP:           ${PORT_HTTP}"
    echo "  HTTPS:          ${PORT_HTTPS}"
    echo "  PHP-FPM:        ${PORT_PHP}"
    echo "  Redis:          ${PORT_REDIS}"
    if [[ "$DB_TYPE" == "mysql" ]]; then
        echo "  MySQL:          ${PORT_MYSQL}"
    else
        echo "  PostgreSQL:     ${PORT_POSTGRES}"
    fi
    echo ""
    echo "REDIS:"
    echo "  Password: saved in .env (REDIS_PASSWORD)"
    echo "  Used for:       Moodle sessions"
    echo ""
    echo "RESOURCES:"
    echo "  Profile:        ${PROFILE} (PHP-FPM workers: ${PHP_FPM_MAX_CHILDREN}; values in .env)"
    echo ""
    echo "MAIL:"
    if [[ -n "$SMTP_HOST" ]]; then
        echo "  SMTP:           ${SMTP_HOST} (${SMTP_SECURE})"
    else
        echo "  SMTP:           not configured; Moodle cannot deliver email (see --smtp-host)"
    fi
    echo ""
    if [[ "$DB_TYPE" == "mysql" ]]; then
        echo "MYSQL:"
        echo "  Database:       ${DB_MYSQL_NAME}"
        echo "  User:           ${DB_MYSQL_USER}"
        echo "  Password: saved in .env (DB_MYSQL_PASSWORD)"
        echo "  Password: saved in .env (DB_MYSQL_ROOT_PASSWORD)"
    else
        echo "POSTGRESQL:"
        echo "  Database:       ${DB_POSTGRES_NAME}"
        echo "  User:           ${DB_POSTGRES_USER}"
        echo "  Password: saved in .env (DB_POSTGRES_PASSWORD)"
    fi
    echo ""
    if [[ "$ENABLE_BASIC_AUTH" == true ]]; then
        echo "HTTP BASIC AUTHENTICATION:"
        echo "  User:           ${AUTH_USER}"
        echo "  Password: saved in .env (AUTH_PASSWORD)"
        echo "  .htpasswd:      ${WWW_DIR}/${SLUG}/.config/nginx/.htpasswd"
        echo ""
    fi
    if [[ -n "$MOODLE_ADMIN_USER" ]]; then
        echo "MOODLE ADMINISTRATOR:"
        echo "  URL:            $(site_scheme)://${DOMAIN}/login/"
        echo "  Username:       ${MOODLE_ADMIN_USER}"
        echo "  Password: saved in .env (MOODLE_ADMIN_PASSWORD)"
        echo "  Email:          ${MOODLE_ADMIN_EMAIL}"
        echo ""
    fi
    echo "============================================================"
    echo "Next steps:"
    echo "============================================================"
    if [[ "$OBTAIN_SSL" == true ]]; then
        echo "  1. Restart the proxy to apply the SSL certificate:"
        echo "       cd ${PROXY_DIR} && docker compose restart"
        echo ""
        echo "  2. Check site availability:"
        echo "       https://${DOMAIN}"
    else
        echo "  1. Check site availability:"
        echo "       http://${DOMAIN}"
        echo ""
        echo "  2. To switch to HTTPS later, follow the HTTP-to-HTTPS procedure in README.md."
    fi
    echo ""
    echo "  Check container status:"
    echo "       cd ${WWW_DIR}/${SLUG} && docker compose ps"
    echo ""
    echo "  Check the site's health (containers, HTTP, certificate, Moodle, mail, backups):"
    echo "       sudo bash ${SCRIPT_DIR}/doctor.sh --slug ${SLUG}"
    echo ""
    echo "  Schedule daily backups (keeps 7 archives by default):"
    echo "       sudo bash ${SCRIPT_DIR}/schedule-backup.sh --slug ${SLUG}"
    echo ""

    if [[ -n "$BACKUP_FILE_PATH" ]]; then
        echo "BACKUP:"
        echo "  Project archive: ${BACKUP_FILE_PATH}"
        echo ""
    fi

    echo "============================================================"
    echo ""
}

# ==================== MAIN ==================================
main() {
    local ARG
    for ARG in "$@"; do
        case "$ARG" in -h|--help) usage; exit 0 ;; esac
    done

    check_root
    info "Parsing arguments..."
    parse_args "$@"
    mooship_require_new_project
    assign_ports
    info "Arguments processed successfully"
    resolve_moodle_version
    select_php_version_for_moodle
    select_resource_profile
    install_docker
    mooship_require_docker
    mooship_require_unused_resources
    if [[ "$DB_NATIVE" == true ]]; then
        if [[ "$DB_TYPE" == postgres ]]; then mooship_validate_port "$PORT_POSTGRES";
        else mooship_validate_port "$PORT_MYSQL"; fi
        mooship_require_new_native_database
    fi
    ensure_www_dir
    init_nginxproxy
    ensure_logrotate
    create_dhparam
    create_project
    comment_ssl_blocks
    build_and_start_project
    create_native_database
    (cd "$PROJECT_DIR" && mooship_check_database connect) || error "PHP cannot authenticate to the selected database"
    install_moodle
    install_moodle_dependencies
    configure_moodle_config
    reload_project_nginx
    install_moodle_database
    configure_moodle_mail
    start_moodle_cron
    # Publish upstreams only after the application and its Docker network exist.
    update_proxy_nginx_conf
    update_proxy_docker_compose
    comment_ssl_blocks
    restart_nginxproxy
    obtain_ssl_certificate
    create_project_backup
    send_project_data
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
