#!/usr/bin/env bash
# cron-setup.sh - Simplified cron job management with library integration
# Uses centralized library functions

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"

# --- Configuration ---
REMOVE_CRONS=false
DRY_RUN=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden Cron Job Setup

USAGE:
    sudo ./cron-setup.sh [OPTIONS]

OPTIONS:
    --remove     Remove existing VaultWarden cron jobs
    --dry-run    Show what would be done without executing
    --help       Show this help

DESCRIPTION:
    Sets up automated cron jobs for VaultWarden maintenance:
    - Daily database backups (2:00 AM)
    - Weekly full backups (Sunday 1:00 AM)
    - Daily health checks (every 6 hours)
    - Weekly container updates (Sunday 3:00 AM)

EXAMPLES:
    sudo ./cron-setup.sh           # Install cron jobs
    sudo ./cron-setup.sh --remove  # Remove cron jobs
    sudo ./cron-setup.sh --dry-run # Preview changes
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --remove) REMOVE_CRONS=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
validate_environment() {
    # Check if running as root using library function
    if ! is_root; then
        log_error "Cron setup requires root privileges"
        log_info "Run with: sudo ./cron-setup.sh"
        return 1
    fi

    # Check required commands using library function
    require_commands crontab || return 1

    # Ensure project scripts are executable
    local scripts=("backup.sh" "health.sh" "update.sh")
    for script in "${scripts[@]}"; do
        if [[ ! -x "$PROJECT_ROOT/$script" ]]; then
            log_warn "Making script executable: $script"
            chmod +x "$PROJECT_ROOT/$script"
        fi
    done

    return 0
}

# --- Cron Management ---
get_current_crontab() {
    # Get current crontab, handle case where no crontab exists
    crontab -l 2>/dev/null || echo ""
}

remove_vaultwarden_crons() {
    log_info "Removing VaultWarden cron jobs..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would remove VaultWarden cron jobs"
        return 0
    fi

    local current_crons temp_crons
    current_crons=$(get_current_crontab)

    if [[ -z "$current_crons" ]]; then
        log_info "No existing crontab found"
        return 0
    fi

    # Filter out VaultWarden-related cron jobs
    temp_crons=$(mktemp)
    setup_cleanup_trap "rm -f '$temp_crons'"

    echo "$current_crons" | grep -v "# VaultWarden-OCI-NG" | grep -v "$PROJECT_ROOT" > "$temp_crons" || true

    # Install filtered crontab
    if crontab "$temp_crons"; then
        log_success "VaultWarden cron jobs removed"
    else
        log_error "Failed to update crontab"
        return 1
    fi

    return 0
}

install_vaultwarden_crons() {
    log_info "Installing VaultWarden cron jobs..."

    # Get real user using library function
    local real_user
    real_user=$(get_real_user)

    # Define cron jobs
    local cron_jobs
    read -r -d '' cron_jobs << EOF || true
# VaultWarden-OCI-NG Automated Tasks
# Generated on $(date)

# Daily database backup at 2:00 AM
0 2 * * * $real_user cd $PROJECT_ROOT && ./backup.sh --type db >/dev/null 2>&1

# Weekly full backup on Sunday at 1:00 AM  
0 1 * * 0 $real_user cd $PROJECT_ROOT && ./backup.sh --type full >/dev/null 2>&1

# Health check every 6 hours with auto-heal
0 */6 * * * $real_user cd $PROJECT_ROOT && ./health.sh --auto-heal --quiet >/dev/null 2>&1

# Weekly container updates on Sunday at 3:00 AM
0 3 * * 0 $real_user cd $PROJECT_ROOT && ./update.sh --type containers --force >/dev/null 2>&1

# Monthly system updates on first Sunday at 4:00 AM
0 4 1-7 * 0 root cd $PROJECT_ROOT && ./update.sh --type system --force >/dev/null 2>&1

# --- FIX (H1): Add Cloudflare IP update cron job ---
# Weekly Cloudflare IP update on Monday at 5:00 AM (runs as root)
0 5 * * 1 root (cd $PROJECT_ROOT && CF_IPS_V4=\$(curl -sL https://www.cloudflare.com/ips-v4) && CF_IPS_V6=\$(curl -sL https://www.cloudflare.com/ips-v6) && echo -e "# Cloudflare IP ranges (auto-updated \$(date -uIs))\n@cloudflare {\n    # Cloudflare IPv4 ranges\n    remote_ip \$CF_IPS_V4\n    # Cloudflare IPv6 ranges\n    remote_ip \$CF_IPS_V6\n}" > caddy/cloudflare-ips.caddy.new && chown --reference=caddy/cloudflare-ips.caddy caddy/cloudflare-ips.caddy.new && mv caddy/cloudflare-ips.caddy.new caddy/cloudflare-ips.caddy && docker compose -f $PROJECT_ROOT/docker-compose.yml exec -T caddy caddy reload) >/dev/null 2>&1
# --- END FIX ---

EOF

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would install the following cron jobs:"
        echo "$cron_jobs"
        return 0
    fi

    # Get current crontab and append new jobs
    local current_crons temp_file
    current_crons=$(get_current_crontab)
    temp_file=$(mktemp)
    setup_cleanup_trap "rm -f '$temp_file'"

    # Remove any existing VaultWarden crons first
    if [[ -n "$current_crons" ]]; then
        echo "$current_crons" | grep -v "# VaultWarden-OCI-NG" | grep -v "$PROJECT_ROOT" > "$temp_file" || true
    fi

    # Add new cron jobs
    echo "" >> "$temp_file"
    echo "$cron_jobs" >> "$temp_file"

    # Install updated crontab
    if crontab "$temp_file"; then
        log_success "VaultWarden cron jobs installed"
    else
        log_error "Failed to install crontab"
        return 1
    fi

    # Verify cron service is running
    if systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1; then
        log_success "Cron service is running"
    else
        log_warn "Cron service may not be running"
        log_info "Start with: sudo systemctl start cron"
    fi

    return 0
}

show_current_crons() {
    log_info "Current VaultWarden-related cron jobs:"
    echo ""

    local current_crons
    current_crons=$(get_current_crontab)

    if [[ -z "$current_crons" ]]; then
        log_info "No crontab found"
        return 0
    fi

    # Show only VaultWarden-related crons
    local vw_crons
    vw_crons=$(echo "$current_crons" | grep -A 20 "# VaultWarden-OCI-NG" || echo "")

    if [[ -z "$vw_crons" ]]; then
        log_info "No VaultWarden cron jobs found"
    else
        echo "$vw_crons"
    fi

    echo ""
}

# --- Log Rotation Configuration ---
setup_log_rotation() {
    log_info "Setting up log rotation for VaultWarden..."

    local logrotate_conf="/etc/logrotate.d/vaultwarden"
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create logrotate configuration: $logrotate_conf"
        return 0
    fi

    # Create logrotate configuration
    local real_user
    real_user=$(get_real_user)

    cat > "$logrotate_conf" << EOF
# VaultWarden-OCI-NG Log Rotation
$state_dir/logs/*/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 $real_user $real_user
    postrotate
        # Send HUP signal to containers to reopen log files
        docker compose -f $PROJECT_ROOT/docker-compose.yml kill -s HUP caddy || true
    endscript
}

# Backup logs
$PROJECT_ROOT/backups/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

    log_success "Log rotation configured: $logrotate_conf"
    return 0
}

# --- Cron Service Management ---
ensure_cron_service() {
    log_info "Ensuring cron service is enabled and running..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would check and start cron service"
        return 0
    fi

    # Try both cron and crond service names
    local cron_service=""
    if systemctl list-unit-files | grep -q "^cron.service"; then
        cron_service="cron"
    elif systemctl list-unit-files | grep -q "^crond.service"; then
        cron_service="crond"
    else
        log_warn "Could not find cron service"
        return 1
    fi

    # Enable and start cron service
    if ! systemctl is-enabled "$cron_service" >/dev/null 2>&1; then
        log_info "Enabling cron service..."
        systemctl enable "$cron_service" || log_warn "Failed to enable cron service"
    fi

    if ! systemctl is-active "$cron_service" >/dev/null 2>&1; then
        log_info "Starting cron service..."
        systemctl start "$cron_service" || {
            log_error "Failed to start cron service"
            return 1
        }
    fi

    log_success "Cron service is running and enabled"
    return 0
}

# --- Configuration Validation ---
validate_scripts() {
    log_info "Validating automation scripts..."

    local scripts=("backup.sh" "health.sh" "update.sh")
    local missing_scripts=()
    local non_executable=()

    for script in "${scripts[@]}"; do
        if [[ ! -f "$PROJECT_ROOT/$script" ]]; then
            missing_scripts+=("$script")
        elif [[ ! -x "$PROJECT_ROOT/$script" ]]; then
            non_executable+=("$script")
        fi
    done

    if [[ ${#missing_scripts[@]} -gt 0 ]]; then
        log_error "Missing required scripts: ${missing_scripts[*]}"
        return 1
    fi

    if [[ ${#non_executable[@]} -gt 0 ]]; then
        log_warn "Making scripts executable: ${non_executable[*]}"
        if [[ "$DRY_RUN" != "true" ]]; then
            for script in "${non_executable[@]}"; do
                chmod +x "$PROJECT_ROOT/$script"
            done
        fi
    fi

    log_success "All automation scripts are available and executable"
    return 0
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Cron Setup"

    validate_environment || exit 1

    # Load configuration if available using library function
    load_env_file 2>/dev/null || log_warn "No .env file found, using defaults"

    if [[ "$REMOVE_CRONS" == "true" ]]; then
        remove_vaultwarden_crons || exit 1
    else
        show_current_crons

        # Validate scripts before installing crons
        validate_scripts || exit 1

        # Ask for confirmation unless dry run
        if [[ "$DRY_RUN" == "false" ]]; then
            echo ""
            read -p "Install/update VaultWarden cron jobs? (Y/n): " confirm
            if [[ "$confirm" =~ ^[Nn]$ ]]; then
                log_info "Cancelled"
                exit 0
            fi
        fi

        # Ensure cron service is running
        ensure_cron_service || log_warn "Cron service issues detected"

        # Install cron jobs
        install_vaultwarden_crons || exit 1

        # Setup log rotation
        setup_log_rotation || log_warn "Failed to setup log rotation (non-critical)"

        echo ""
        log_success "Cron setup completed!"
        echo ""
        echo "Scheduled Tasks:"
        echo "  • Daily DB backup: 2:00 AM"
        echo "  • Weekly full backup: Sunday 1:00 AM"  
        echo "  • Health check: Every 6 hours"
        echo "  • Container updates: Sunday 3:00 AM"
        echo "  • System updates: First Sunday 4:00 AM"
        echo "  • Cloudflare IP updates: Monday 5:00 AM"
        echo ""
        echo "Management Commands:"
        echo "  • View cron jobs: sudo crontab -l"
        echo "  • Check cron logs: sudo journalctl -u cron"
        echo "  • Manual health check: ./health.sh --comprehensive"
    fi
}

main "$@"
