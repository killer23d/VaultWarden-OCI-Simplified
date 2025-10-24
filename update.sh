#!/usr/bin/env bash
# update.sh - Simplified VaultWarden container and system updates with library integration
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
UPDATE_TYPE="containers"  # containers, system, all
AUTO_BACKUP=true
DRY_RUN=false
FORCE=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Update Tool

USAGE:
    ./update.sh [OPTIONS]

OPTIONS:
    --type TYPE        Update type: containers, system, all (default: containers)
    --no-backup       Skip automatic backup before update
    --dry-run         Show what would be updated without executing
    --force           Skip confirmation prompts
    --help            Show this help

UPDATE TYPES:
    containers    Update Docker containers only (safe, fast)
    system        Update system packages (requires reboot)
    all           Update both containers and system

NOTE:
    To upgrade container versions (e.g., Vaultwarden 1.30.5 -> 1.31.0),
    you must first edit the version tags in the .env file, then run this script.

EXAMPLES:
    ./update.sh                     # Update containers with backup
    ./update.sh --type system      # Update system packages
    ./update.sh --type all         # Full system update
    ./update.sh --no-backup        # Update without backup
    ./update.sh --dry-run          # Preview updates
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type) UPDATE_TYPE="$2"; shift 2 ;;
        --no-backup) AUTO_BACKUP=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Pre-Update Backup ---
create_backup() {
    if [[ "$AUTO_BACKUP" == "false" ]]; then
        log_info "Skipping backup (--no-backup specified)"
        return 0
    fi
    
    log_info "Creating pre-update backup..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create backup with: ./backup.sh --type full"
        return 0
    fi
    
    # Create full backup before updates
    if ./backup.sh --type full >/dev/null 2>&1; then
        log_success "Pre-update backup created"
        return 0
    else
        log_error "Failed to create pre-update backup"
        log_warn "Continue without backup? This is not recommended."
        
        if [[ "$FORCE" == "true" ]]; then
            log_warn "Continuing without backup (--force specified)"
            return 0
        fi
        
        read -p "Continue anyway? (y/N): " continue_choice
        if [[ "$continue_choice" =~ ^[Yy]$ ]]; then
            log_warn "Proceeding without backup"
            return 0
        else
            log_info "Update cancelled"
            exit 1
        fi
    fi
}

# --- Container Updates ---
update_containers() {
    log_info "Updating Docker containers..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would pull latest container images"
        log_info "[DRY RUN] Would restart containers with new images"
        return 0
    fi
    
    # Check Docker availability
    require_docker || return 1
    
    # Get list of services
    if ! validate_compose_file; then
        log_error "Docker Compose configuration is invalid"
        return 1
    fi
    
    local services
    services=$(docker compose config --services 2>/dev/null || echo "")
    
    if [[ -z "$services" ]]; then
        log_error "Could not determine services from docker-compose.yml"
        return 1
    fi
    
    # Check current container versions
    log_info "Current container versions:"
    for service in $services; do
        local image current_id
        image=$(docker compose config | grep -A 10 "$service:" | grep "image:" | awk '{print $2}' | head -1)
        current_id=$(docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}" | grep "$image" | awk '{print $2}' | head -1 || echo "unknown")
        log_info "  $service: $image ($current_id)"
    done
    
    echo ""
    
    # Pull latest images using library function
    log_info "Pulling latest container images..."
    if ! pull_images; then
        log_error "Failed to pull latest images"
        return 1
    fi
    
    # Check if any images were updated
    local updated_services=()
    for service in $services; do
        if has_image_updates "$service"; then
            updated_services+=("$service")
        fi
    done
    
    if [[ ${#updated_services[@]} -eq 0 ]]; then
        log_success "All containers are already up to date"
        return 0
    fi
    
    log_info "Services with updates available: ${updated_services[*]}"
    
    # Recreate containers with new images using library function
    log_info "Updating containers with new images..."
    if recreate_services; then
        log_success "Containers updated successfully"
        
        # Wait for services to stabilize
        log_info "Waiting for services to stabilize..."
        sleep 15
        
        # Check service health using library functions
        local failed_services=()
        for service in $services; do
            if ! wait_for_service_ready "$service" 30; then
                failed_services+=("$service")
            fi
        done
        
        if [[ ${#failed_services[@]} -eq 0 ]]; then
            log_success "All services are running after update"
        else
            log_error "Some services failed to start: ${failed_services[*]}"
            log_info "Check logs: docker compose logs <service_name>"
            return 1
        fi
        
    else
        log_error "Failed to update containers"
        return 1
    fi
    
    # Clean up old images using library function
    log_info "Cleaning up old Docker images..."
    if cleanup_images; then
        log_success "Old images cleaned up"
    else
        log_warn "Failed to clean up old images (non-critical)"
    fi
    
    return 0
}

# --- System Updates ---
update_system() {
    log_info "Updating system packages..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: apt update && apt upgrade"
        log_info "[DRY RUN] Would check if reboot is required"
        return 0
    fi
    
    # Check if running as root
    if ! is_root; then
        log_error "System updates require root privileges"
        log_info "Run with: sudo ./update.sh --type system"
        return 1
    fi
    
    # Update package lists
    log_info "Updating package lists..."
    if ! apt update; then
        log_error "Failed to update package lists"
        return 1
    fi
    
    # Check for available updates
    local update_count
    update_count=$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo "0")
    
    if [[ "$update_count" -eq 0 ]]; then
        log_success "System is already up to date"
        return 0
    fi
    
    log_info "Found $update_count package updates available"
    
    # Show available updates
    log_info "Available updates:"
    apt list --upgradable 2>/dev/null | grep upgradable | head -10
    
    if [[ "$update_count" -gt 10 ]]; then
        log_info "... and $((update_count - 10)) more packages"
    fi
    
    # Confirm system updates
    if [[ "$FORCE" == "false" ]]; then
        echo ""
        read -p "Proceed with system package updates? (y/N): " confirm_updates
        if [[ ! "$confirm_updates" =~ ^[Yy]$ ]]; then
            log_info "System updates cancelled"
            return 0
        fi
    fi
    
    # Perform updates
    log_info "Installing system updates..."
    export DEBIAN_FRONTEND=noninteractive
    
    if apt upgrade -y; then
        log_success "System packages updated successfully"
    else
        log_error "Failed to update some system packages"
        return 1
    fi
    
    # Check if reboot is required
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "⚠️  SYSTEM REBOOT REQUIRED"
        log_info "Some updates require a system reboot to take effect"
        
        if [[ -f /var/run/reboot-required.pkgs ]]; then
            log_info "Packages requiring reboot:"
            cat /var/run/reboot-required.pkgs | head -5
        fi
        
        echo ""
        log_warn "Schedule a system reboot when convenient:"
        log_info "  sudo reboot"
        
        return 2  # Special return code for reboot required
    else
        log_success "System update completed, no reboot required"
        return 0
    fi
}

# --- Health Check After Update ---
verify_system_health() {
    log_info "Verifying system health after update..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run health check: ./health.sh"
        return 0
    fi
    
    # Wait a moment for services to fully stabilize
    sleep 5
    
    # Run health check
    if ./health.sh --quiet; then
        log_success "Health check passed after update"
        return 0
    else
        log_warn "Health check detected issues after update"
        log_info "Run full health check: ./health.sh --comprehensive"
        return 1
    fi
}

# --- Update Notifications ---
send_update_notification() {
    local update_type="$1"
    local status="$2"  # success, failed, reboot_required
    
    # Simple notification (could be enhanced with SMTP if configured)
    local subject="VaultWarden Update: $update_type"
    local message=""
    
    case "$status" in
        "success")
            message="Update completed successfully on $(hostname -f 2>/dev/null || hostname)"
            ;;
        "failed")
            message="Update failed on $(hostname -f 2>/dev/null || hostname). Check system logs."
            ;;
        "reboot_required")
            message="Update completed but system reboot required on $(hostname -f 2>/dev/null || hostname)"
            ;;
    esac
    
    log_info "Update notification: $message"
    
    # Log to system log if available
    if has_command logger; then
        logger "VaultWarden Update [$status]: $message"
    fi
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Update Manager"
    
    # Load configuration
    load_env_file || {
        log_warn "No .env file found, using defaults"
    }
    
    local exit_code=0
    local reboot_required=false
    
    # Show update plan
    echo ""
    log_info "Update Plan:"
    case "$UPDATE_TYPE" in
        "containers")
            log_info "  - Update Docker containers"
            log_info "  - Verify service health"
            ;;
        "system")
            log_info "  - Update system packages"
            log_info "  - Check reboot requirements"
            ;;
        "all")
            log_info "  - Create backup"
            log_info "  - Update Docker containers"
            log_info "  - Update system packages"
            log_info "  - Verify service health"
            ;;
        *)
            log_error "Unknown update type: $UPDATE_TYPE"
            log_info "Valid types: containers, system, all"
            exit 1
            ;;
    esac
    
    if [[ "$AUTO_BACKUP" == "true" && "$UPDATE_TYPE" != "system" ]]; then
        log_info "  - Create pre-update backup"
    fi
    
    echo ""
    
    # Confirm update operation
    if [[ "$FORCE" == "false" && "$DRY_RUN" == "false" ]]; then
        read -p "Proceed with update? (Y/n): " confirm_proceed
        if [[ "$confirm_proceed" =~ ^[Nn]$ ]]; then
            log_info "Update cancelled"
            exit 0
        fi
    fi
    
    echo ""
    
    # Execute updates based on type
    case "$UPDATE_TYPE" in
        "containers")
            create_backup || exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                update_containers || exit_code=$?
            fi
            ;;
        "system")
            update_system
            case $? in
                0) ;;  # Success
                1) exit_code=1 ;;  # Failed
                2) reboot_required=true ;;  # Reboot required
            esac
            ;;
        "all")
            create_backup || exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                update_containers || exit_code=$?
            fi
            if [[ $exit_code -eq 0 ]]; then
                update_system
                case $? in
                    0) ;;  # Success
                    1) exit_code=1 ;;  # Failed
                    2) reboot_required=true ;;  # Reboot required
                esac
            fi
            ;;
    esac
    
    # Verify health if container updates were performed
    if [[ $exit_code -eq 0 && "$UPDATE_TYPE" != "system" ]]; then
        verify_system_health || log_warn "Post-update health check issues detected"
    fi
    
    # Send notification and summary
    echo ""
    if [[ $exit_code -eq 0 ]]; then
        if [[ "$reboot_required" == "true" ]]; then
            log_success "Update completed successfully - REBOOT REQUIRED"
            send_update_notification "$UPDATE_TYPE" "reboot_required"
        else
            log_success "Update completed successfully"
            send_update_notification "$UPDATE_TYPE" "success"
        fi
        
        echo ""
        echo "Update Summary:"
        echo "  Type: $UPDATE_TYPE"
        echo "  Status: Success"
        if [[ "$reboot_required" == "true" ]]; then
            echo "  Reboot: Required"
        fi
        echo "  Completed: $(date)"
        
    else
        log_error "Update failed"
        send_update_notification "$UPDATE_TYPE" "failed"
        
        echo ""
        echo "Update failed. Common troubleshooting:"
        echo "  - Check service logs: docker compose logs"
        echo "  - Verify system resources: ./health.sh"
        echo "  - Restore from backup if needed: ./restore.sh"
    fi
    
    exit $exit_code
}

main "$@"
