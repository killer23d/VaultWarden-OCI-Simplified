#!/usr/bin/env bash
# setup.sh - Simplified VaultWarden-OCI-NG deployment script
# Replaces: init-setup.sh, install-deps.sh, and complex initialization

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Simple Logging ---
log_info() { echo "[$(date '+%H:%M:%S')] [INFO] $*"; }
log_warn() { echo "[$(date '+%H:%M:%S')] [WARN] $*" >&2; }
log_error() { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; }
log_success() { echo "[$(date '+%H:%M:%S')] [SUCCESS] $*"; }

# --- Configuration ---
DOMAIN=""
EMAIL=""
AUTO_MODE=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Simple Setup

USAGE:
    sudo ./setup.sh --domain vault.example.com --email admin@example.com

OPTIONS:
    --domain DOMAIN     Your VaultWarden domain (required)
    --email EMAIL       Admin email for certificates (required)  
    --auto             Auto-install dependencies without prompts
    --help             Show this help

EXAMPLE:
    sudo ./setup.sh --domain vault.mydomain.com --email admin@mydomain.com --auto
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --auto) AUTO_MODE=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
validate_inputs() {
    [[ -n "$DOMAIN" ]] || { log_error "Domain is required (--domain)"; exit 1; }
    [[ -n "$EMAIL" ]] || { log_error "Email is required (--email)"; exit 1; }

    # Simple validation
    [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || {
        log_error "Invalid domain format: $DOMAIN"; exit 1;
    }
    [[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || {
        log_error "Invalid email format: $EMAIL"; exit 1;
    }

    # Check if running as root
    [[ $EUID -eq 0 ]] || {
        log_error "This script requires root privileges (use sudo)"; exit 1;
    }
}

# --- Install Dependencies ---
install_dependencies() {
    log_info "Installing system dependencies..."

    # Update system
    apt update -y

    # Install required packages
    local packages=(
        "docker.io" "docker-compose-plugin" "age" "curl" "jq" 
        "ufw" "fail2ban" "sqlite3" "openssl" "coreutils"
    )

    if [[ "$AUTO_MODE" == "true" ]]; then
        DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}"
    else
        apt install -y "${packages[@]}"
    fi

    # Add current user to docker group if not root-only setup
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
        log_info "Added $SUDO_USER to docker group (requires logout/login)"
    fi

    # Start and enable services
    systemctl enable --now docker
    systemctl enable --now fail2ban

    log_success "Dependencies installed successfully"
}

# --- Generate Age Keys ---
generate_age_keys() {
    log_info "Generating Age encryption keys..."

    local keys_dir="$PROJECT_ROOT/secrets/keys"
    mkdir -p "$keys_dir"

    if [[ ! -f "$keys_dir/age-key.txt" ]]; then
        # Generate new Age key pair
        age-keygen -o "$keys_dir/age-key.txt"
        chmod 600 "$keys_dir/age-key.txt"

        # Extract public key
        age-keygen -y "$keys_dir/age-key.txt" > "$keys_dir/age-public-key.txt"
        chmod 644 "$keys_dir/age-public-key.txt"

        log_success "Age keys generated"
    else
        log_info "Age keys already exist, skipping generation"
    fi
}

# --- Create Configuration Files ---
create_config_files() {
    log_info "Creating configuration files..."

    # Create .env file
    cat > .env << EOF
# VaultWarden-OCI-NG Configuration
DOMAIN=$DOMAIN
ADMIN_EMAIL=$EMAIL
COMPOSE_PROJECT_NAME=vaultwarden

# Container Settings
WEBSOCKET_ENABLED=true
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
LOG_LEVEL=warn
EXTENDED_LOGGING=true

# Paths
PROJECT_STATE_DIR=/var/lib/vaultwarden
TZ=UTC

# Resource Limits (for 1 OCPU, 6GB RAM)
VAULTWARDEN_MEMORY_LIMIT=2G
CADDY_MEMORY_LIMIT=512M
FAIL2BAN_MEMORY_LIMIT=256M

# SMTP (configure via secrets)
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=
SMTP_FROM=$EMAIL

# Optional Features (disabled by default)
PUSH_ENABLED=false
DDCLIENT_ENABLED=false
EOF

    # Create SOPS config
    local public_key
    public_key=$(cat secrets/keys/age-public-key.txt)

    cat > .sops.yaml << EOF
creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: $public_key
EOF

    # Create initial secrets file
    mkdir -p secrets
    cat > secrets/secrets.yaml << EOF
# VaultWarden Secrets (will be encrypted with SOPS)
admin_token: CHANGE_ME_$(openssl rand -hex 32)
admin_basic_auth_hash: CHANGE_ME_BCRYPT_HASH
smtp_password: CHANGE_ME_SMTP_PASSWORD
backup_passphrase: CHANGE_ME_$(openssl rand -base64 32)
EOF

    # Encrypt secrets file
    if command -v sops >/dev/null 2>&1; then
        sops --encrypt --in-place secrets/secrets.yaml
        log_success "Secrets file encrypted"
    else
        log_warn "SOPS not found, secrets file left unencrypted"
        log_warn "Install SOPS and encrypt manually: sops --encrypt --in-place secrets/secrets.yaml"
    fi

    chmod 600 .env secrets/secrets.yaml
    log_success "Configuration files created"
}

# --- Setup Firewall ---
setup_firewall() {
    log_info "Configuring firewall..."

    # Reset UFW to default state
    ufw --force reset

    # Default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH (current connection)
    ufw allow ssh

    # Allow HTTP/HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp

    # Enable firewall
    ufw --force enable

    log_success "Firewall configured"
}

# --- Setup System Directories ---
setup_directories() {
    log_info "Setting up system directories..."

    local state_dir="/var/lib/vaultwarden"

    # Create required directories
    mkdir -p "$state_dir"/{data/bwdata,logs/{caddy,fail2ban,system},backups/{db,full}}

    # Set ownership (assume SUDO_USER for non-root operations)
    local target_user="${SUDO_USER:-$USER}"
    if [[ "$target_user" != "root" ]]; then
        chown -R "$target_user":"$target_user" "$state_dir"
    fi

    # Set permissions
    chmod 755 "$state_dir"
    chmod 700 "$state_dir/data"

    log_success "System directories created"
}

# --- Main Execution ---
main() {
    log_info "Starting VaultWarden-OCI-NG setup..."

    validate_inputs
    install_dependencies
    generate_age_keys
    create_config_files
    setup_firewall
    setup_directories

    log_success "Setup completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Edit secrets: ./edit-secrets.sh"
    echo "2. Start services: ./startup.sh" 
    echo "3. Check health: ./health.sh"
    echo ""
    echo "Your VaultWarden will be available at: https://$DOMAIN"
}

main "$@"
