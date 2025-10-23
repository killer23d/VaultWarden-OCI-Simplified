#!/usr/bin/env bash
# restore.sh - Simplified VaultWarden restore from backups
# Replaces: Complex backup recovery system

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

NOTES:
    - Services will be stopped during restore
    - Age private key must be available for decryption
    - Database restores require VaultWarden to be stopped
    - Full/emergency restores will overwrite existing configuration
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
    local missing=()
    for cmd in age tar gzip docker; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        return 1
    fi

    # Check Age key
    local age_key="secrets/keys/age-key.txt"
    if [[ ! -f "$age_key" ]]; then
        log_error "Age private key not found: $age_key"
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

            # Decrypt and check for common files
            if age -d -i secrets/keys/age-key.txt "$BACKUP_FILE" | tar -tf - 2>/dev/null | grep -q "docker-compose.yml\|RECOVERY.md"; then
                if age -d -i secrets/keys/age-key.txt "$BACKUP_FILE" | tar -tf - 2>/dev/null | grep -q "RECOVERY.md\|kit-info.txt"; then
                    echo "emergency"
                else
                    echo "full"
                fi
            else
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
            echo "  - Replace configuration files"
            echo "  - Replace database and data"
            echo "  - Restart all services"
            echo ""
            echo "⚠️  All current configuration and data will be lost!"
            ;;
        "emergency")
            echo "This will:"
            echo "  - Stop all services"
            echo "  - Replace ALL configuration and data"
            echo "  - Overwrite secrets and keys"
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

    # Stop VaultWarden service
    log_info "Stopping VaultWarden service..."
    docker compose stop vaultwarden || log_warn "Failed to stop VaultWarden (may not be running)"

    # Backup current database
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    local db_file="$state_dir/data/bwdata/db.sqlite3"

    if [[ -f "$db_file" ]]; then
        log_info "Backing up current database..."
        cp "$db_file" "$db_file.backup-$(date +%Y%m%d-%H%M%S)" || log_warn "Failed to backup current database"
    fi

    # Ensure database directory exists
    mkdir -p "$(dirname "$db_file")"

    # Decrypt and restore database
    log_info "Restoring database from backup..."
    if age -d -i secrets/keys/age-key.txt "$BACKUP_FILE" | gunzip > "$db_file"; then
        log_success "Database restored successfully"

        # Set proper permissions
        chmod 644 "$db_file"

        # Start VaultWarden service
        log_info "Starting VaultWarden service..."
        if docker compose start vaultwarden; then
            log_success "VaultWarden service started"

            # Wait and check health
            sleep 5
            if docker compose ps vaultwarden --status running >/dev/null 2>&1; then
                log_success "Database restore completed successfully"
            else
                log_error "VaultWarden failed to start after restore"
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

    # Stop all services
    log_info "Stopping all services..."
    docker compose down || log_warn "Failed to stop services (may not be running)"

    # Create temporary restore directory
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT

    # Decrypt backup
    log_info "Decrypting backup archive..."
    if ! age -d -i secrets/keys/age-key.txt "$BACKUP_FILE" | tar -xzf - -C "$temp_dir"; then
        log_error "Failed to decrypt or extract backup"
        return 1
    fi

    # Backup current configuration
    local backup_suffix="backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Backing up current configuration..."

    [[ -f .env ]] && cp .env ".env.$backup_suffix" || true
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "docker-compose.yml.$backup_suffix" || true
    [[ -d secrets ]] && cp -r secrets "secrets.$backup_suffix" || true

    # Restore configuration files
    log_info "Restoring configuration files..."

    [[ -f "$temp_dir/.env" ]] && cp "$temp_dir/.env" . || log_warn ".env not found in backup"
    [[ -f "$temp_dir/docker-compose.yml" ]] && cp "$temp_dir/docker-compose.yml" . || log_warn "docker-compose.yml not found in backup"
    [[ -d "$temp_dir/secrets" ]] && cp -r "$temp_dir/secrets" . || log_warn "secrets/ not found in backup"
    [[ -d "$temp_dir/caddy" ]] && cp -r "$temp_dir/caddy" . || log_warn "caddy/ not found in backup"
    [[ -d "$temp_dir/fail2ban" ]] && cp -r "$temp_dir/fail2ban" . || log_warn "fail2ban/ not found in backup"

    # Restore data directory
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    if [[ -d "$temp_dir/data" ]]; then
        log_info "Restoring data directory..."
        mkdir -p "$state_dir"

        # Backup existing data
        [[ -d "$state_dir/data" ]] && mv "$state_dir/data" "$state_dir/data.$backup_suffix" || true

        # Restore data
        cp -r "$temp_dir/data" "$state_dir/" || log_warn "Failed to restore some data files"
    fi

    # Set proper permissions
    chmod 600 .env 2>/dev/null || true
    chmod 600 secrets/secrets.yaml 2>/dev/null || true
    chmod 600 secrets/keys/age-key.txt 2>/dev/null || true

    # Start services
    log_info "Starting services..."
    if ./startup.sh; then
        log_success "Full system restore completed successfully"
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
        log_info "[DRY RUN] Would decrypt kit and restore all components"
        log_info "[DRY RUN] Would restart all services"
        return 0
    fi

    # Emergency restore is essentially the same as full restore
    # but with additional verification and documentation display

    # Create temporary restore directory
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT

    # Decrypt emergency kit
    log_info "Decrypting emergency kit..."
    if ! age -d -i secrets/keys/age-key.txt "$BACKUP_FILE" | tar -xzf - -C "$temp_dir"; then
        log_error "Failed to decrypt or extract emergency kit"
        return 1
    fi

    # Show recovery information if available
    if [[ -f "$temp_dir/RECOVERY.md" ]]; then
        log_info "Emergency kit recovery notes:"
        echo ""
        head -20 "$temp_dir/RECOVERY.md"
        echo ""
        log_info "Full recovery guide saved as: RECOVERY.md"
        cp "$temp_dir/RECOVERY.md" .
    fi

    if [[ -f "$temp_dir/kit-info.txt" ]]; then
        log_info "Emergency kit information:"
        cat "$temp_dir/kit-info.txt"
        echo ""
    fi

    # Perform full system restore using the same logic
    # Stop services and restore everything
    log_info "Stopping all services..."
    docker compose down || true

    # Backup current state
    local backup_suffix="emergency-backup-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating emergency backup of current state..."

    mkdir -p "emergency-backups/$backup_suffix"
    cp -r . "emergency-backups/$backup_suffix/" 2>/dev/null || true

    # Restore all components
    log_info "Restoring complete system from emergency kit..."

    # Configuration files
    [[ -f "$temp_dir/.env" ]] && cp "$temp_dir/.env" .
    [[ -f "$temp_dir/docker-compose.yml" ]] && cp "$temp_dir/docker-compose.yml" .
    [[ -d "$temp_dir/secrets" ]] && cp -r "$temp_dir/secrets" .
    [[ -d "$temp_dir/caddy" ]] && cp -r "$temp_dir/caddy" .
    [[ -d "$temp_dir/fail2ban" ]] && cp -r "$temp_dir/fail2ban" .

    # Data directory
    local state_dir="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"
    if [[ -d "$temp_dir/data" ]]; then
        mkdir -p "$state_dir"
        rm -rf "$state_dir/data" 2>/dev/null || true
        cp -r "$temp_dir/data" "$state_dir/"
    fi

    # Set permissions
    chmod 600 .env secrets/secrets.yaml secrets/keys/age-key.txt 2>/dev/null || true

    # Start services
    log_info "Starting restored services..."
    if ./startup.sh; then
        log_success "Emergency kit restore completed successfully"
        echo ""
        log_info "System restored from emergency kit"
        log_info "Verify functionality and update DNS if needed"
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
    if [[ -f .env ]]; then
        set -a
        source .env
        set +a
    fi

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

    echo ""
    log_success "Restore operation completed successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify service health: ./health.sh"
    echo "  2. Test web access: https://\${DOMAIN:-your-domain}"
    echo "  3. Check admin panel access"
    echo "  4. Create new backup: ./backup.sh"
}

main "$@"
