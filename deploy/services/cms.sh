#!/usr/bin/env bash
set -euo pipefail

export SHELL=/bin/bash

# Script directory (templates are one level up)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

# Load deploy env file if present (written by justfile push)
[[ -f "${SCRIPT_DIR}/../deploy.env" ]] && source "${SCRIPT_DIR}/../deploy.env"

# Application configuration
APP_NAME="${APP_NAME:-cms}"
APP_USER="${APP_USER:-ubuntu}"
DEPLOY_DIR="${DEPLOY_DIR:-/var/www/app/${APP_NAME}}"
SERVER_DIR="${DEPLOY_DIR}/server"
CLIENT_DIR="${DEPLOY_DIR}/client"
ENV_FILE="${ENV_FILE:-/etc/${APP_NAME}/env}"
LOG_DIR="/var/log/${APP_NAME}"

USE_PNPM="${USE_PNPM:-false}"
USE_UV="${USE_UV:-false}"

PYTHON_VERSION="${PYTHON_VERSION:-3.10}"
NODE_VERSION="${NODE_VERSION:-22}"
NPM_VERSION="${NPM_VERSION:-10}"
REDIS_VERSION="${REDIS_VERSION:-5.0}"
MONGO_VERSION="${MONGO_VERSION:-6.0}"
ELASTICSEARCH_VERSION="${ELASTICSEARCH_VERSION:-7.17.10}"

# Repository
# REPO_REF accepts a branch or a release tag (e.g. cp30.1). REPO_BRANCH is
# kept as a back-compat alias for env files that still set it.
REPO_URL="${REPO_URL:-https://github.com/canadianpress/superdesk-cp-2.git}"
REPO_REF="${REPO_REF:-develop}"

# Which requirements file to install (cp30 ships a pip-compiled requirements.txt;
# dev-requirements.txt also exists but pulls in pytest/mypy/black — not for prod)
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-requirements.txt}"

# Web server
# Ports below mirror honcho's PORT assignment for the cp30 Procfile
# (rest=5000, wamp=5100, …, capi=5400, papi=5500) and are used for nginx routing.
WEB_PORT="${WEB_PORT:-5000}"
WS_PORT="${WS_PORT:-5100}"
WEB_TIMEOUT="${WEB_TIMEOUT:-30}"
DOMAIN="${DOMAIN:-localhost}"
CAPI_PORT="${CAPI_PORT:-5400}"
PAPI_PORT="${PAPI_PORT:-5500}"
# hypercorn_config.py reads WEB_CONCURRENCY; CAPI/PAPI workers are read by the Procfile
WEB_CONCURRENCY="${WEB_CONCURRENCY:-${WEB_WORKERS:-2}}"
CAPI_WORKERS="${CAPI_WORKERS:-2}"
PAPI_WORKERS="${PAPI_WORKERS:-2}"

# Computed URLs (derived from DOMAIN)
# PRODAPI_URL is the host only (no path, no trailing slash) — prod_api appends
# its own PRODAPI_URL_PREFIX (default "prodapi") and API_VERSION.
if [[ "$DOMAIN" == "localhost" ]]; then
    SUPERDESK_CLIENT_URL="${SUPERDESK_CLIENT_URL:-http://localhost}"
    SUPERDESK_URL="${SUPERDESK_URL:-http://localhost/api}"
    CONTENTAPI_URL="${CONTENTAPI_URL:-http://localhost/contentapi}"
    PRODAPI_URL="${PRODAPI_URL:-http://localhost}"
    SUPERDESK_WS_URL="${SUPERDESK_WS_URL:-ws://localhost/ws}"
else
    SUPERDESK_CLIENT_URL="${SUPERDESK_CLIENT_URL:-https://${DOMAIN}}"
    SUPERDESK_URL="${SUPERDESK_URL:-https://${DOMAIN}/api}"
    CONTENTAPI_URL="${CONTENTAPI_URL:-https://${DOMAIN}/contentapi}"
    PRODAPI_URL="${PRODAPI_URL:-https://${DOMAIN}}"
    SUPERDESK_WS_URL="${SUPERDESK_WS_URL:-wss://${DOMAIN}/ws}"
fi

# Database
MONGODB_HOST="${MONGODB_HOST:-localhost}"
MONGODB_PORT="${MONGODB_PORT:-27017}"
MONGODB_DB="${MONGODB_DB:-cms}"
ELASTICSEARCH_HOST="${ELASTICSEARCH_HOST:-localhost}"
ELASTICSEARCH_PORT="${ELASTICSEARCH_PORT:-9200}"
ELASTICSEARCH_INDEX="${ELASTICSEARCH_INDEX:-cms}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_DB="${REDIS_DB:-1}"
DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-America/Toronto}"

# Semaphore (Progress/Smartlogic) — set via env or ENV_FILE
SEMAPHORE_BASE_URL="${SEMAPHORE_BASE_URL:-https://cp.data.progress.cloud}"
SEMAPHORE_TOKEN_URL="${SEMAPHORE_TOKEN_URL:-https://cp.data.progress.cloud/token}"
SEMAPHORE_API_KEY_URL="${SEMAPHORE_API_KEY_URL:-https://cp.data.progress.cloud/api/account/apikey}"
SEMAPHORE_ANALYZE_URL="${SEMAPHORE_ANALYZE_URL:-https://cp.data.progress.cloud/classification/prod/?operation=classify}"
SEMAPHORE_SEARCH_URL="${SEMAPHORE_SEARCH_URL:-https://cp.data.progress.cloud/sis/prod/ses/CPKnowledgeSystem/en/hints/}"
SEMAPHORE_GET_PARENT_URL="${SEMAPHORE_GET_PARENT_URL:-https://cp.data.progress.cloud/sis/prod/ses/CPKnowledgeSystem/en/relatedfrom/}"
SEMAPHORE_CREATE_TAG_URL="${SEMAPHORE_CREATE_TAG_URL:-https://cp.data.progress.cloud/studio/cpstudio/kmm/api}"
SEMAPHORE_CREATE_TAG_TASK="${SEMAPHORE_CREATE_TAG_TASK:-/task:CPKnowledgeSystem:SuggestedTerm}"
SEMAPHORE_CREATE_TAG_QUERY="${SEMAPHORE_CREATE_TAG_QUERY:-/skos:Concept/rdf:instance}"

# Translation services — set via env or ENV_FILE
GOOGLE_API_KEY="${GOOGLE_API_KEY:-}"
GOOGLE_API_URL="${GOOGLE_API_URL:-https://translation.googleapis.com/language/translate}"
GOOGLE_PROJECT_ID="${GOOGLE_PROJECT_ID:-pctrad-202713}"
GOOGLE_PROJECT_LOCATION="${GOOGLE_PROJECT_LOCATION:-us-central1}"
GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-}"
# settings.py reads GOOGLE_SERVICE_ACCOUNT_PATH; default it to the same file
GOOGLE_SERVICE_ACCOUNT_PATH="${GOOGLE_SERVICE_ACCOUNT_PATH:-${GOOGLE_APPLICATION_CREDENTIALS}}"
DEEPL_AUTH_KEY="${DEEPL_AUTH_KEY:-}"
DEEPL_API_URL="${DEEPL_API_URL:-https://api.deepl.com/v2/translate}"

# Optional: Admin user creation
# ADMIN_EMAIL, ADMIN_PASSWORD

# Frontend build options
NODE_MAX_MEM="${NODE_MAX_MEM:-4096}"

# Timing (set TIMING=true to enable per-step timing)
TIMING="${TIMING:-false}"
DEPLOY_START="${EPOCHSECONDS:-$(date +%s)}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Run a function and print elapsed time if TIMING=true
time_step() {
    local label="$1"
    shift
    if [[ "$TIMING" == "true" ]]; then
        local start=${EPOCHSECONDS:-$(date +%s)}
        "$@"
        local end=${EPOCHSECONDS:-$(date +%s)}
        echo -e "${BLUE}[TIME]${NC} ${label}: $((end - start))s"
    else
        "$@"
    fi
}

preflight_checks() {
    [[ "$(whoami)" == "$APP_USER" ]] || { log_error "Must run as $APP_USER"; exit 1; }
    sudo -n true 2>/dev/null || { log_error "$APP_USER needs sudo access. Run setup-cms-system.sh first."; exit 1; }
    [[ -d "$TEMPLATE_DIR" ]] || { log_error "Template directory not found: $TEMPLATE_DIR"; exit 1; }
}

setup_directories() {
    log_info "Setting up directories..."

    for dir in "${DEPLOY_DIR}" "$(dirname "${ENV_FILE}")" "${LOG_DIR}"; do
        if [[ ! -d "${dir}" ]]; then
            sudo mkdir -p "${dir}"
            sudo chown "${APP_USER}:${APP_USER}" "${dir}"
        fi
    done

    log_info "Directories created"
}

clone_or_update_repo() {
    log_info "Cloning/updating repository..."

    if [[ -d "$DEPLOY_DIR/.git" ]]; then
        log_info "Repository exists, fetching..."
        git -C "$DEPLOY_DIR" fetch --prune --tags --force origin
    else
        log_info "Cloning repository..."
        git clone "$REPO_URL" "$DEPLOY_DIR"
        git -C "$DEPLOY_DIR" fetch --tags --force origin
    fi

    # REPO_REF may be a tag (e.g. cp30.1) or a branch — tags have no
    # origin/<ref> tracking ref, so the two cases are handled separately.
    if git -C "$DEPLOY_DIR" rev-parse -q --verify "refs/tags/${REPO_REF}" >/dev/null; then
        log_info "Checking out tag ${REPO_REF}"
        git -C "$DEPLOY_DIR" checkout --force "tags/${REPO_REF}"
    else
        log_info "Checking out branch ${REPO_REF}"
        git -C "$DEPLOY_DIR" checkout --force -B "$REPO_REF" "origin/${REPO_REF}"
    fi

    git config --global --add safe.directory "$DEPLOY_DIR" 2>/dev/null || true
    log_info "Repository ready at $(git -C "$DEPLOY_DIR" rev-parse --short HEAD) (${REPO_REF})"
}

setup_python() {
    log_info "Setting up Python virtual environment..."

    cd "$SERVER_DIR"

    local req="$REQUIREMENTS_FILE"
    [[ -f "$req" ]] || { log_error "Requirements file not found: $SERVER_DIR/$req"; exit 1; }

    install_pyenv

    if [[ "$USE_UV" == "true" ]]; then
        install_uv
        if [[ ! -d "env" ]]; then
            uv venv --seed --python "${PYTHON_VERSION}" env
        fi
        log_info "Installing Python dependencies..."
        uv pip install --quiet --python env/bin/python -r "$req"
    else
        if [[ ! -d "env" ]]; then
            python -m venv env
        fi
        log_info "Installing Python dependencies..."
        source env/bin/activate
        pip install --quiet --progress-bar off --upgrade pip wheel setuptools
        pip install --quiet --progress-bar off -r "$req"
        deactivate
    fi

    log_success "Python environment ready"
}

install_pyenv() {
    export PYENV_ROOT="$HOME/.pyenv"
    [[ ":$PATH:" != *":$PYENV_ROOT/bin:"* ]] && export PATH="$PYENV_ROOT/bin:$PATH"
    if ! command -v pyenv >/dev/null 2>&1; then
        log_info "Installing pyenv..."
        curl -fsSL https://pyenv.run | bash
        "$PYENV_ROOT/bin/pyenv" init --install
    fi
    eval "$("$PYENV_ROOT/bin/pyenv" init -)"
    pyenv install -s "${PYTHON_VERSION}"
    pyenv shell "${PYTHON_VERSION}"
}

install_uv() {
    if ! command -v uv &>/dev/null; then
        log_info "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi
    
}

setup_frontend() {
    log_info "Building frontend..."

    cd "$CLIENT_DIR"
    install_pnpm
    export NODE_OPTIONS="--max-old-space-size=${NODE_MAX_MEM}"
    export SUPERDESK_URL SUPERDESK_WS_URL

    if [[ "$USE_PNPM" == "true" ]]; then
        pnpm i -ci --quiet
        pnpm run build > /dev/null 2>&1
    else
        npm i -ci --quiet
        npm run build > /dev/null 2>&1
    fi

    log_success "Frontend built"
}

install_pnpm() {
    export PNPM_HOME="$HOME/.local/share/pnpm"
    [[ ":$PATH:" != *":$PNPM_HOME/bin:"* ]] && export PATH="$PNPM_HOME/bin:$PATH"
    if ! command -v pnpm &>/dev/null; then
        log_info "Installing pnpm + Node.js ${NODE_VERSION}..."
        curl -fsSL https://get.pnpm.io/install.sh | sh
    fi
    pnpm runtime set node "${NODE_VERSION}" -g
    pnpm add -g npm@${NPM_VERSION}
}

run_docker_compose() {
    log_info "Running docker compose up..."

    local compose_dir="${SCRIPT_DIR}/.."
    
    if [[ ! -f "${compose_dir}/docker-compose.yml" ]] && [[ ! -f "${compose_dir}/docker-compose.yaml" ]]; then
        log_error "No docker-compose.yml found in ${compose_dir}"
        exit 1
    fi

    export REDIS_VERSION MONGO_VERSION ELASTICSEARCH_VERSION
    sg docker -c "docker compose -f '${compose_dir}/docker-compose.yml' up -d"
    log_success "Docker containers started successfully."
}

render_template() {
    local template_file="$1"
    shift

    if [[ ! -f "$template_file" ]]; then
        log_error "Template not found: $template_file"
        exit 1
    fi

    local content
    content=$(cat "$template_file")

    # Standard substitutions: replace {{VAR}} with $VAR
    local var
    for var in APP_NAME APP_USER DEPLOY_DIR SERVER_DIR CLIENT_DIR ENV_FILE \
               WEB_PORT WS_PORT CAPI_PORT PAPI_PORT DOMAIN LOG_DIR \
               WEB_CONCURRENCY CAPI_WORKERS PAPI_WORKERS WEB_TIMEOUT ELASTICSEARCH_INDEX \
               SEMAPHORE_BASE_URL SEMAPHORE_TOKEN_URL SEMAPHORE_API_KEY_URL \
               SEMAPHORE_ANALYZE_URL SEMAPHORE_SEARCH_URL SEMAPHORE_GET_PARENT_URL \
               SEMAPHORE_CREATE_TAG_URL SEMAPHORE_CREATE_TAG_TASK SEMAPHORE_CREATE_TAG_QUERY \
               GOOGLE_API_KEY GOOGLE_API_URL GOOGLE_PROJECT_ID GOOGLE_PROJECT_LOCATION \
               GOOGLE_APPLICATION_CREDENTIALS GOOGLE_SERVICE_ACCOUNT_PATH \
               DEEPL_AUTH_KEY DEEPL_API_URL; do
        content="${content//\{\{${var}\}\}/${!var}}"
    done

    # Computed values
    content="${content//\{\{VENV_BIN\}\}/$SERVER_DIR/env/bin}"
    content="${content//\{\{TIMESTAMP\}\}/$(date -u +"%Y-%m-%d %H:%M:%S UTC")}"

    # Extra substitutions passed as KEY=VALUE arguments
    local pair key value
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        content="${content//\{\{${key}\}\}/$value}"
    done

    echo "$content"
}

install_template() {
    local template="$1"
    local dest="$2"
    shift 2

    render_template "$TEMPLATE_DIR/$template" "$@" | sudo tee "$dest" > /dev/null
    sudo chmod 644 "$dest"
}

setup_env_file() {
    log_info "Setting up environment file..."

    if [[ -f "$ENV_FILE" ]]; then
        log_info "Environment file already exists at $ENV_FILE"
        return
    fi

    log_info "Generating environment file from template..."

    # Generate secrets if not provided
    local secret_key="${SECRET_KEY:-$(python${PYTHON_VERSION} -c "import secrets; print(secrets.token_hex(32))")}"
    local auth_secret="${AUTH_SERVER_SHARED_SECRET:-$(python${PYTHON_VERSION} -c "import secrets; print(secrets.token_hex(32))")}"

    # Build database URLs (5 databases for the async stack).
    # Each URI honours an explicit override from the env file — set those
    # (e.g. to mongodb+srv://… Atlas URIs) to use an external cluster.
    local mongo_uri="${MONGO_URI:-mongodb://${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_DB}}"
    local legal_archive_uri="${LEGAL_ARCHIVE_URI:-mongodb://${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_DB}_la}"
    local archived_uri="${ARCHIVED_URI:-mongodb://${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_DB}_ar}"
    local publicapi_mongo_uri="${PUBLICAPI_MONGO_URI:-mongodb://${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_DB}_papi}"
    local contentapi_mongo_uri="${CONTENTAPI_MONGO_URI:-mongodb://${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_DB}_capi}"
    local es_url="http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}"
    local redis_url="redis://${REDIS_HOST}:${REDIS_PORT}/${REDIS_DB}"
    local contentapi_es_index="${ELASTICSEARCH_INDEX}_capi"

    # Build optional vars block
    local optional_vars=""
    for var in AMAZON_CONTAINER_NAME AMAZON_S3_SUBFOLDER MEDIA_PREFIX \
               AMAZON_SERVE_DIRECT_LINKS AMAZON_S3_USE_HTTPS \
               SUPERDESK_TESTING; do
        if [[ -n "${!var:-}" ]]; then
            optional_vars="${optional_vars}${var}=${!var}
"
        fi
    done

    render_template "$TEMPLATE_DIR/cms.env.template" \
        "SECRET_KEY=$secret_key" \
        "AUTH_SERVER_SHARED_SECRET=$auth_secret" \
        "CLIENT_URL=$SUPERDESK_CLIENT_URL" \
        "SUPERDESK_URL=$SUPERDESK_URL" \
        "CONTENTAPI_URL=$CONTENTAPI_URL" \
        "PRODAPI_URL=$PRODAPI_URL" \
        "SUPERDESK_WS_URL=$SUPERDESK_WS_URL" \
        "MONGO_URI=$mongo_uri" \
        "LEGAL_ARCHIVE_URI=$legal_archive_uri" \
        "ARCHIVED_URI=$archived_uri" \
        "PUBLICAPI_MONGO_URI=$publicapi_mongo_uri" \
        "CONTENTAPI_MONGO_URI=$contentapi_mongo_uri" \
        "ELASTICSEARCH_URL=$es_url" \
        "REDIS_URL=$redis_url" \
        "CONTENTAPI_ES_INDEX=$contentapi_es_index" \
        "OPTIONAL_VARS=$optional_vars" | sudo tee "$ENV_FILE" > /dev/null

    sudo chown "$APP_USER:$APP_USER" "$ENV_FILE"
    sudo chmod 600 "$ENV_FILE"
    log_success "Environment file created at $ENV_FILE"
}

wait_for_services() {
    log_info "Waiting for services (systemd auto-restarts if OOM killed)..."

    local timeout=120
    local elapsed=0

    while ! curl -s "http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}" > /dev/null 2>&1; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Elasticsearch not available at ${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT} after ${timeout}s"
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_info "Services ready"
}

initialize_database() {
    log_info "Initializing database..."

    cd "$SERVER_DIR"
    source env/bin/activate
    set -a
    source "$ENV_FILE"
    set +a
    python3 manage.py app:initialize_data || log_warn "initialize_data may have partial failures (this is often OK)"

    log_info "Creating admin user..."
    python3 manage.py users:create \
        -u "${ADMIN_EMAIL:-admin}" \
        -p "${ADMIN_PASSWORD:-admin}" \
        -e "${ADMIN_EMAIL:-admin@localhost.com}" \
        --admin || log_warn "Admin user may already exist"

    deactivate
    log_success "Database initialized"
}

create_procfile() {
    log_info "Generating Procfile..."
    install_template "cms.procfile.template" "${SERVER_DIR}/Procfile"
    log_success "Procfile created"
}

create_systemd_service() {
    log_info "Creating user systemd service..."

    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

    local user_service_dir="${HOME}/.config/systemd/user"
    mkdir -p "${user_service_dir}"
    install_template "app.service.template" "${user_service_dir}/${APP_NAME}.service"

    sudo loginctl enable-linger "${USER}"
    systemctl --user daemon-reload
    systemctl --user enable --now "${APP_NAME}.service"

    log_success "Systemd service created"
}

configure_nginx() {
    log_info "Configuring Nginx..."

    install_template "cms.nginx.conf.template" "/etc/nginx/conf.d/${APP_NAME}.conf"

    # Remove default config if present
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo rm -f /etc/nginx/conf.d/default.conf

    if sudo nginx -t; then
        log_success "Nginx configuration valid"
    else
        log_error "Nginx configuration test failed"
        exit 1
    fi

    sudo systemctl enable nginx
}

configure_logrotate() {
    log_info "Configuring log rotation..."
    install_template "logrotate.template" "/etc/logrotate.d/${APP_NAME}"
    log_success "Log rotation configured"
}

copy_translations() {
    local translations_dir="${CLIENT_DIR}/dist/languages"
    local source="/home/${APP_USER}/fr_CA.json"

    if [[ -f "$source" ]]; then
        log_info "Copying translations..."
        mkdir -p "$translations_dir"
        cp "$source" "$translations_dir/"
        log_success "Translations copied"
    else
        log_warn "No translation file found at $source — skipping"
    fi
}

restart_services() {
    log_info "Restarting services..."

    systemctl --user restart "${APP_NAME}.service"
    sudo systemctl restart nginx

    sleep 3

    log_info "Services restarted"
}

show_status() {
    echo ""
    log_success "Deployment complete!"
    echo ""
    log_info "Ports: API=$WEB_PORT WS=$WS_PORT CAPI=$CAPI_PORT PAPI=$PAPI_PORT | Ref: ${REPO_REF} @ $(git -C "$DEPLOY_DIR" rev-parse --short HEAD)"
    echo ""
    systemctl --user status "${APP_NAME}.service" --no-pager --lines=0 || true
    echo ""
    sudo systemctl status nginx --no-pager --lines=0 || true
    echo ""
    log_info "Useful commands:"
    echo "  sudo systemctl restart ${APP_NAME}    # restart app"
    echo "  sudo journalctl -u ${APP_NAME} -f     # view logs"
    echo "  sudo vim $ENV_FILE                     # edit env"
    echo "  sudo systemctl reload nginx            # reload nginx"
}

main() {
    log_info "Starting deployment of $APP_NAME"

    time_step "Preflight checks"       preflight_checks
    time_step "Setup directories"      setup_directories
    time_step "Clone/update repo"      clone_or_update_repo
    time_step "Setup Python"           setup_python
    time_step "Build frontend"         setup_frontend
    time_step "Setup env file"         setup_env_file
    time_step "Run Docker Compose"     run_docker_compose
    time_step "Wait for services"      wait_for_services
    time_step "Initialize database"    initialize_database
    # No Procfile generation — the repo ships its own Procfile for the async stack
    time_step "Create systemd service" create_systemd_service
    time_step "Configure nginx"        configure_nginx
    time_step "Configure logrotate"    configure_logrotate
    time_step "Copy translations"      copy_translations
    time_step "Restart services"       restart_services
    show_status

    if [[ "$TIMING" == "true" ]]; then
        local total=$(( ${EPOCHSECONDS:-$(date +%s)} - DEPLOY_START ))
        echo -e "${BLUE}[TIME]${NC} Total: ${total}s"
    fi
}

main "$@"
