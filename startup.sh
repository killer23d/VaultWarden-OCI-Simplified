#!/usr/bin/env bash
# startup.sh - Simplified VaultWarden stack orchestration
# Replaces: Complex startup with multiple libraries

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

# --- Load Configuration ---
load_config() {
    if [[ ! -f .env ]]; then
        log_error "Configuration file .env not found"
        log_info "Run ./setup.sh first to create configuration"
        return 1
    fi

    # Source .env file
    set -a  # Export all variables
    source .env
    set +a

    # Validate required variables
    [[ -n "${DOMAIN:-}" ]] || { log_error "DOMAIN not set in .env"; return 1; }
    [[ -n "${ADMIN_EMAIL:-}" ]] || { log_error "ADMIN_EMAIL not set in .env"; return 1; }

    log_info "Configuration loaded for domain: $DOMAIN"
    return 0
}

# --- Prepare Docker Secrets ---
prepare_docker_secrets() {
    log_info "Preparing Docker secrets..."

    local docker_secrets_dir="secrets/.docker_secrets"
    rm -rf "$docker_secrets_dir"
    mkdir -p "$docker_secrets_dir"

    # Check if SOPS is available and secrets are encrypted
    if command -v sops >/dev/null 2>&1 && [[ -f secrets/secrets.yaml ]]; then
        # Decrypt secrets and extract individual values
        local decrypted_secrets
        if ! decrypted_secrets=$(sops -d secrets/secrets.yaml 2>/dev/null); then
            log_error "Failed to decrypt secrets.yaml with SOPS"
            log_info "Make sure Age key exists and SOPS is properly configured"
            return 1
        fi

        # Extract secrets using simple parsing (assumes YAML format: key: value)
        echo "$decrypted_secrets" | grep -E "^[a-z_]+:" | while IFS=': ' read -r key value; do
            # Remove any quotes from value
            value=$(echo "$value" | sed 's/^["''']//;s/["''']$//')
            echo "$value" > "$docker_secrets_dir/$key"
            chmod 600 "$docker_secrets_dir/$key"
        done

        log_success "Docker secrets prepared from SOPS"
    else
        log_warn "SOPS not available or secrets.yaml not found"
        log_info "Creating placeholder secret files"

        # Create placeholder files so Docker doesn't fail
        for secret in admin_token smtp_password backup_passphrase; do
            echo "CHANGE_ME" > "$docker_secrets_dir/$secret"
            chmod 600 "$docker_secrets_dir/$secret"
        done

        log_warn "Using placeholder secrets - configure with ./edit-secrets.sh"
    fi

    return 0
}

# --- Ensure Log Directories ---
ensure_log_directories() {
    log_info "Ensuring log directories exist..."

    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local log_dirs=("$state_dir/logs/caddy" "$state_dir/logs/fail2ban" "$state_dir/logs/system")

    for dir in "${log_dirs[@]}"; do
        mkdir -p "$dir"
        chmod 755 "$dir"
    done

    return 0
}

# --- Docker Operations ---
stop_stack() {
    log_info "Stopping VaultWarden stack..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker compose down --remove-orphans"
        return 0
    fi

    if ! docker compose down --remove-orphans; then
        log_error "Failed to stop stack"
        return 1
    fi

    # Clean up Docker secrets
    rm -rf secrets/.docker_secrets

    log_success "Stack stopped successfully"
    return 0
}

start_stack() {
    log_info "Starting VaultWarden stack..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker compose up -d --remove-orphans"
        return 0
    fi

    local compose_cmd="docker compose up -d --remove-orphans"

    if [[ "$FORCE_RESTART" == "true" ]]; then
        compose_cmd="docker compose up -d --force-recreate --remove-orphans"
        log_info "Force recreating containers..."
    fi

    if ! $compose_cmd; then
        log_error "Failed to start stack"
        return 1
    fi

    log_success "Stack started successfully"
    return 0
}

# --- Health Check ---
post_startup_health_check() {
    if [[ "$SKIP_HEALTH" == "true" || "$DRY_RUN" == "true" ]]; then
        log_info "Skipping health check"
        return 0
    fi

    log_info "Performing post-startup health check..."

    # Wait for services to initialize
    sleep 10

    # Check if containers are running
    local failed_services=()
    local services=("vaultwarden" "caddy" "fail2ban")

    for service in "${services[@]}"; do
        if ! docker compose ps "$service" --status running >/dev/null 2>&1; then
            failed_services+=("$service")
        fi
    done

    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All services are running"

        # Test web connectivity if possible
        if command -v curl >/dev/null 2>&1 && [[ -n "${DOMAIN:-}" ]]; then
            log_info "Testing web connectivity..."
            if curl -sf --max-time 10 "https://$DOMAIN" >/dev/null 2>&1; then
                log_success "Web interface is responding"
            else
                log_warn "Web interface not yet responding (may need more time)"
            fi
        fi
    else
        log_error "Failed services: ${failed_services[*]}"
        log_info "Check logs: docker compose logs <service_name>"
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

    # Handle stop mode
    if [[ "$STOP_MODE" == "true" ]]; then
        stop_stack
        return $?
    fi

    # Normal startup flow
    load_config || exit 1
    ensure_log_directories || exit 1
    prepare_docker_secrets || exit 1

    # Force restart if requested
    if [[ "$FORCE_RESTART" == "true" ]]; then
        stop_stack || exit 1
        sleep 2
    fi

    start_stack || exit 1
    post_startup_health_check || log_warn "Health check failed, but stack is running"

    log_success "VaultWarden-OCI-NG startup completed"
    echo ""
    echo "Services started successfully!"
    echo "Web interface: https://$DOMAIN"
    echo "Admin panel: https://$DOMAIN/admin"
    echo ""
    echo "Useful commands:"
    echo "  ./health.sh          # Check system health"
    echo "  ./backup.sh          # Create backup"
    echo "  ./startup.sh --down  # Stop services"
}

main "$@"
