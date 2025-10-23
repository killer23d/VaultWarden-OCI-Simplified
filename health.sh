#!/usr/bin/env bash
# health.sh - Simplified VaultWarden health monitoring and auto-repair
# Replaces: Complex monitoring library with self-healing

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
COMPREHENSIVE=false
AUTO_HEAL=false
QUIET=false

# --- Health Tracking ---
WARNINGS=0
ERRORS=0

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Health Check

USAGE:
    ./health.sh [OPTIONS]

OPTIONS:
    --comprehensive  Run extended health checks
    --auto-heal      Automatically attempt to fix issues
    --quiet          Only show warnings and errors
    --help           Show this help

EXAMPLES:
    ./health.sh                    # Basic health check
    ./health.sh --comprehensive    # Full system health check
    ./health.sh --auto-heal        # Check health and auto-repair
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --comprehensive) COMPREHENSIVE=true; shift ;;
        --auto-heal) AUTO_HEAL=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Utility Functions ---
check_pass() {
    [[ "$QUIET" != "true" ]] && log_success "✅ $*"
}

check_warn() {
    log_warn "⚠️  $*"
    ((WARNINGS++))
}

check_fail() {
    log_error "❌ $*"
    ((ERRORS++))
}

# --- Load Configuration ---
load_config() {
    if [[ -f .env ]]; then
        set -a
        source .env
        set +a
        return 0
    else
        check_fail "Configuration file .env not found"
        return 1
    fi
}

# --- Docker Health Checks ---
check_docker_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking Docker health..."

    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        check_fail "Docker daemon not accessible"
        return 1
    fi
    check_pass "Docker daemon accessible"

    # Check Docker Compose
    if ! docker compose version >/dev/null 2>&1; then
        check_fail "Docker Compose not available"
        return 1
    fi
    check_pass "Docker Compose available"

    return 0
}

# --- Container Health Checks ---
check_container_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking container health..."

    local services=("vaultwarden" "caddy" "fail2ban")
    local unhealthy_services=()
    local stopped_services=()

    for service in "${services[@]}"; do
        local status
        status=$(docker compose ps "$service" --format json 2>/dev/null | jq -r '.State // "unknown"' 2>/dev/null || echo "unknown")

        case "$status" in
            "running")
                # Check health status if available
                local health
                health=$(docker compose ps "$service" --format json 2>/dev/null | jq -r '.Health // "none"' 2>/dev/null || echo "none")

                if [[ "$health" == "unhealthy" ]]; then
                    unhealthy_services+=("$service")
                    check_fail "$service is running but unhealthy"
                elif [[ "$health" == "starting" ]]; then
                    check_warn "$service is starting up"
                else
                    check_pass "$service is running and healthy"
                fi
                ;;
            "exited"|"dead")
                stopped_services+=("$service")
                check_fail "$service is stopped"
                ;;
            "unknown")
                stopped_services+=("$service")
                check_fail "$service status unknown (not found)"
                ;;
            *)
                check_warn "$service in unexpected state: $status"
                ;;
        esac
    done

    # Return status based on issues found
    if [[ ${#stopped_services[@]} -gt 0 ]]; then
        return 2  # Critical - services stopped
    elif [[ ${#unhealthy_services[@]} -gt 0 ]]; then
        return 1  # Warning - services unhealthy
    else
        return 0  # All good
    fi
}

# --- System Resource Checks ---
check_system_resources() {
    [[ "$QUIET" != "true" ]] && log_info "Checking system resources..."

    # Memory usage
    if command -v free >/dev/null; then
        local mem_percent
        mem_percent=$(free | awk '/^Mem:/ {printf "%.0f", ($3/$2)*100}')

        if [[ "$mem_percent" -lt 85 ]]; then
            check_pass "Memory usage: ${mem_percent}%"
        elif [[ "$mem_percent" -lt 95 ]]; then
            check_warn "Memory usage high: ${mem_percent}%"
        else
            check_fail "Memory usage critical: ${mem_percent}%"
        fi
    fi

    # Disk usage for project state directory
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    if [[ -d "$state_dir" ]]; then
        local disk_percent
        disk_percent=$(df -h "$state_dir" | awk 'NR==2{print $5}' | sed 's/%//')

        if [[ "$disk_percent" -lt 85 ]]; then
            check_pass "Disk usage: ${disk_percent}%"
        elif [[ "$disk_percent" -lt 95 ]]; then
            check_warn "Disk usage high: ${disk_percent}%"
        else
            check_fail "Disk usage critical: ${disk_percent}%"
        fi
    fi

    return 0
}

# --- Network Connectivity Checks ---
check_network_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking network connectivity..."

    # Internet connectivity
    if ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
        check_pass "Internet connectivity working"
    else
        check_fail "No internet connectivity"
        return 1
    fi

    # Domain connectivity (if configured)
    if [[ -n "${DOMAIN:-}" ]]; then
        local clean_domain
        clean_domain=$(echo "$DOMAIN" | sed 's|https\?://||; s|/.*$||')

        # DNS resolution
        if getent hosts "$clean_domain" >/dev/null 2>&1; then
            check_pass "DNS resolution for $clean_domain"
        else
            check_fail "DNS resolution failed for $clean_domain"
            return 1
        fi

        # HTTPS connectivity
        if command -v curl >/dev/null; then
            if curl -sf --max-time 10 "https://$clean_domain" >/dev/null 2>&1; then
                check_pass "HTTPS connectivity to $clean_domain"
            else
                check_warn "HTTPS connectivity failed to $clean_domain"
            fi
        fi
    fi

    return 0
}

# --- Backup Health Checks ---
check_backup_health() {
    [[ "$QUIET" != "true" ]] && log_info "Checking backup health..."

    local backup_dir="$PROJECT_ROOT/backups"

    # Check if backup directory exists
    if [[ ! -d "$backup_dir" ]]; then
        check_warn "Backup directory not found: $backup_dir"
        return 1
    fi

    # Check for recent backups
    local recent_backups
    recent_backups=$(find "$backup_dir" -name "*.age" -mtime -7 2>/dev/null | wc -l)

    if [[ "$recent_backups" -gt 0 ]]; then
        check_pass "Found $recent_backups recent backup(s)"
    else
        check_warn "No recent backups found (last 7 days)"
    fi

    return 0
}

# --- Auto-Healing Functions ---
auto_heal_containers() {
    log_info "Attempting to heal container issues..."

    # Try restarting unhealthy containers first
    local services=("vaultwarden" "caddy" "fail2ban")
    local restart_needed=()

    for service in "${services[@]}"; do
        local status health
        status=$(docker compose ps "$service" --format json 2>/dev/null | jq -r '.State // "unknown"' 2>/dev/null || echo "unknown")
        health=$(docker compose ps "$service" --format json 2>/dev/null | jq -r '.Health // "none"' 2>/dev/null || echo "none")

        if [[ "$status" != "running" || "$health" == "unhealthy" ]]; then
            restart_needed+=("$service")
        fi
    done

    if [[ ${#restart_needed[@]} -gt 0 ]]; then
        log_info "Restarting services: ${restart_needed[*]}"

        if docker compose restart "${restart_needed[@]}"; then
            log_success "Services restarted successfully"
            sleep 10  # Wait for services to initialize
            return 0
        else
            log_error "Failed to restart services"

            # If restart failed, try full recreate
            log_info "Attempting full service recreation..."
            if ./startup.sh --force-restart; then
                log_success "Services recreated successfully"
                return 0
            else
                log_error "Auto-healing failed"
                return 1
            fi
        fi
    else
        log_info "No container healing needed"
        return 0
    fi
}

# --- Main Health Check ---
run_health_checks() {
    log_info "Running VaultWarden health checks..."
    echo ""

    load_config || return 1

    # Core checks
    check_docker_health || return 1
    local container_status=0
    check_container_health || container_status=$?

    # Extended checks if requested
    if [[ "$COMPREHENSIVE" == "true" ]]; then
        check_system_resources
        check_network_health
        check_backup_health
    fi

    # Auto-heal if requested and issues found
    if [[ "$AUTO_HEAL" == "true" && "$container_status" -gt 0 ]]; then
        echo ""
        auto_heal_containers
        echo ""

        # Re-check container health after healing
        log_info "Re-checking container health after auto-heal..."
        check_container_health || container_status=$?
    fi

    return "$container_status"
}

# --- Main Execution ---
main() {
    local exit_code=0

    run_health_checks || exit_code=$?

    echo ""
    echo "Health Check Summary:"
    echo "  Warnings: $WARNINGS"
    echo "  Errors: $ERRORS"

    if [[ "$ERRORS" -eq 0 ]]; then
        if [[ "$WARNINGS" -eq 0 ]]; then
            log_success "All health checks passed ✅"
        else
            log_warn "Health check completed with $WARNINGS warning(s) ⚠️"
        fi
    else
        log_error "Health check failed with $ERRORS error(s) ❌"
        echo ""
        echo "Common fixes:"
        echo "  - Run: ./startup.sh --force-restart"
        echo "  - Check logs: docker compose logs <service>"
        echo "  - Restart system: sudo systemctl restart docker"
    fi

    exit "$exit_code"
}

main "$@"
