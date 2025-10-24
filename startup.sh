#!/usr/bin/env bash
# startup.sh - Simplified VaultWarden stack orchestration with Priority 3 fixes
# Uses centralized library functions

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
FORCE_RESTART=false
DRY_RUN=false
SKIP_HEALTH=false
STOP_MODE=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Startup Script

USAGE:
    ./startup.sh [OPTIONS]

OPTIONS:
    --help           Show this help
    --force-restart  Stop and recreate all containers
    --dry-run        Show what would be done without executing
    --skip-health    Skip post-startup health check
    --down           Stop and remove all containers

EXAMPLES:
    ./startup.sh                    # Normal startup
    ./startup.sh --force-restart    # Force recreate containers
    ./startup.sh --down             # Stop all services
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --help) show_help; exit 0 ;;
        --force-restart) FORCE_RESTART=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-health) SKIP_HEALTH=true; shift ;;
        --down) STOP_MODE=true; shift ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Prepare Docker Secrets ---
prepare_docker_secrets() {
    log_info "Preparing Docker secrets..."

    local docker_secrets_dir="secrets/.docker_secrets"
    rm -rf "$docker_secrets_dir"
    mkdir -p "$docker_secrets_dir"

    # Check if secrets file exists and is encrypted
    if [[ ! -f "secrets/secrets.yaml" ]]; then
        log_error "Secrets file not found: secrets/secrets.yaml"
        log_info "Run: ./edit-secrets.sh --init to create it"
        return 1
    fi

    if ! is_sops_encrypted "secrets/secrets.yaml"; then
        log_error "Secrets file is not encrypted with SOPS"
        return 1
    fi

    # Get all secrets and create individual files
    local secrets=("admin_token" "admin_basic_auth_hash" "smtp_password" "backup_passphrase" "push_installation_key" "cloudflare_api_token")

    for secret in "${secrets[@]}"; do
        local value
        if value=$(get_secret "$secret" 2>/dev/null) && [[ -n "$value" ]] && [[ "$value" != "CHANGE_ME"* ]]; then
            echo "$value" > "$docker_secrets_dir/$secret"
            secure_file "$docker_secrets_dir/$secret" 600
        else
            # Create placeholder for missing secrets so Docker doesn't fail
            echo "CHANGE_ME" > "$docker_secrets_dir/$secret"
            secure_file "$docker_secrets_dir/$secret" 600
            log_warn "Secret '$secret' not configured or has placeholder value"
        fi
    done

    log_success "Docker secrets prepared"
    return 0
}

# --- PRIORITY 3 FIX: Environment Variables Setup ---
prepare_environment_variables() {
    log_info "Preparing environment variables from secrets..."

    # Create temporary environment file for secrets-based variables
    local temp_env="$PROJECT_ROOT/.env.secrets"
    rm -f "$temp_env"

    # Get admin basic auth hash and set environment variable
    local admin_hash
    if admin_hash=$(get_secret "admin_basic_auth_hash" 2>/dev/null) && [[ -n "$admin_hash" ]] && [[ "$admin_hash" != "CHANGE_ME"* ]]; then
        echo "ADMIN_BASIC_AUTH_HASH=$admin_hash" >> "$temp_env"
        export ADMIN_BASIC_AUTH_HASH="$admin_hash"
        log_success "Admin basic auth hash configured for Caddy"
    else
        log_warn "Admin basic auth hash not configured - admin panel will be unprotected!"
        log_info "Run: ./edit-secrets.sh and configure admin_basic_auth_hash"
        echo "ADMIN_BASIC_AUTH_HASH=" >> "$temp_env"
    fi

    # Get Cloudflare API token and set environment variable  
    local cf_token
    if cf_token=$(get_secret "cloudflare_api_token" 2>/dev/null) && [[ -n "$cf_token" ]] && [[ "$cf_token" != "CHANGE_ME"* ]]; then
        echo "CLOUDFLARE_API_TOKEN=$cf_token" >> "$temp_env"
        export CLOUDFLARE_API_TOKEN="$cf_token"
        log_success "Cloudflare API token configured"
    else
        log_info "Cloudflare API token not configured (optional)"
        echo "CLOUDFLARE_API_TOKEN=" >> "$temp_env"
    fi

    # Get SMTP configuration from .env and secrets
    local smtp_host smtp_username smtp_port smtp_security
    smtp_host=$(get_config_value "SMTP_HOST" "")
    smtp_username=$(get_config_value "SMTP_USERNAME" "")
    smtp_port=$(get_config_value "SMTP_PORT" "587")
    smtp_security=$(get_config_value "SMTP_SECURITY" "starttls")

    if [[ -n "$smtp_host" ]]; then
        echo "SMTP_HOST=$smtp_host" >> "$temp_env"
        echo "SMTP_USERNAME=$smtp_username" >> "$temp_env"
        echo "SMTP_PORT=$smtp_port" >> "$temp_env"
        echo "SMTP_SECURITY=$smtp_security" >> "$temp_env"
        export SMTP_HOST="$smtp_host"
        export SMTP_USERNAME="$smtp_username"
        export SMTP_PORT="$smtp_port"
        export SMTP_SECURITY="$smtp_security"
        log_success "SMTP configuration loaded from .env"
    else
        log_info "SMTP not configured (email notifications disabled)"
    fi

    # Ensure critical environment variables are set from .env
    local domain admin_email
    domain=$(get_config_value "DOMAIN" "")
    admin_email=$(get_config_value "ADMIN_EMAIL" "")

    if [[ -n "$domain" ]]; then
        echo "DOMAIN=$domain" >> "$temp_env"
        export DOMAIN="$domain"
    fi

    if [[ -n "$admin_email" ]]; then
        echo "ADMIN_EMAIL=$admin_email" >> "$temp_env"
        export ADMIN_EMAIL="$admin_email"
    fi

    # Load the temporary environment file for Docker Compose
    if [[ -f "$temp_env" ]]; then
        set -a
        source "$temp_env"
        set +a
        secure_file "$temp_env" 600
        log_success "Environment variables prepared from secrets and configuration"
    fi

    return 0
}

# --- Post-Startup Health Check ---
post_startup_health_check() {
    if [[ "$SKIP_HEALTH" == "true" || "$DRY_RUN" == "true" ]]; then
        log_info "Skipping health check"
        return 0
    fi

    log_info "Performing post-startup health check..."

    # Wait for services to initialize
    sleep 10

    # Check critical services
    local critical_services=("vaultwarden" "caddy")
    local failed_services=()

    for service in "${critical_services[@]}"; do
        if ! wait_for_service_ready "$service" 30; then
            failed_services+=("$service")
        fi
    done

    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All services are running and healthy"

        # Test web connectivity if domain is configured
        local domain
        domain=$(get_config_value "DOMAIN" "")
        if [[ -n "$domain" ]] && has_command curl; then
            log_info "Testing web connectivity..."
            local clean_domain
            clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')

            if test_http "https://$clean_domain" 15; then
                log_success "Web interface is responding"
            else
                log_warn "Web interface not yet responding (may need more time)"
            fi
        fi
    else
        log_error "Failed services: ${failed_services[*]}"
        log_info "Check logs with: docker compose logs <service_name>"
        return 1
    fi

    return 0
}

# --- Configuration Validation ---
validate_configuration() {
    log_info "Validating configuration..."

    # Check critical configuration values
    local required_vars=("DOMAIN" "ADMIN_EMAIL")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [[ -z "$(get_config_value "$var")" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing required configuration: ${missing_vars[*]}"
        log_info "Update your .env file or run: ./setup.sh"
        return 1
    fi

    # Validate domain format
    local domain
    domain=$(get_config_value "DOMAIN")
    if ! validate_domain "$domain"; then
        log_error "Invalid domain format: $domain"
        return 1
    fi

    # Validate email format
    local admin_email
    admin_email=$(get_config_value "ADMIN_EMAIL")
    if ! validate_email "$admin_email"; then
        log_error "Invalid email format: $admin_email"
        return 1
    fi

    # Check if admin basic auth is configured
    local admin_hash
    if admin_hash=$(get_secret "admin_basic_auth_hash" 2>/dev/null) && [[ "$admin_hash" != "CHANGE_ME"* ]]; then
        log_success "Admin authentication configured"
    else
        log_warn "Admin panel authentication not configured!"
        log_warn "Run: ./edit-secrets.sh to configure admin_basic_auth_hash"
    fi

    log_success "Configuration validation completed"
    return 0
}

# --- Show Startup Summary ---
show_startup_summary() {
    local domain admin_email
    domain=$(get_config_value "DOMAIN")
    admin_email=$(get_config_value "ADMIN_EMAIL")

    echo ""
    log_success "🎉 VaultWarden-OCI-NG startup completed successfully!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  VaultWarden Access Information"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Web Vault:    https://$domain"
    echo "  🔧 Admin Panel:  https://$domain/admin"
    echo "  📧 Admin Email:  $admin_email"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📋 Management Commands:"
    echo "  ./health.sh                    # Check system health"
    echo "  ./health.sh --auto-heal        # Check and auto-repair issues"
    echo "  ./backup.sh                    # Create backup"
    echo "  ./startup.sh --down            # Stop all services"
    echo "  ./edit-secrets.sh              # Manage secrets"
    echo ""
    echo "📊 Service Status:"
    if check_docker_available; then
        docker compose ps --format "table {{.Service}}	{{.Status}}	{{.Ports}}" 2>/dev/null || echo "  Run: docker compose ps"
    fi
    echo ""
}

# --- Main Execution ---
main() {
    log_header "VaultWarden-OCI-NG Stack Management"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Load configuration
    load_env_file || {
        log_error "Failed to load configuration (.env file)"
        log_info "Run: ./setup.sh to create initial configuration"
        exit 1
    }

    # Validate configuration
    validate_configuration || exit 1

    # Check Docker availability
    require_docker || exit 1

    # Handle stop mode
    if [[ "$STOP_MODE" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would stop all services"
        else
            log_info "Stopping VaultWarden services..."
            stop_services
            # Clean up Docker secrets and temp env
            rm -rf secrets/.docker_secrets
            rm -f .env.secrets
            log_success "Services stopped successfully"
        fi
        return 0
    fi

    # Normal startup flow
    log_info "Starting VaultWarden-OCI-NG services..."

    # Ensure state directory exists
    ensure_dir "$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")/logs" 755 || exit 1

    # Prepare secrets and environment
    prepare_docker_secrets || exit 1
    prepare_environment_variables || exit 1  # PRIORITY 3 FIX

    # Handle force restart
    if [[ "$FORCE_RESTART" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would force restart all services"
        else
            log_info "Force restarting services..."
            stop_services
            sleep 2
            recreate_services
        fi
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would start services"
        else
            log_info "Starting services..."
            start_services
        fi
    fi

    # Post-startup validation
    post_startup_health_check || log_warn "Health check failed, but stack is running"

    # Show summary if not in dry run mode
    if [[ "$DRY_RUN" == "false" ]]; then
        show_startup_summary
    fi
}

main "$@"
