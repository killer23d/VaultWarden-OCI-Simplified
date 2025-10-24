#!/usr/bin/env bash
# startup.sh - Simplified VaultWarden stack orchestration
# Uses centralized library functions

set -euo pipefail
trap "rm -rf '$PROJECT_ROOT/secrets/.docker_secrets' '$PROJECT_ROOT/.env.secrets' 2>/dev/null" EXIT HUP INT TERM

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
    --force-restart  Stop and recreate all containers (REQUIRED after secrets changes)
    --dry-run        Show what would be done without executing
    --skip-health    Skip post-startup health check
    --down           Stop and remove all containers

EXAMPLES:
    ./startup.sh                    # Normal startup
    ./startup.sh --force-restart    # Force recreate containers (use after edit-secrets.sh)
    ./startup.sh --down             # Stop all services

IMPORTANT:
    After editing secrets (./edit-secrets.sh), always use --force-restart to ensure
    environment variables are properly updated in containers.
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
    # --- FIX: Add push_installation_id ---
    local secrets=("admin_token" "smtp_password" "push_installation_id" "push_installation_key" "cloudflare_api_token")

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

# --- Prepare Environment Variables for Caddy ---
prepare_environment_variables() {
    log_info "Preparing environment variables for containers..."

    # Get admin basic auth hash for Caddy
    local admin_basic_auth_hash
    if admin_basic_auth_hash=$(get_secret "admin_basic_auth_hash" 2>/dev/null) && [[ -n "$admin_basic_auth_hash" ]] && [[ "$admin_basic_auth_hash" != "CHANGE_ME"* ]]; then
        export ADMIN_BASIC_AUTH_HASH="$admin_basic_auth_hash"
        log_success "Admin basic auth hash loaded"
    else
        log_warn "Admin basic auth hash not configured - admin panel will be accessible!"
        log_info "Configure with: ./edit-secrets.sh (update admin_basic_auth_hash)"
        export ADMIN_BASIC_AUTH_HASH="CHANGE_ME_BCRYPT_HASH"
    fi

    # Get Cloudflare API token if configured
    local cloudflare_token
    if cloudflare_token=$(get_secret "cloudflare_api_token" 2>/dev/null) && [[ -n "$cloudflare_token" ]] && [[ "$cloudflare_token" != "CHANGE_ME"* ]] && [[ "$cloudflare_token" != "" ]]; then
        export CLOUDFLARE_API_TOKEN="$cloudflare_token"
        log_success "Cloudflare API token loaded"
    else
        export CLOUDFLARE_API_TOKEN=""
        log_info "Cloudflare API token not configured (optional)"
    fi

    # Write to .env.secrets for docker-compose if needed
    # Note: This file isn't strictly necessary as variables are exported, but kept for clarity/debugging
    cat > .env.secrets << EOF
# Generated environment variables from secrets
# This file is created automatically by startup.sh
ADMIN_BASIC_AUTH_HASH=$ADMIN_BASIC_AUTH_HASH
CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
EOF

    secure_file .env.secrets 600
    log_success "Environment variables prepared"
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
    log_info "Waiting 15s for services to initialize..."
    sleep 15

    # Check critical services
    local critical_services=("vaultwarden" "caddy")
    local failed_services=()

    for service in "${critical_services[@]}"; do
        # Use longer timeout for health check
        if ! wait_for_service_ready "$service" 60; then
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

# --- Main Execution ---
main() {
    log_info "VaultWarden-OCI-NG Stack Management"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_warn "DRY RUN MODE - No changes will be made"
    fi

    # Load configuration
    load_env_file || {
        log_error "Failed to load configuration"
        exit 1
    }

    # Validate required configuration
    require_config "DOMAIN" "ADMIN_EMAIL" || exit 1

    # Check Docker availability
    require_docker || exit 1

    # Handle stop mode
    if [[ "$STOP_MODE" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would stop all services"
        else
            stop_services
            # Clean up temporary files
            rm -rf secrets/.docker_secrets .env.secrets 2>/dev/null || true
            log_success "Services stopped successfully"
        fi
        return 0
    fi

    # Normal startup flow
    ensure_dir "$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")/logs" 755 || exit 1
    prepare_docker_secrets || exit 1
    prepare_environment_variables || exit 1

    # Handle force restart or normal startup
    if [[ "$FORCE_RESTART" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would force restart all services"
        else
            log_info "Force restarting services (ensures environment variables are updated)..."
            stop_services
            sleep 2
            recreate_services
        fi
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would start services"
        else
            start_services
        fi
    fi

    # Post-startup validation
    post_startup_health_check || log_warn "Health check failed, but stack is running"

    local domain
    domain=$(get_config_value "DOMAIN")

    log_success "VaultWarden-OCI-NG startup completed"
    echo ""
    echo "Services started successfully!"
    echo "Web interface: https://$domain"
    echo "Admin panel: https://$domain/admin"
    echo ""
    echo "Useful commands:"
    echo "  ./health.sh          # Check system health"
    echo "  ./backup.sh          # Create backup"
    echo "  ./startup.sh --down  # Stop services"
    echo ""
    echo "IMPORTANT NOTES:"
    echo "  • After editing secrets, always use: ./startup.sh --force-restart"
    echo "  • This ensures environment variables are properly updated in containers"
}

main "$@"
