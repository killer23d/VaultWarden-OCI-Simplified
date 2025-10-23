#!/usr/bin/env bash
# maintenance.sh - System maintenance and cleanup for VaultWarden-OCI-NG  
# Replaces: Complex host maintenance scripts

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# Source common library
source lib/common.sh
init_common_lib "$0"

# --- Configuration ---
DRY_RUN=false
FORCE=false
CLEANUP_TYPE="standard"  # standard, deep, docker

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden System Maintenance

USAGE:
    sudo ./maintenance.sh [OPTIONS]

OPTIONS:
    --type TYPE    Cleanup type: standard, deep, docker (default: standard)
    --force        Skip confirmation prompts
    --dry-run      Show what would be done without executing
    --help         Show this help

CLEANUP TYPES:
    standard    Log rotation, old backups, Docker cleanup
    deep        Standard + system cache, temp files, package cache
    docker      Docker-specific cleanup (images, volumes, networks)

EXAMPLES:
    sudo ./maintenance.sh              # Standard maintenance
    sudo ./maintenance.sh --type deep  # Deep system cleanup
    sudo ./maintenance.sh --type docker # Docker cleanup only
    sudo ./maintenance.sh --dry-run    # Preview actions
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type) CLEANUP_TYPE="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
validate_environment() {
    # Check if running as root for system operations
    if [[ "$CLEANUP_TYPE" != "docker" ]] && ! is_root; then
        log_error "System maintenance requires root privileges"
        log_info "Run with: sudo ./maintenance.sh"
        return 1
    fi

    return 0
}

# --- Docker Cleanup ---
cleanup_docker() {
    log_info "Docker cleanup..."

    if ! check_docker; then
        log_warn "Docker not available, skipping Docker cleanup"
        return 0
    fi

    local freed_space=0

    # Clean up stopped containers
    log_info "Removing stopped containers..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local stopped_containers
        stopped_containers=$(docker ps -aq --filter "status=exited" | wc -l)
        log_info "[DRY RUN] Would remove $stopped_containers stopped containers"
    else
        local removed
        removed=$(docker container prune -f 2>/dev/null | grep -o "deleted [0-9]*" | grep -o "[0-9]*" || echo "0")
        log_success "Removed $removed stopped containers"
    fi

    # Clean up unused images
    log_info "Removing unused Docker images..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker image prune -f"
    else
        local image_cleanup
        image_cleanup=$(docker image prune -f 2>/dev/null || echo "")
        if [[ -n "$image_cleanup" ]]; then
            log_success "Docker images cleaned up"
        else
            log_info "No unused images to clean"
        fi
    fi

    # Clean up unused volumes (be careful - only truly unused ones)
    log_info "Checking for unused Docker volumes..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local unused_volumes
        unused_volumes=$(docker volume ls -qf dangling=true | wc -l)
        log_info "[DRY RUN] Found $unused_volumes unused volumes"
    else
        # Be very careful with volume cleanup - only remove truly dangling ones
        local volume_cleanup
        volume_cleanup=$(docker volume prune -f 2>/dev/null | grep -o "deleted [0-9]*" | grep -o "[0-9]*" || echo "0")
        if [[ "$volume_cleanup" -gt 0 ]]; then
            log_success "Removed $volume_cleanup unused volumes"
        else
            log_info "No unused volumes found"
        fi
    fi

    # Clean up unused networks
    log_info "Cleaning up unused Docker networks..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker network prune -f"
    else
        docker network prune -f >/dev/null 2>&1 || true
        log_success "Unused networks cleaned up"
    fi

    # Show Docker system disk usage
    log_info "Docker system disk usage:"
    if has_command docker; then
        docker system df 2>/dev/null || log_warn "Could not get Docker disk usage"
    fi

    return 0
}

# --- Log Cleanup ---
cleanup_logs() {
    log_info "Log file cleanup..."

    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    local log_dirs=("$state_dir/logs" "$PROJECT_ROOT/backups")

    for log_dir in "${log_dirs[@]}"; do
        if [[ ! -d "$log_dir" ]]; then
            continue
        fi

        log_info "Cleaning logs in: $log_dir"

        # Remove logs older than 30 days
        if [[ "$DRY_RUN" == "true" ]]; then
            local old_logs
            old_logs=$(find "$log_dir" -name "*.log" -type f -mtime +30 2>/dev/null | wc -l)
            log_info "[DRY RUN] Would remove $old_logs log files older than 30 days"
        else
            local removed_count=0
            while IFS= read -r -d '' log_file; do
                rm -f "$log_file"
                ((removed_count++))
            done < <(find "$log_dir" -name "*.log" -type f -mtime +30 -print0 2>/dev/null)

            if [[ $removed_count -gt 0 ]]; then
                log_success "Removed $removed_count old log files from $log_dir"
            fi
        fi

        # Compress logs older than 7 days
        if has_command gzip; then
            if [[ "$DRY_RUN" == "true" ]]; then
                local compress_logs
                compress_logs=$(find "$log_dir" -name "*.log" -type f -mtime +7 ! -name "*.gz" 2>/dev/null | wc -l)
                log_info "[DRY RUN] Would compress $compress_logs log files older than 7 days"
            else
                local compressed_count=0
                while IFS= read -r -d '' log_file; do
                    gzip "$log_file" && ((compressed_count++))
                done < <(find "$log_dir" -name "*.log" -type f -mtime +7 ! -name "*.gz" -print0 2>/dev/null)

                if [[ $compressed_count -gt 0 ]]; then
                    log_success "Compressed $compressed_count log files in $log_dir"
                fi
            fi
        fi
    done

    return 0
}

# --- Backup Cleanup ---
cleanup_backups() {
    log_info "Backup cleanup..."

    local backup_dir="$PROJECT_ROOT/backups"
    if [[ ! -d "$backup_dir" ]]; then
        log_info "No backup directory found, skipping backup cleanup"
        return 0
    fi

    # Define retention periods
    local db_retention_days=14
    local full_retention_days=28
    local emergency_retention_days=90

    # Clean up old database backups
    log_info "Cleaning database backups (retention: ${db_retention_days} days)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local old_db_backups
        old_db_backups=$(find "$backup_dir/db" -name "*.age" -mtime +${db_retention_days} 2>/dev/null | wc -l)
        log_info "[DRY RUN] Would remove $old_db_backups old database backups"
    else
        local removed_db=0
        while IFS= read -r -d '' backup_file; do
            rm -f "$backup_file"
            ((removed_db++))
        done < <(find "$backup_dir/db" -name "*.age" -mtime +${db_retention_days} -print0 2>/dev/null)

        if [[ $removed_db -gt 0 ]]; then
            log_success "Removed $removed_db old database backups"
        fi
    fi

    # Clean up old full backups
    log_info "Cleaning full backups (retention: ${full_retention_days} days)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local old_full_backups
        old_full_backups=$(find "$backup_dir/full" -name "*.age" -mtime +${full_retention_days} 2>/dev/null | wc -l)
        log_info "[DRY RUN] Would remove $old_full_backups old full backups"
    else
        local removed_full=0
        while IFS= read -r -d '' backup_file; do
            rm -f "$backup_file"
            ((removed_full++))
        done < <(find "$backup_dir/full" -name "*.age" -mtime +${full_retention_days} -print0 2>/dev/null)

        if [[ $removed_full -gt 0 ]]; then
            log_success "Removed $removed_full old full backups"
        fi
    fi

    # Clean up old emergency kits (keep longer)
    log_info "Cleaning emergency kits (retention: ${emergency_retention_days} days)..."
    if [[ "$DRY_RUN" == "true" ]]; then
        local old_emergency
        old_emergency=$(find "$backup_dir/emergency" -name "*.age" -mtime +${emergency_retention_days} 2>/dev/null | wc -l)
        log_info "[DRY RUN] Would remove $old_emergency old emergency kits"
    else
        local removed_emergency=0
        while IFS= read -r -d '' backup_file; do
            rm -f "$backup_file"
            ((removed_emergency++))
        done < <(find "$backup_dir/emergency" -name "*.age" -mtime +${emergency_retention_days} -print0 2>/dev/null)

        if [[ $removed_emergency -gt 0 ]]; then
            log_success "Removed $removed_emergency old emergency kits"
        fi
    fi

    return 0
}

# --- System Cleanup ---
cleanup_system() {
    log_info "System cleanup..."

    if ! is_root; then
        log_warn "Skipping system cleanup (requires root)"
        return 0
    fi

    # Clean package cache
    log_info "Cleaning package cache..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would run: apt autoclean && apt autoremove"
    else
        apt autoclean -y >/dev/null 2>&1 || true
        apt autoremove -y >/dev/null 2>&1 || true
        log_success "Package cache cleaned"
    fi

    # Clean temporary files
    local temp_dirs=("/tmp" "/var/tmp")
    for temp_dir in "${temp_dirs[@]}"; do
        if [[ ! -d "$temp_dir" ]]; then
            continue
        fi

        log_info "Cleaning old temporary files in: $temp_dir"
        if [[ "$DRY_RUN" == "true" ]]; then
            local temp_files
            temp_files=$(find "$temp_dir" -type f -mtime +7 2>/dev/null | wc -l)
            log_info "[DRY RUN] Would remove $temp_files temporary files older than 7 days"
        else
            local removed_temp=0
            while IFS= read -r -d '' temp_file; do
                rm -f "$temp_file" 2>/dev/null && ((removed_temp++))
            done < <(find "$temp_dir" -type f -mtime +7 -print0 2>/dev/null)

            if [[ $removed_temp -gt 0 ]]; then
                log_success "Removed $removed_temp temporary files from $temp_dir"
            fi
        fi
    done

    # Clean systemd journal logs (keep last 30 days)
    if has_command journalctl; then
        log_info "Cleaning systemd journal logs..."
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY RUN] Would run: journalctl --vacuum-time=30d"
        else
            journalctl --vacuum-time=30d >/dev/null 2>&1 || true
            log_success "Systemd journal logs cleaned"
        fi
    fi

    return 0
}

# --- Disk Usage Report ---
show_disk_usage() {
    log_info "Current disk usage report:"
    echo ""

    # System disk usage
    echo "System Disk Usage:"
    df -h / 2>/dev/null || echo "  Cannot determine root filesystem usage"

    # Project directory usage
    if [[ -d "$PROJECT_ROOT" ]]; then
        echo ""
        echo "Project Directory Usage:"
        du -sh "$PROJECT_ROOT" 2>/dev/null || echo "  Cannot determine project directory usage"
    fi

    # State directory usage
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -d "$state_dir" ]]; then
        echo ""
        echo "VaultWarden State Directory Usage:"
        du -sh "$state_dir" 2>/dev/null || echo "  Cannot determine state directory usage"

        # Break down by subdirectory
        local subdirs=("data" "logs" "backups")
        for subdir in "${subdirs[@]}"; do
            if [[ -d "$state_dir/$subdir" ]]; then
                local size
                size=$(du -sh "$state_dir/$subdir" 2>/dev/null | cut -f1)
                echo "  $subdir: $size"
            fi
        done
    fi

    # Docker usage
    if check_docker >/dev/null 2>&1; then
        echo ""
        echo "Docker System Usage:"
        docker system df 2>/dev/null || echo "  Cannot determine Docker usage"
    fi

    echo ""
}

# --- Main Execution ---
main() {
    log_header "VaultWarden System Maintenance"

    validate_environment || exit 1

    # Load configuration
    load_env_file 2>/dev/null || log_warn "No .env file found"

    # Show current disk usage
    show_disk_usage

    # Confirm maintenance operation
    if [[ "$FORCE" == "false" && "$DRY_RUN" == "false" ]]; then
        echo ""
        read -p "Proceed with $CLEANUP_TYPE maintenance? (Y/n): " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            log_info "Maintenance cancelled"
            exit 0
        fi
    fi

    echo ""
    log_info "Starting $CLEANUP_TYPE maintenance..."

    # Execute maintenance based on type
    case "$CLEANUP_TYPE" in
        "standard")
            cleanup_logs
            cleanup_backups  
            cleanup_docker
            ;;
        "deep")
            cleanup_logs
            cleanup_backups
            cleanup_docker
            cleanup_system
            ;;
        "docker")
            cleanup_docker
            ;;
        *)
            log_error "Unknown cleanup type: $CLEANUP_TYPE"
            log_info "Valid types: standard, deep, docker"
            exit 1
            ;;
    esac

    echo ""
    log_success "Maintenance completed!"

    # Show updated disk usage
    echo ""
    show_disk_usage

    echo ""
    log_info "Maintenance summary:"
    echo "  Type: $CLEANUP_TYPE"
    echo "  Completed: $(date)"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  Mode: Dry run (no changes made)"
    fi
}

main "$@"
