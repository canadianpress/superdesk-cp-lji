#!/bin/bash
#
# System Setup Script for Superdesk CMS
# Ubuntu 22.04 LTS (Jammy Jellyfish)
# Run as: sudo ./setup-cms-system.sh

set -euo pipefail

# Suppress needrestart prompts during apt operations
export NEEDRESTART_MODE=a
export DEBIAN_FRONTEND=noninteractive

# Script directory (templates are one level up)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load setup env file if present (written by justfile push)
[[ -f "${SCRIPT_DIR}/../setup.env" ]] && source "${SCRIPT_DIR}/../setup.env"

# Versions
PYTHON_VERSION="${PYTHON_VERSION:-3.8}"

# Timing (set TIMING=true to enable per-step timing)
TIMING="${TIMING:-false}"
DEPLOY_START="${EPOCHSECONDS:-$(date +%s)}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

apt_update() { apt-get update -qq > /dev/null; }
apt_install() { apt-get install -y -qq "$@" > /dev/null; }
apt_upgrade() { apt-get upgrade -y -qq > /dev/null; }

# Run a function and print elapsed time if TIMING=true
time_step() {
    local label="$1"
    shift
    if [[ "$TIMING" == "true" ]]; then
        local start=${EPOCHSECONDS:-$(date +%s)}
        "$@"
        local end=${EPOCHSECONDS:-$(date +%s)}
        echo -e "${CYAN}[TIME]${NC} ${label}: $((end - start))s"
    else
        "$@"
    fi
}

# Add a signed apt repo: add_repo <gpg_key_url> <keyring_name> <repo_line>
add_repo() {
    local key_url="$1" keyring="/usr/share/keyrings/$2.gpg" repo_line="$3"
    curl -fsSL "$key_url" | gpg --dearmor --yes -o "$keyring"
    echo "$repo_line" | tee "/etc/apt/sources.list.d/$2.list" > /dev/null
    apt_update
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Verify Ubuntu 22.04
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "$VERSION_ID" != "22.04" ]]; then
        log_warn "This script targets Ubuntu 22.04, detected: $PRETTY_NAME"
    fi
fi

log_info "Starting system setup for Superdesk..."

# ============================================================================
# Steps
# ============================================================================

install_system_packages() {
    log_info "Updating system packages..."
    apt_update
    apt_upgrade

    log_info "Installing base utilities..."
    apt_install \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        git \
        build-essential \
        pkg-config \
        libffi-dev \
        software-properties-common \
        dos2unix \
        unzip \
        language-pack-en
}

install_python() {
    # C library deps needed for building native extensions (lxml, Pillow, xmlsec, etc.)
    log_info "Installing Python library dependencies..."
    apt_install \
        libxml2-dev \
        libxslt-dev \
        libjpeg-dev \
        zlib1g-dev \
        libmagic-dev \
        libxmlsec1-dev \
        libxmlsec1-openssl \
        libxslt1-dev \
        libjpeg8-dev \
        libtiff5-dev \
        libfreetype6-dev \
        liblcms2-dev \
        libwebp-dev \
        libfontconfig1-dev \
        libssl-dev \
        libexempi8 \
        libimage-exiftool-perl

    log_info "Installing Python ${PYTHON_VERSION}..."
    add-apt-repository -y ppa:deadsnakes/ppa > /dev/null 2>&1
    apt_update
    apt_install \
        "python${PYTHON_VERSION}" \
        "python${PYTHON_VERSION}-dev" \
        "python${PYTHON_VERSION}-venv" \
        python2

    log_success "Python ${PYTHON_VERSION}"
}

install_nginx() {
    log_info "Installing Nginx..."
    apt_install nginx
    log_success "Nginx"
}

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log_info "Docker Engine and Compose plugin already installed."
        return
    fi

    log_info "Installing Docker Engine and Docker Compose plugin..."

    apt_update
    apt_install ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt_update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    usermod -aG docker ubuntu

    log_success "Docker Engine and Docker Compose plugin installed."
}

setup_swap() {
    SWAP_SIZE="${SWAP_SIZE:-4G}"
    if [[ ! -f /swapfile ]]; then
        log_info "Creating ${SWAP_SIZE} swap file..."
        fallocate -l "$SWAP_SIZE" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log_success "Swap enabled (${SWAP_SIZE})"
    else
        log_info "Swap file already exists"
    fi
}

apply_system_tuning() {
    log_info "Applying system tuning..."

    if ! grep -q "^vm.max_map_count=262144" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    fi
    sysctl -w vm.max_map_count=262144 > /dev/null

    if ! grep -q "soft nofile 65536" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf <<EOF
* soft nofile 65536
* hard nofile 65536
EOF
    fi
}

disable_rsyslog() {
    # Disable rsyslog (superdesk uses its own logging)
    systemctl disable rsyslog 2>/dev/null || true
    systemctl stop rsyslog 2>/dev/null || true

    # Set locale
    locale-gen en_US.UTF-8 > /dev/null 2>&1 || true
}

show_summary() {
    echo ""
    log_success "System setup complete!"
    echo ""
    log_info "  Python:        $("python${PYTHON_VERSION}" --version 2>&1 || echo 'installed during deploy')"
    log_info "  Nginx:         $(nginx -v 2>&1)"
    echo ""
    log_info "Next: run services/cms.sh as the ubuntu user"
}

# ============================================================================
# Main
# ============================================================================

time_step "System packages"    install_system_packages
time_step "Python"             install_python
time_step "Nginx"              install_nginx
time_step "Install Docker"     install_docker
time_step "Swap"               setup_swap
time_step "System tuning"      apply_system_tuning
show_summary

if [[ "$TIMING" == "true" ]]; then
    total=$(( ${EPOCHSECONDS:-$(date +%s)} - DEPLOY_START ))
    echo -e "${CYAN}[TIME]${NC} Total: ${total}s"
fi
