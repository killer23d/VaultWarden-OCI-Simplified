#!/usr/bin/env bash
# restore.sh - Simplified VaultWarden restore with library integration
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
RESTORE_TYPE="auto"  # auto, db, full, emergency
BACKUP_FILE=""
FORCE=false
DRY_RUN=false

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Restore Tool

USAGE:
    ./restore.sh [OPTIONS] [BACKUP_FILE]

OPTIONS:
    --type TYPE      Restore type: auto, db, full, emergency (default: auto)
    --force          Skip confirmation prompts
    --dry-run        Show what would be done without executing
    --help           Show this help

RESTORE TYPES:
    auto        Detect backup type automatically from filename
    db          Database restore only
    full        Full system restore
    emergency   Emergency kit restoration

EXAMPLES:
    ./restore.sh backup.tar.gz.age           # Auto-detect type
    ./restore.sh --type db db-backup.age     # Database restore
    ./restore.sh --force emergency-kit.age  # Force emergency restore
    ./restore.sh --dry-run backup.age       # Preview restore actions
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type) RESTORE_TYPE="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        --) shift; break ;;
        -*) log_error "Unknown option: $1"; show_help; exit 1 ;;
        *) BACKUP_FILE="$1"; shift ;;
    esac
done

# --- Validation ---
validate_environment() {
    # Check required commands
    require_commands age tar gzip chown || return 1 # Added chown for P13

    # Check Docker availability for container operations
    require_docker || return 1

    # Check Age key
    if ! check_age_key; then
        log_error "Age private key not available"
        log_info "Restore the Age key from your secure backup first"
        return 1
    fi

    # Check backup file
    if [[ -z "$BACKUP_FILE" ]]; then
        log_error "No backup file specified"
        log_info "Usage: $0 [options] <backup_file.age>"
        return 1
    fi

    if [[ ! -f "$BACKUP_FILE" ]]; then
        log_error "Backup file not found: $BACKUP_FILE"
        return 1
    fi

    return 0
}

# --- Auto-detect Backup Type ---
detect_backup_type() {
    local filename
    filename=$(basename "$BACKUP_FILE")

    case "$filename" in
        *emergency*|*kit*)
            echo "emergency"
            ;;
        *full*)
            echo "full"
            ;;
        *db*|*database*)
            echo "db"
            ;;
        *.sqlite3*)
            echo "db"
            ;;
        *)
            # Try to peek inside the encrypted file to determine type
            log_info "Attempting to auto-detect backup type..."
            local peek_content
            peek_content=$(decrypt_file "$BACKUP_FILE" | tar -tf - 2>/dev/null || echo "")

            if [[ -n "$peek_content" ]]; then
                 if echo "$peek_content" | grep -qE "(RECOVERY\.md|kit-info\.txt)"; then
                    echo "emergency"
                 elif echo "$peek_content" | grep -qE "(\.env|docker-compose\.yml)"; then
                     echo "full"
                 else
                     # Assume db if it doesn't look like full or emergency
                     echo "db"
                 fi
            else
                log_warn "Could not decrypt or read archive to detect type, assuming 'db'"
                echo "db"
            fi
            ;;
    esac
}

# --- Confirmation ---
confirm_restore() {
    local restore_type="$1"

    if [[ "$FORCE" == "true" || "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    echo ""
    log_warn "⚠️  DESTRUCTIVE OPERATION WARNING ⚠️"
    echo ""
    echo "Restore Details:"
    echo "  Type: $restore_type"
    echo "  File: $BACKUP_FILE"
    echo "  Size: $(du -h "$BACKUP_FILE" | cut -f1)"
    echo ""

    case "$restore_type" in
        "db")
            echo "This will:"
            echo "  - Stop VaultWarden service"
            echo "  - Replace the current database"
            echo "  - Restart VaultWarden service"
            echo ""
            echo "⚠️  All current vault data will be lost!"
            ;;
        "full")
            echo "This will:"
            echo "  - Stop all services"
            echo "  - Replace configuration files (.env, compose, secrets, caddy, fail2ban)"
            echo "  - Replace database and data directory"
            echo "  - Restart all services"
            echo ""
            echo "⚠️  All current configuration and data will be lost!"
            ;;
        "emergency")
            echo "This will:"
            echo "  - Stop all services"
            echo "  - Replace ALL configuration and data in project directory"
            echo "  - Overwrite secrets and Age keys"
            echo "  - Replace database and data directory"
            echo "  - Restart all services"
            echo ""
            echo "⚠️  Complete system replacement - all current data will be lost!"
            ;;
    esac

    echo ""
    read -p "Are you absolutely sure you want to continue? (type 'yes' to confirm): " confirmation

    if [[ "$confirmation" != "yes" ]]; then
        log_info "Restore cancelled by user"
        exit 0
    fi

    echo ""
    return 0
}

# --- Database Restore ---
restore_database() {
    log_info "Starting database restore..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would stop VaultWarden service"
        log_info "[DRY RUN] Would decrypt and restore database"
        log_info "[DRY RUN] Would restart VaultWarden service"
        return 0
    fi

    # Stop VaultWarden service using library function
    log_info "Stopping VaultWarden service..."
    stop_services "vaultwarden" || log_warn "VaultWarden may not have been running"

    # Backup current database
    local state_dir db_file db_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    db_dir="$state_dir/data/bwdata"
    db_file="$db_dir/db.sqlite3"

    if [[ -f "$db_file" ]]; then
        log_info "Backing up current database..."
        cp "$db_file" "$db_file.backup-$(date +%Y%m%d-%H%M%S)" || log_warn "Failed to backup current database"
    fi

    # Ensure database directory exists
    # --- P13 FIX: Get owner info ---
    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user") || real_group="$real_user"
    owner="$real_user:$real_group"
    ensure_dir "$db_dir" 700 "$owner" # Use 700 to match data dir permissions

    # Decrypt and restore database using library function
    log_info "Restoring database from backup..."
    if decrypt_file "$BACKUP_FILE" | gunzip > "$db_file"; then
        log_success "Database restored successfully"

        # Set proper permissions and ownership
        chown "$owner" "$db_file" || log_warn "Failed to set ownership on database file"
        secure_file "$db_file" 600 || { log_error "Failed to set database permissions"; return 1; } # P16 FIX + use 600

        # Start VaultWarden service using library function
        log_info "Starting VaultWarden service..."
        if start_services "vaultwarden"; then
            log_success "VaultWarden service started"

            # Wait and check health using library function
            if wait_for_service_ready "vaultwarden" 30; then
                log_success "Database restore completed successfully"
            else
                log_error "VaultWarden failed to start properly after restore"
                log_info "Check logs: docker compose logs vaultwarden"
                return 1
            fi
        else
            log_error "Failed to start VaultWarden service"
            return 1
        fi
    else
        log_error "Failed to decrypt or restore database"
        return 1
    fi

    return 0
}

# --- Full System Restore ---
restore_full_system() {
    log_info "Starting full system restore..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would stop all services"
        log_info "[DRY RUN] Would decrypt and restore all files"
        log_info "[DRY RUN] Would restart all services"
        return 0
    fi

    # --- P13 FIX: Get owner info ---
    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user") || real_group="$real_user"
    owner="$real_user:$real_group"

    # Stop all services using library function
    log_info "Stopping all services..."
    stop_services || log_warn "Services may not have been running"

    # Create temporary restore directory
    local temp_dir
    temp_dir=$(mktemp -d)
    setup_cleanup_trap "rm -rf '$temp_dir'"

    # Decrypt backup using library function
    log_info "Decrypting backup archive..."
    if ! decrypt_file "$BACKUP_FILE" | tar -xzf - -C "$temp_dir"; then
        log_error "Failed to decrypt or extract backup"
        return 1
    fi

    # Backup current configuration
    local backup_suffix="backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Backing up current configuration..."

    [[ -f .env ]] && cp .env ".env.$backup_suffix" || true
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "docker-compose.yml.$backup_suffix" || true
    [[ -d secrets ]] && cp -r secrets "secrets.$backup_suffix" || true

    # Restore configuration files from temp dir to project root
    log_info "Restoring configuration files..."
    if [[ -d "$temp_dir" ]]; then
        cp -a "$temp_dir"/* . 2>/dev/null || log_warn "Could not copy some config files"
    fi

    # Restore data directory
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -d "$temp_dir/data" ]]; then
        log_info "Restoring data directory to $state_dir/data..."
        ensure_dir "$state_dir" 755 "$owner" # Ensure state dir exists with correct owner

        # Backup existing data
        [[ -d "$state_dir/data" ]] && mv "$state_dir/data" "$state_dir/data.$backup_suffix" || true

        # Move restored data from temp dir (already in project root now) to state dir
        if [[ -d "./data" ]]; then
            mv "./data" "$state_dir/" || log_warn "Failed to move data directory"
        else
             log_warn "Restored data directory not found in project root"
        fi
    fi

    # --- P13 FIX: Set ownership recursively ---
    log_info "Setting ownership for restored files..."
    if ! chown -R "$owner" .; then
         log_warn "Failed to set ownership on some project files"
    fi
    if [[ -d "$state_dir/data" ]]; then
        if ! chown -R "$owner" "$state_dir/data"; then
             log_warn "Failed to set ownership on data directory"
        fi
    fi
    # --- END P13 FIX ---

    # Set secure permissions using library functions (after ownership)
    secure_file .env 600 || { log_error "Failed to secure .env"; return 1; }
    if [[ -f secrets/secrets.yaml ]]; then
        secure_file secrets/secrets.yaml 600 || { log_error "Failed to secure secrets.yaml"; return 1; }
    fi
    if [[ -f secrets/keys/age-key.txt ]]; then
        secure_file secrets/keys/age-key.txt 600 || { log_error "Failed to secure age-key.txt"; return 1; }
    fi
    # Ensure data directory has correct base permissions after potential overwrite
    if [[ -d "$state_dir/data" ]]; then
        chmod 700 "$state_dir/data" || log_warn "Failed to set permissions on data directory"
    fi

    # Start services using library function
    log_info "Starting services..."
    if start_services; then
        # Wait for services to be ready
        log_info "Waiting for services to initialize..."
        sleep 10

        local critical_services=("vaultwarden" "caddy")
        local failed_services=()

        for service in "${critical_services[@]}"; do
            if ! wait_for_service_ready "$service" 30; then
                failed_services+=("$service")
            fi
        done

        if [[ ${#failed_services[@]} -eq 0 ]]; then
            log_success "Full system restore completed successfully"
        else
            log_error "Some services failed to start: ${failed_services[*]}"
            log_info "Check logs and try: ./startup.sh --force-restart"
            return 1
        fi
    else
        log_error "Failed to start services after restore"
        log_info "Check configuration and try: ./startup.sh --force-restart"
        return 1
    fi

    return 0
}

# --- Emergency Kit Restore ---
restore_emergency_kit() {
    log_info "Starting emergency kit restore..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would perform complete system restoration from emergency kit"
        return 0
    fi

    # --- P13 FIX: Get owner info ---
    local real_user real_group owner
    real_user=$(get_real_user)
    real_group=$(id -g -n "$real_user") || real_group="$real_user"
    owner="$real_user:$real_group"

    # Create temporary restore directory
    local temp_dir
    temp_dir=$(mktemp -d)
    setup_cleanup_trap "rm -rf '$temp_dir'"

    # Decrypt emergency kit using library function
    log_info "Decrypting emergency kit..."
    if ! decrypt_file "$BACKUP_FILE" | tar -xzf - -C "$temp_dir"; then
        log_error "Failed to decrypt or extract emergency kit"
        return 1
    fi

    # Show recovery information if available
    if [[ -f "$temp_dir/RECOVERY.md" ]]; then
        log_info "Emergency kit recovery notes:"
        echo ""
        head -20 "$temp_dir/RECOVERY.md"
        echo ""
        log_info "Full recovery guide will be saved as: RECOVERY.md"
        cp "$temp_dir/RECOVERY.md" .
    fi

    if [[ -f "$temp_dir/kit-info.txt" ]]; then
        log_info "Emergency kit information:"
        cat "$temp_dir/kit-info.txt"
        echo ""
    fi

    # Stop all services using library function
    log_info "Stopping all services..."
    stop_services || true

    # Create emergency backup of current state
    local backup_suffix="emergency-backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating emergency backup of current state..."

    ensure_dir "emergency-backups/$backup_suffix" 755 "$owner" # Ensure owner is correct
    # Use cp -a to preserve permissions as much as possible during backup
    cp -a . "emergency-backups/$backup_suffix/" 2>/dev/null || log_warn "Could not fully back up current state"

    # Restore all components from temp dir to project root
    log_info "Restoring complete system from emergency kit..."
    if [[ -d "$temp_dir" ]]; then
        # Copy with -a preserves permissions from the archive, then we fix owner/group
        cp -a "$temp_dir"/* . 2>/dev/null || log_warn "Could not copy some files from kit"
    fi

    # Restore data directory separately
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -d "./data" ]]; then # Data was copied to project root first
        log_info "Moving restored data directory to $state_dir/data..."
        ensure_dir "$state_dir" 755 "$owner"
        rm -rf "$state_dir/data" 2>/dev/null || true # Remove old one if exists
        mv "./data" "$state_dir/" || log_warn "Failed to move data directory"
    fi

    # --- P13 FIX: Set ownership recursively ---
    log_info "Setting ownership for restored files..."
    if ! chown -R "$owner" .; then
         log_warn "Failed to set ownership on some project files"
    fi
    if [[ -d "$state_dir/data" ]]; then
        if ! chown -R "$owner" "$state_dir/data"; then
             log_warn "Failed to set ownership on data directory"
        fi
    fi
    # --- END P13 FIX ---

    # Set secure permissions using library functions (after ownership)
    secure_file .env 600 || { log_error "Failed to secure .env"; return 1; }
    if [[ -f secrets/secrets.yaml ]]; then
        secure_file secrets/secrets.yaml 600 || { log_error "Failed to secure secrets.yaml"; return 1; }
    fi
    if [[ -f secrets/keys/age-key.txt ]]; then
        secure_file secrets/keys/age-key.txt 600 || { log_error "Failed to secure age-key.txt"; return 1; }
    fi
    # Ensure data directory has correct base permissions after potential overwrite
    if [[ -d "$state_dir/data" ]]; then
        chmod 700 "$state_dir/data" || log_warn "Failed to set permissions on data directory"
    fi

    # Start services using library function
    log_info "Starting restored services..."
    if start_services; then
        log_info "Waiting for services to initialize..."
        sleep 15

        local critical_services=("vaultwarden" "caddy")
        local ready_services=0

        for service in "${critical_services[@]}"; do
            if wait_for_service_ready "$service" 45; then
                ((ready_services++))
            fi
        done

        if [[ $ready_services -eq ${#critical_services[@]} ]]; then
            log_success "Emergency kit restore completed successfully"
            echo ""
            log_info "System restored from emergency kit"
            log_info "Verify functionality and update DNS if needed"
        else
            log_error "Some services failed to start properly after emergency restore"
            return 1
        fi
    else
        log_error "Failed to start services after emergency restore"
        return 1
    fi

    return 0
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Restore Tool"

    validate_environment || exit 1

    # Detect restore type if auto
    if [[ "$RESTORE_TYPE" == "auto" ]]; then
        RESTORE_TYPE=$(detect_backup_type)
        log_info "Auto-detected backup type: $RESTORE_TYPE"
    fi

    # Confirm the restore operation
    confirm_restore "$RESTORE_TYPE"

    # Load configuration if available
    load_env_file 2>/dev/null || log_warn "No .env file found"

    # Perform restore based on type
    case "$RESTORE_TYPE" in
        "db")
            restore_database || exit 1
            ;;
        "full")
            restore_full_system || exit 1
            ;;
        "emergency")
            restore_emergency_kit || exit 1
            ;;
        *)
            log_error "Unknown restore type: $RESTORE_TYPE"
            log_info "Valid types: auto, db, full, emergency"
            exit 1
            ;;
    esac

    local domain
    domain=$(get_config_value "DOMAIN" "your-domain")

    echo ""
    log_success "Restore operation completed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify service health: ./health.sh"
    echo "  2. Test web access: https://$domain"
    echo "  3. Check admin panel access"
    echo "  4. Create new backup: ./backup.sh"
}

main "$@"
