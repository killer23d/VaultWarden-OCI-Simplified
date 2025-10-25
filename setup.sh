#!/usr/bin/env bash
# setup.sh - Complete VaultWarden-OCI-NG system setup with library integration

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
source "lib/docker.sh"
source "lib/crypto.sh"

# --- Configuration ---
DOMAIN=""
ADMIN_EMAIL=""
AUTO_MODE=false
SKIP_DEPS=false
FORCE=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Complete Setup

USAGE:
    sudo ./setup.sh [OPTIONS]

OPTIONS:
    --domain DOMAIN    Your domain (e.g., vault.example.com)
    --email EMAIL      Admin email address
    --auto            Automated setup with minimal prompts
    --skip-deps       Skip dependency installation
    --force           Overwrite existing configuration
    --help            Show this help

EXAMPLES:
    sudo ./setup.sh --domain vault.example.com --email admin@example.com --auto
    sudo ./setup.sh --domain vault.example.com --email admin@example.com
    sudo ./setup.sh --skip-deps  # Only configure, don't install packages

DESCRIPTION:
    Complete system setup including:
    - System dependencies (Docker, Age, SOPS, Rclone, Mailutils)
    - Firewall configuration
    - Age encryption keys
    - Environment configuration
    - Directory structure
    - Initial secrets template
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) ADMIN_EMAIL="$2"; shift 2 ;;
        --auto) AUTO_MODE=true; shift ;;
        --skip-deps) SKIP_DEPS=true; shift ;;
        --force) FORCE=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
validate_setup_environment() {
    # Check if running as root using library function
    if ! is_root; then
        log_error "Setup requires root privileges"
        log_info "Run with: sudo ./setup.sh"
        return 1
    fi

    # Validate domain format using library function
    if [[ -n "$DOMAIN" ]] && ! validate_domain "$DOMAIN"; then
        log_error "Invalid domain format: $DOMAIN"
        return 1
    fi

    # Validate email format using library function
    if [[ -n "$ADMIN_EMAIL" ]] && ! validate_email "$ADMIN_EMAIL"; then
        log_error "Invalid email format: $ADMIN_EMAIL"
        return 1
    fi

    return 0
}

# --- Interactive Setup ---
interactive_setup() {
    log_info "Interactive VaultWarden-OCI-NG Setup"
    echo ""

    # Get domain
    while [[ -z "$DOMAIN" ]]; do
        read -p "Enter your domain (e.g., vault.example.com): " DOMAIN
        if ! validate_domain "$DOMAIN"; then
            log_error "Invalid domain format. Please try again."
            DOMAIN=""
        fi
    done

    # Get admin email
    while [[ -z "$ADMIN_EMAIL" ]]; do
        read -p "Enter admin email address: " ADMIN_EMAIL
        if ! validate_email "$ADMIN_EMAIL"; then
            log_error "Invalid email format. Please try again."
            ADMIN_EMAIL=""
        fi
    done

    echo ""
    log_info "Configuration Summary:"
    echo "  Domain: $DOMAIN"
    echo "  Admin Email: $ADMIN_EMAIL"
    echo ""

    if [[ "$AUTO_MODE" != "true" ]]; then
        read -p "Continue with setup? (Y/n): " confirm_setup
        if [[ "$confirm_setup" =~ ^[Nn]$ ]]; then
            log_info "Setup cancelled"
            exit 0
        fi
    fi
}

# --- System Dependencies ---
install_dependencies() {
    if [[ "$SKIP_DEPS" == "true" ]]; then
        log_info "Skipping dependency installation (--skip-deps specified)"
        return 0
    fi

    log_info "Installing system dependencies..."

    # Update package lists
    log_info "Updating package lists..."
    apt update || {
        log_error "Failed to update package lists"
        return 1
    }

    # --- START P1/P2: Add rclone and mailutils ---
    # Required packages
    local packages=("docker.io" "docker-compose-plugin" "age" "sops" "ufw" "curl" "jq" "sqlite3" "gzip" "tar" "cron" "rclone" "mailutils")
    # --- END P1/P2 ---
    local missing_packages=()

    # Check which packages are missing
    for package in "${packages[@]}"; do
        if ! dpkg -l "$package" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_info "Installing missing packages: ${missing_packages[*]}"
        if ! apt install -y "${missing_packages[@]}"; then
            log_error "Failed to install some packages"
            return 1
        fi
        log_success "Dependencies installed successfully"
    else
        log_success "All required packages are already installed"
    fi

    # Enable and start services
    log_info "Configuring system services..."

    # Docker service
    systemctl enable docker || log_warn "Failed to enable Docker service"
    systemctl start docker || {
        log_error "Failed to start Docker service"
        return 1
    }

    # Cron service
    local cron_service="cron"
    if systemctl list-unit-files | grep -q "crond.service"; then
        cron_service="crond"
    fi

    systemctl enable "$cron_service" || log_warn "Failed to enable cron service"
    systemctl start "$cron_service" || log_warn "Failed to start cron service"

    # Add current user to docker group
    local real_user
    real_user=$(get_real_user)
    if [[ -n "$real_user" ]] && [[ "$real_user" != "root" ]]; then
        log_info "Adding user $real_user to docker group..."
        usermod -aG docker "$real_user" || log_warn "Failed to add user to docker group"
        log_info "Note: User $real_user needs to log out and back in for docker group to take effect"
    fi

    return 0
}

# --- Firewall Configuration ---
configure_firewall() {
    log_info "Configuring firewall..."

    # Check if ufw is available using library function
    if ! has_command ufw; then
        log_warn "UFW not available, skipping firewall configuration"
        return 0
    fi

    # Reset and configure UFW
    log_info "Configuring UFW firewall rules..."

    # Reset to defaults
    ufw --force reset >/dev/null 2>&1 || true

    # Default policies
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    # --- P7 FIX: Smart SSH Port Detection ---
    # Allow SSH (be careful not to lock ourselves out)
    # Priority: 1. $SSH_PORT env var, 2. sshd_config, 3. default 22
    local ssh_port="${SSH_PORT:-}"
    if [[ -z "$ssh_port" ]]; then
        # Grep for the 'Port' directive, ignore comments, get last value
        ssh_port=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -1)
    fi
    # Default to 22 if still empty
    ssh_port="${ssh_port:-22}"

    ufw allow "$ssh_port/tcp" comment "SSH" >/dev/null 2>&1
    log_success "SSH access allowed on port $ssh_port"
    # --- END P7 FIX ---

    # --- FIX: Web rules are now handled by update-cloudflare-ips.sh ---
    # We will call that script later in main() to populate web rules.
    # This function now ONLY handles the basics.

    # Enable UFW
    ufw --force enable >/dev/null 2>&1
    log_success "Firewall configured and enabled with SSH access"

    # Show status
    log_info "Firewall status (web rules will be added next):"
    ufw status numbered | head -20

    return 0
}

# --- Directory Structure ---
setup_directories() {
    log_info "Setting up directory structure..."

    local real_user
    real_user=$(get_real_user)
    local state_dir="/var/lib/vaultwarden"

    # --- P5 FIX: Get user's real GID ---
    local real_group
    real_group=$(id -g -n "$real_user")
    if [[ -z "$real_group" ]]; then
        real_group="$real_user"
    fi
    local owner="$real_user:$real_group"
    # --- END P5 FIX ---

    # Create main directories using library function
    ensure_dir "$state_dir" 755 "$owner"

    # Data directory with stricter permissions (addresses v4 review)
    ensure_dir "$state_dir/data" 700 "$owner"
    log_info "Data directory created with strict permissions (700)"

    ensure_dir "$state_dir/logs" 755 "$owner"
    ensure_dir "$state_dir/backups" 755 "$owner"
    ensure_dir "$state_dir/caddy" 755 "$owner"
    ensure_dir "$state_dir/caddy/data" 755 "$owner"
    ensure_dir "$state_dir/caddy/config" 755 "$owner"

    # Create log subdirectories
    ensure_dir "$state_dir/logs/caddy" 755 "$owner"
    ensure_dir "$state_dir/logs/vaultwarden" 755 "$owner"
    ensure_dir "$state_dir/logs/fail2ban" 755 "$owner"

    # Create project directories
    ensure_dir "$PROJECT_ROOT/secrets" 700 "$owner"
    ensure_dir "$PROJECT_ROOT/secrets/keys" 700 "$owner"
    ensure_dir "$PROJECT_ROOT/backups" 755 "$owner"
    ensure_dir "$PROJECT_ROOT/backups/db" 755 "$owner"
    ensure_dir "$PROJECT_ROOT/backups/full" 755 "$owner"
    ensure_dir "$PROJECT_ROOT/backups/emergency" 755 "$owner"

    # --- FIX: Ensure logs directory exists for cron output ---
    ensure_dir "$PROJECT_ROOT/logs" 755 "$owner"

    log_success "Directory structure created with appropriate permissions"
    return 0
}

# --- Age Keys Setup ---
setup_age_keys() {
    log_info "Setting up Age encryption keys..."

    local private_key_file="$PROJECT_ROOT/secrets/keys/age-key.txt"
    local public_key_file="$PROJECT_ROOT/secrets/keys/age-public-key.txt"

    # Check if keys already exist
    if check_age_key "$private_key_file"; then
        if [[ "$FORCE" == "true" ]]; then
            log_warn "Overwriting existing Age keys (--force specified)"
        else
            log_warn "Age keys already exist"
            read -p "Overwrite existing keys? This will make existing encrypted data inaccessible! (y/N): " overwrite_keys
            if [[ ! "$overwrite_keys" =~ ^[Yy]$ ]]; then
                log_info "Keeping existing Age keys"
                return 0
            fi
        fi
    fi

    # Generate new keys using library function
    if generate_age_keypair "$private_key_file" "$public_key_file"; then
        log_success "Age encryption keys generated"

        # Set ownership
        local real_user
        real_user=$(get_real_user)
        # --- P5 FIX: Get user's real GID ---
        local real_group
        real_group=$(id -g -n "$real_user")
        if [[ -z "$real_group" ]]; then
            real_group="$real_user"
        fi
        chown "$real_user:$real_group" "$private_key_file" "$public_key_file"
        # --- END P5 FIX ---

        # Show public key
        echo ""
        log_info "Age public key (for reference):"
        cat "$public_key_file"
        echo ""
        log_warn "IMPORTANT: Backup your Age private key securely!"
        log_info "Private key location: $private_key_file"
    else
        log_error "Failed to generate Age keys"
        return 1
    fi

    return 0
}

# --- SOPS Configuration ---
setup_sops_config() {
    log_info "Setting up SOPS configuration..."

    local sops_config="$PROJECT_ROOT/.sops.yaml"
    local public_key_file="$PROJECT_ROOT/secrets/keys/age-public-key.txt"

    if [[ ! -f "$public_key_file" ]]; then
        log_error "Age public key not found: $public_key_file"
        return 1
    fi

    local public_key
    public_key=$(cat "$public_key_file")

    # Create SOPS config
    cat > "$sops_config" << EOF
creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: '$public_key'
  - path_regex: secrets/.*\.yml$
    age: '$public_key'
EOF

    # Set ownership
    local real_user
    real_user=$(get_real_user)
    # --- P5 FIX: Get user's real GID ---
    local real_group
    real_group=$(id -g -n "$real_user")
    if [[ -z "$real_group" ]]; then
        real_group="$real_user"
    fi
    chown "$real_user:$real_group" "$sops_config"
    # --- END P5 FIX ---

    log_success "SOPS configuration created"
    return 0
}

# --- Environment Configuration ---
setup_environment() {
    log_info "Creating environment configuration..."

    local env_file="$PROJECT_ROOT/.env"
    local state_dir="/var/lib/vaultwarden"
    # --- P5 FIX: Get real user and group IDs ---
    local real_user
    real_user=$(get_real_user)
    local real_uid
    real_uid=$(id -u "$real_user")
    local real_gid
    real_gid=$(id -g "$real_user")
    # --- END P5 FIX ---


    # Check if .env already exists
    if [[ -f "$env_file" ]]; then
        if [[ "$FORCE" == "true" ]]; then
            log_warn "Overwriting existing .env file (--force specified)"
        else
            log_warn ".env file already exists"
            read -p "Overwrite existing configuration? (y/N): " overwrite_env
            if [[ ! "$overwrite_env" =~ ^[Nn]$ ]]; then
                log_info "Keeping existing .env file"
                return 0
            fi
        fi
    fi

    # Create .env file with explicit version definitions (addresses v4 review)
    cat > "$env_file" << EOF
# VaultWarden-OCI-NG Configuration
# Generated on $(date)

# Domain Configuration
DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL

# Project Configuration
PROJECT_NAME=vaultwarden-oci
PROJECT_STATE_DIR=$state_dir
COMPOSE_PROJECT_NAME=vaultwarden

# --- P5 FIX: Add PUID/PGID ---
# User/Group IDs for container permissions
# Set automatically to match the user who ran setup.sh
PUID=$real_uid
PGID=$real_gid
# --- END P5 FIX ---

# --- P7 NOTE: Add SSH_PORT ---
# Custom SSH port (if not 22)
# IMPORTANT: If you use a custom SSH port, set it here to prevent
# the automated firewall from locking you out.
# SSH_PORT=2222
# --- END P7 NOTE ---

# Container Versions (Single source of truth per v4 review)
VAULTWARDEN_VERSION=1.30.5
CADDY_VERSION=2.8.4
FAIL2BAN_VERSION=1.1.0
DDCLIENT_VERSION=3.11.2

# VaultWarden Configuration
VAULTWARDEN_DATA_FOLDER=$state_dir/data
VAULTWARDEN_LOG_LEVEL=info

# Caddy Configuration
CADDY_DATA_DIR=$state_dir/caddy
CADDY_CONFIG_DIR=$PROJECT_ROOT/caddy

# fail2ban Configuration
FAIL2BAN_CONFIG_DIR=$PROJECT_ROOT/fail2ban
FAIL2BAN_LOG_LEVEL=INFO

# Backup Configuration
BACKUP_RETENTION_DAYS=30
BACKUP_ENCRYPTION=age
# --- START P1: Add Rclone config ---
# Rclone remote name (configure with 'rclone config')
RCLONE_REMOTE_NAME=MyCloudStorage
# --- END P1 ---

# Network Configuration
DOCKER_NETWORK_NAME=vaultwarden_network

# Resource Limits (for small VMs)
VAULTWARDEN_MEMORY_LIMIT=1g
CADDY_MEMORY_LIMIT=128m
FAIL2BAN_MEMORY_LIMIT=64m

# --- Cloudflare & DDClient (REQUIRED) ---
# Find this on your Cloudflare dashboard (REQUIRED for fail2ban/ddclient)
CLOUDFLARE_ZONE_ID=CHANGE_ME
# The full domain name to update (e.g., $DOMAIN)
DDCLIENT_HOSTNAME=$DOMAIN

# Optional: SMTP Configuration (configure in secrets)
# SMTP_HOST=smtp.example.com
# SMTP_PORT=587
# SMTP_SECURITY=starttls
# SMTP_USERNAME=noreply@$DOMAIN

# Optional: Cloudflare Configuration (configure in secrets)
# CF_ZONE_API_TOKEN=<configure-in-secrets>
EOF

    # Set secure permissions using library function
    secure_file "$env_file" 600

    # Set ownership
    # --- P5 FIX: Use correct owner variables ---
    local real_group
    real_group=$(id -g -n "$real_user")
    if [[ -z "$real_group" ]]; then
        real_group="$real_user"
    fi
    chown "$real_user:$real_group" "$env_file"
    # --- END P5 FIX ---

    log_success "Environment configuration created with explicit version definitions"
    return 0
}

# --- Initial Secrets ---
setup_initial_secrets() {
    log_info "Setting up initial secrets..."

    local secrets_file="$PROJECT_ROOT/secrets/secrets.yaml"

    # Check if secrets already exist
    if [[ -f "$secrets_file" ]]; then
        if [[ "$FORCE" == "true" ]]; then
            log_warn "Overwriting existing secrets (--force specified)"
        else
            log_warn "Secrets file already exists"
            log_info "Use ./edit-secrets.sh to modify secrets"
            return 0
        fi
    fi

    # Generate initial secrets using library functions
    local admin_token backup_pass
    admin_token=$(generate_hex_string 32)
    backup_pass=$(generate_secure_string 32)

    # Create initial secrets file
    cat > "$secrets_file" << EOF
# VaultWarden-OCI-NG Secrets
# Generated on $(date)
# Edit with: ./edit-secrets.sh

# Admin token for VaultWarden admin panel
admin_token: $admin_token

# Basic auth hash for admin panel protection
# Generate with bcrypt generator: https://bcrypt-generator.com/
# This is used by Caddy for /admin protection
admin_basic_auth_hash: CHANGE_ME_BCRYPT_HASH

# SMTP configuration (if email notifications desired)
smtp_password: CHANGE_ME_SMTP_PASSWORD

# Backup encryption passphrase
backup_passphrase: $backup_pass

# Optional: Push notification key
push_installation_key: ""

# --- P1 CHANGE: Split Cloudflare token (from previous step) ---
# Cloudflare API token for DDNS (Permissions: Zone:DNS:Edit)
ddclient_api_token: CHANGE_ME_DDCLIENT_API_TOKEN

# Cloudflare API token for Fail2Ban/Caddy (Permissions: Zone:Firewall Services:Edit)
fail2ban_api_token: CHANGE_ME_FAIL2BAN_API_TOKEN
EOF

    # Encrypt secrets using library function
    if sops_encrypt "$secrets_file"; then
        log_success "Initial secrets created and encrypted"

        # Set ownership
        local real_user
        real_user=$(get_real_user)
        # --- P5 FIX: Get user's real GID ---
        local real_group
        real_group=$(id -g -n "$real_user")
        if [[ -z "$real_group" ]]; then
            real_group="$real_user"
        fi
        chown "$real_user:$real_group" "$secrets_file"
        # --- END P5 FIX ---


        log_warn "IMPORTANT: Update placeholder values in secrets:"
        log_info "  Run: ./edit-secrets.sh"
        log_info "  Update admin_basic_auth_hash with bcrypt hash"
        log_info "  Configure SMTP password if using email"
        # --- P1 CHANGE: Updated help text (from previous step) ---
        log_info "  Update ddclient_api_token (for dynamic DNS)"
        log_info "  Update fail2ban_api_token (for firewall bans)"
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    return 0
}

# --- Docker Compose Validation ---
validate_docker_setup() {
    log_info "Validating Docker setup..."

    # Check Docker daemon using library function
    if ! check_docker_available; then
        log_error "Docker daemon not accessible"
        log_info "Try: sudo systemctl restart docker"
        return 1
    fi

    # Check Docker Compose using library function
    if ! check_compose_available; then
        log_error "Docker Compose not available"
        return 1
    fi

    # Validate compose file using library function
    if [[ -f "$PROJECT_ROOT/docker-compose.yml" ]]; then
        if validate_compose_file "$PROJECT_ROOT/docker-compose.yml"; then
            log_success "Docker Compose configuration is valid"
        else
            log_error "Docker Compose configuration is invalid"
            return 1
        fi
    else
        log_warn "docker-compose.yml not found (will be needed for startup)"
    fi

    return 0
}

# --- Script Permissions ---
setup_script_permissions() {
    log_info "Setting up script permissions..."

    local scripts=("startup.sh" "health.sh" "backup.sh" "restore.sh" "edit-secrets.sh" 
                   "update.sh" "maintenance.sh" "cron-setup.sh" "update-cloudflare-ips.sh")
    local real_user
    real_user=$(get_real_user)
    # --- P5 FIX: Get user's real GID ---
    local real_group
    real_group=$(id -g -n "$real_user")
    if [[ -z "$real_group" ]]; then
        real_group="$real_user"
    fi
    local owner="$real_user:$real_group"
    # --- END P5 FIX ---

    for script in "${scripts[@]}"; do
        if [[ -f "$PROJECT_ROOT/$script" ]]; then
            chmod +x "$PROJECT_ROOT/$script"
            chown "$owner" "$PROJECT_ROOT/$script"
            log_success "Made $script executable"
        else
            log_warn "Script not found: $script"
        fi
    done

    # Make library files readable
    if [[ -d "$PROJECT_ROOT/lib" ]]; then
        chmod -R 644 "$PROJECT_ROOT/lib"/*.sh
        chmod +x "$PROJECT_ROOT/lib"  # Directory needs execute
        chown -R "$owner" "$PROJECT_ROOT/lib"
        log_success "Library permissions set"
    fi

    return 0
}

# --- Final Validation ---
run_final_validation() {
    log_info "Running final validation..."

    local validation_errors=0

    # Check Age key
    if check_age_key; then
        log_success "Age encryption key is accessible"
    else
        log_error "Age encryption key validation failed"
        ((validation_errors++))
    fi

    # Check SOPS config
    if [[ -f ".sops.yaml" ]]; then
        log_success "SOPS configuration exists"
    else
        log_error "SOPS configuration missing"
        ((validation_errors++))
    fi

    # Check environment file
    if [[ -f ".env" ]]; then
        log_success "Environment configuration exists"
    else
        log_error "Environment configuration missing"
        ((validation_errors++))
    fi

    # Check secrets
    local secrets_file="secrets/secrets.yaml"
    if [[ -f "$secrets_file" ]] && is_sops_encrypted "$secrets_file"; then
        log_success "Encrypted secrets file exists"
    else
        log_error "Secrets file missing or not encrypted"
        ((validation_errors++))
    fi

    # Test network connectivity using library function
    if test_connectivity; then
        log_success "Network connectivity available"
    else
        log_warn "Network connectivity issues detected"
    fi

    if [[ $validation_errors -eq 0 ]]; then
        log_success "All validation checks passed"
        return 0
    else
        log_error "$validation_errors validation errors found"
        return 1
    fi
}

# --- Main Execution ---
main() {
    log_header "VaultWarden-OCI-NG Complete Setup"

    validate_setup_environment || exit 1

    # Interactive setup if domain/email not provided
    if [[ -z "$DOMAIN" || -z "$ADMIN_EMAIL" ]]; then
        if [[ "$AUTO_MODE" == "true" ]]; then
            log_error "Auto mode requires --domain and --email"
            exit 1
        fi
        interactive_setup
    fi

    # Load any existing configuration
    load_env_file 2>/dev/null || log_info "No existing .env file found"

    echo ""
    log_info "Starting system setup..."

    # Execute setup steps
    install_dependencies || exit 1
    configure_firewall || exit 1
    setup_directories || exit 1
    setup_age_keys || exit 1
    setup_sops_config || exit 1
    setup_environment || exit 1
    setup_initial_secrets || exit 1
    validate_docker_setup || exit 1
    setup_script_permissions || exit 1
    
    # --- FIX: Run Cloudflare IP update script to populate web firewall rules ---
    log_info "Populating firewall rules for Cloudflare..."
    if ./update-cloudflare-ips.sh; then
        log_success "Firewall rules for Cloudflare IPs applied"
    else
        log_error "Failed to apply Cloudflare IP firewall rules"
        log_warn "Your firewall may be blocking web traffic. Run './update-cloudflare-ips.sh' manually."
    fi
    # --- END FIX ---

    echo ""
    log_info "Running final validation..."
    run_final_validation || {
        log_error "Setup completed with validation errors"
        exit 1
    }

    echo ""
    log_success "🎉 VaultWarden-OCI-NG setup completed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Update secrets: ./edit-secrets.sh"
    echo "     • CRITICAL: Set admin_basic_auth_hash for Caddy admin protection"
    echo "     • CRITICAL: Set ddclient_api_token (for DNS)"
    echo "     • CRITICAL: Set fail2ban_api_token (for firewall)"
    echo "     • Configure SMTP password if using email notifications"
    echo "  2. Review configuration: nano .env"
    echo "     • CRITICAL: Set CLOUDFLARE_ZONE_ID"
    echo "     • CRITICAL: Set RCLONE_REMOTE_NAME"
    echo "     • NOTE: Set SSH_PORT if you use a custom port"
    echo "  3. Configure Rclone: rclone config (for the user '$real_user')"
    echo "  4. Start services: ./startup.sh"
    echo "  5. Setup automation: sudo ./cron-setup.sh"
    echo "  6. Run health check: ./health.sh --comprehensive"
    echo ""
    echo "Your VaultWarden will be available at: https://$DOMAIN"
    echo "Admin panel: https://$DOMAIN/admin (protected by basic auth)"
    echo ""
    log_warn "IMPORTANT: The admin panel requires admin_basic_auth_hash to be configured!"
    log_warn "IMPORTANT: The stack requires CLOUDFLARE_ZONE_ID and API tokens to function!"
    log_warn "IMPORTANT: Offsite backup requires rclone to be configured and RCLONE_REMOTE_NAME to be set!"
    log_info "Setup completed in $(date)"
}

main "$@"

