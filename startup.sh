#!/usr/bin/env bash
# startup.sh - Simplified VaultWarden stack orchestration
# Uses centralized library functions

set -euo pipefail
trap "rm -rf '$PROJECT_ROOT/secrets/.docker_secrets' 2>/dev/null" EXIT HUP INT TERM

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

    if [[ ! -f "secrets/secrets.yaml" ]]; then
        log_error "Secrets file not found: secrets/secrets.yaml"
        log_info "Run: ./edit-secrets.sh --init to create it"
        return 1
    fi

    if ! is_sops_encrypted "secrets/secrets.yaml"; then
        log_error "Secrets file is not encrypted with SOPS"
        return 1
    fi

    local secrets=("admin_token" "smtp_password" "push_installation_id" "push_installation_key" "admin_basic_auth_hash" "ddclient_api_token" "fail2ban_api_token")
    local secret_file_path

    for secret in "${secrets[@]}"; do
        local value
        secret_file_path="$docker_secrets_dir/$secret"
        if value=$(get_secret "$secret" 2>/dev/null) && [[ -n "$value" ]] && [[ "$value" != "CHANGE_ME"* ]]; then
            echo "$value" > "$secret_file_path"
            # --- P16 FIX: Added error handling ---
            secure_file "$secret_file_path" 600 || { log_error "Failed to secure temporary secret file: $secret"; return 1; }
        else
            echo "CHANGE_ME" > "$secret_file_path"
            # --- P16 FIX: Added error handling ---
            secure_file "$secret_file_path" 600 || { log_error "Failed to secure temporary secret file: $secret"; return 1; }
            log_warn "Secret '$secret' not configured or has placeholder value"
        fi
    done

    log_success "Docker secrets prepared"
    return 0
}

# --- Prepare Environment Variables ---
prepare_environment_variables() {
    log_info "Preparing environment variables for containers..."

    local admin_basic_auth_hash
    if admin_basic_auth_hash=$(get_secret "admin_basic_auth_hash" 2>/dev/null) && [[ -n "$admin_basic_auth_hash" ]] && [[ "$admin_basic_auth_hash" != "CHANGE_ME"* ]]; then
        export ADMIN_BASIC_AUTH_HASH="$admin_basic_auth_hash"
        log_success "Admin basic auth hash loaded"
    else
        log_warn "Admin basic auth hash not configured - admin panel protection disabled!"
        export ADMIN_BASIC_AUTH_HASH="" # Use empty string if not set, Caddy will ignore it
    fi

    local ddclient_token
    if ddclient_token=$(get_secret "ddclient_api_token" 2>/dev/null) && [[ -n "$ddclient_token" ]] && [[ "$ddclient_token" != "CHANGE_ME"* ]] && [[ "$ddclient_token" != "" ]]; then
        export DDCLIENT_API_TOKEN="$ddclient_token"
        log_success "DDClient API token loaded"
    else
        export DDCLIENT_API_TOKEN=""
        log_warn "DDClient API token not configured - Dynamic DNS updates might fail!"
    fi

    local fail2ban_token
    if fail2ban_token=$(get_secret "fail2ban_api_token" 2>/dev/null) && [[ -n "$fail2ban_token" ]] && [[ "$fail2ban_token" != "CHANGE_ME"* ]] && [[ "$fail2ban_token" != "" ]]; then
        export FAIL2BAN_API_TOKEN="$fail2ban_token"
        log_success "Fail2Ban/Caddy API token loaded"
    else
        export FAIL2BAN_API_TOKEN=""
        log_warn "Fail2Ban/Caddy API token not configured - Fail2Ban bans and Caddy ACME DNS challenge might fail!"
    fi

    log_success "Secrets exported to environment"
    return 0
}

# --- Post-Startup Health Check ---
post_startup_health_check() {
    if [[ "$SKIP_HEALTH" == "true" || "$DRY_RUN" == "true" ]]; then
        log_info "Skipping health check"
        return 0
    fi

    log_info "Performing post-startup health check..."
    log_info "Waiting 15s for services to initialize..."
    sleep 15

    local critical_services=("vaultwarden" "caddy")
    local failed_services=()

    for service in "${critical_services[@]}"; do
        if ! wait_for_service_ready "$service" 60; then
            failed_services+=("$service")
        fi
    done

    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All critical services are running and healthy"
        local domain
        domain=$(get_config_value "DOMAIN" "")
        if [[ -n "$domain" ]] && has_command curl; then
            log_info "Testing web connectivity..."
            local clean_domain
            clean_domain=$(echo "$domain" | sed 's|https\?://||; s|/.*$||')
            if test_http "https://$clean_domain" 15; then
                log_success "Web interface is responding"
            else
                log_warn "Web interface not yet responding (may need more time or check DNS/Firewall)"
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

    load_env_file || { log_error "Failed to load configuration"; exit 1; }
    require_config "DOMAIN" "ADMIN_EMAIL" || exit 1
    require_docker || exit 1

    if [[ "$STOP_MODE" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would stop all services"
        else
            stop_services
            rm -rf secrets/.docker_secrets 2>/dev/null || true
            log_success "Services stopped successfully"
        fi
        return 0
    fi

    ensure_dir "$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")/logs" 755 || exit 1
    prepare_docker_secrets || exit 1
    prepare_environment_variables || exit 1

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
            start_services
        fi
    fi

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
}

main "$@"

