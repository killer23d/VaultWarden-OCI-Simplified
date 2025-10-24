#!/usr/bin/env bash
# backup.sh - Simplified VaultWarden backup creation with library integration
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
BACKUP_TYPE="db"  # db, full, or emergency
EMAIL_BACKUP=false
RETENTION_DAYS=30

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden-OCI-NG Backup Tool

USAGE:
    ./backup.sh [OPTIONS]

OPTIONS:
    --type TYPE      Backup type: db, full, or emergency (default: db)
    --email          Email backup file after creation
    --retention N    Keep backups for N days (default: 30)
    --help           Show this help

BACKUP TYPES:
    db         Database only (fast, daily use)
    full       Complete system backup (weekly use)
    emergency  Disaster recovery kit (manual use)

EXAMPLES:
    ./backup.sh                    # Quick database backup
    ./backup.sh --type full        # Full system backup  
    ./backup.sh --type emergency   # Create emergency kit
    ./backup.sh --email            # Backup and email result
EOF
}

# --- Argument Parsing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type) BACKUP_TYPE="$2"; shift 2 ;;
        --email) EMAIL_BACKUP=true; shift ;;
        --retention) RETENTION_DAYS="$2"; shift 2 ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Backup Functions ---
create_db_backup() {
    log_info "Creating database backup..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/db"
    local backup_file="vw-db-backup-$timestamp.sqlite3.gz"
    local encrypted_file="$backup_file.age"

    ensure_dir "$backup_dir" 755

    # Check if VaultWarden is running
    if is_service_running "vaultwarden"; then
        # Backup from running container
        log_info "Backing up database from running container..."

        if ! exec_in_service vaultwarden sqlite3 /data/db.sqlite3 ".backup /tmp/backup.db"; then
            log_error "Failed to create database backup inside container"
            return 1
        fi

        # --- START FIX (H2: Integrity Check) ---
        log_info "Verifying database backup integrity..."
        local integrity_check
        integrity_check=$(exec_in_service vaultwarden sqlite3 /tmp/backup.db "PRAGMA integrity_check;" 2>/dev/null)
        
        if [[ "$integrity_check" != "ok" ]]; then
            log_error "Database integrity check failed: $integrity_check"
            exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
            return 1
        fi
        log_success "Database integrity verified"
        # --- END FIX (H2) ---

        if ! docker compose exec vaultwarden cat /tmp/backup.db | gzip > "$backup_dir/$backup_file"; then
            log_error "Failed to copy database backup from container"
            return 1
        fi

        # Cleanup temporary file in container
        exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true

    else
        # Backup from filesystem (container stopped)
        local state_dir
        state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
        local db_file="$state_dir/data/bwdata/db.sqlite3"

        if [[ ! -f "$db_file" ]]; then
            log_error "Database file not found: $db_file"
            return 1
        fi

        log_info "Backing up database from filesystem..."
        if ! gzip -c "$db_file" > "$backup_dir/$backup_file"; then
            log_error "Failed to compress database file"
            return 1
        fi
    fi

    # Encrypt backup using library function
    if ! encrypt_file "$backup_dir/$backup_file" "$backup_dir/$encrypted_file"; then
        rm -f "$backup_dir/$backup_file"
        log_error "Failed to encrypt backup"
        return 1
    fi

    # Remove unencrypted file
    rm -f "$backup_dir/$backup_file"
    secure_file "$backup_dir/$encrypted_file" 600

    log_success "Database backup created: $encrypted_file"
    echo "$backup_dir/$encrypted_file"
    return 0
}

create_full_backup() {
    log_info "Creating full system backup..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/full"
    local backup_file="vw-full-backup-$timestamp.tar.gz"
    local encrypted_file="$backup_file.age"

    ensure_dir "$backup_dir" 755

    # Create temporary directory for backup content
    local temp_dir
    temp_dir=$(mktemp -d)
    setup_cleanup_trap "rm -rf '$temp_dir'"

    # Copy essential files
    log_info "Gathering configuration files..."
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "$temp_dir/" || log_warn "docker-compose.yml not found"
    [[ -f .env ]] && cp .env "$temp_dir/" || log_warn ".env not found"
    [[ -d caddy ]] && cp -r caddy "$temp_dir/" || log_warn "caddy/ directory not found"
    [[ -d fail2ban ]] && cp -r fail2ban "$temp_dir/" || log_warn "fail2ban/ directory not found"
    [[ -d secrets ]] && cp -r secrets "$temp_dir/" || log_warn "secrets/ directory not found"

    # --- START MODIFICATION (FIX C3: Full Backup) ---
    # Copy data directory
    log_info "Including data directory..."
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")

    # Create a safe database snapshot first
    local db_snapshot="$temp_dir/db.sqlite3.snapshot"
    log_info "Creating consistent database snapshot..."

    if is_service_running "vaultwarden"; then
        if ! exec_in_service vaultwarden sqlite3 /data/db.sqlite3 ".backup /tmp/backup.db"; then
            log_error "Failed to create database snapshot inside container"
            return 1
        fi
        
        # --- START FIX (H2: Integrity Check) ---
        log_info "Verifying database snapshot integrity..."
        local integrity_check
        integrity_check=$(exec_in_service vaultwarden sqlite3 /tmp/backup.db "PRAGMA integrity_check;" 2>/dev/null)
        if [[ "$integrity_check" != "ok" ]]; then
            log_error "Database integrity check failed: $integrity_check"
            exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
            return 1
        fi
        log_success "Database snapshot integrity verified"
        # --- END FIX (H2) ---
        
        if ! docker compose exec vaultwarden cat /tmp/backup.db > "$db_snapshot"; then
            log_error "Failed to copy database snapshot from container"
            return 1
        fi
        exec_in_service vaultwarden rm -f /tmp/backup.db 2>/dev/null || true
    else
        log_info "VaultWarden is not running, copying database file directly..."
        local db_file="$state_dir/data/bwdata/db.sqlite3"
        if [[ -f "$db_file" ]]; then
            cp "$db_file" "$db_snapshot"
        else
            log_warn "Database file not found, backup will not contain a database."
        fi
    fi

    if [[ -d "$state_dir/data" ]]; then
        log_info "Copying all data files..."
        # Copy the entire data directory
        cp -r "$state_dir/data" "$temp_dir/data"
        
        # Overwrite the (potentially live) copied DB with the safe snapshot
        if [[ -f "$db_snapshot" ]]; then
            mkdir -p "$temp_dir/data/bwdata"
            mv "$db_snapshot" "$temp_dir/data/bwdata/db.sqlite3"
            log_info "Replaced live DB with safe snapshot in backup."
        fi
    fi
    # --- END MODIFICATION ---

    # Create system info file
    local domain admin_email
    domain=$(get_config_value "DOMAIN" "Not configured")
    admin_email=$(get_config_value "ADMIN_EMAIL" "Not configured")

    cat > "$temp_dir/backup-info.txt" << EOF
VaultWarden-OCI-NG Full Backup
Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Host: $(hostname -f 2>/dev/null || hostname)
Domain: $domain
Admin Email: $admin_email
EOF

    # Create compressed archive
    log_info "Creating compressed archive..."
    if ! tar -czf "$backup_dir/$backup_file" -C "$temp_dir" .; then
        log_error "Failed to create backup archive"
        return 1
    fi

    # Encrypt backup using library function
    if ! encrypt_file "$backup_dir/$backup_file" "$backup_dir/$encrypted_file"; then
        rm -f "$backup_dir/$backup_file"
        log_error "Failed to encrypt backup"
        return 1
    fi

    # Remove unencrypted file
    rm -f "$backup_dir/$backup_file"
    secure_file "$backup_dir/$encrypted_file" 600

    log_success "Full backup created: $encrypted_file"
    echo "$backup_dir/$encrypted_file"
    return 0
}

create_emergency_kit() {
    log_info "Creating emergency recovery kit..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/emergency"
    local kit_file="emergency-kit-$timestamp.tar.gz"
    local encrypted_file="$kit_file.age"

    ensure_dir "$backup_dir" 755

    # Create temporary directory
    local temp_dir
    temp_dir=$(mktemp -d)
    setup_cleanup_trap "rm -rf '$temp_dir'"

    # Include everything needed for disaster recovery
    log_info "Preparing recovery files..."

    # Configuration and secrets
    [[ -f docker-compose.yml ]] && cp docker-compose.yml "$temp_dir/" || { log_error "docker-compose.yml required"; return 1; }
    [[ -f .env ]] && cp .env "$temp_dir/" || { log_error ".env required"; return 1; }
    [[ -d caddy ]] && cp -r caddy "$temp_dir/" || { log_error "caddy/ directory required"; return 1; }
    [[ -d fail2ban ]] && cp -r fail2ban "$temp_dir/" || log_warn "fail2ban/ directory not found"
    [[ -d secrets ]] && cp -r secrets "$temp_dir/" || { log_error "secrets/ directory required"; return 1; }

    # Data backup
    mkdir -p "$temp_dir/data"
    local state_dir
    state_dir=$(get_config_value "PROJECT_STATE_DIR" "/var/lib/vaultwarden")
    if [[ -d "$state_dir/data" ]]; then
        cp -r "$state_dir/data"/* "$temp_dir/data/" 2>/dev/null || log_warn "Some data files could not be copied"
    fi

    # Recovery documentation
    cat > "$temp_dir/RECOVERY.md" << 'EOF'
# VaultWarden Emergency Recovery

## Quick Recovery Steps
1. Set up new Ubuntu 24.04 server
2. Extract this kit: `age -d -i age-key.txt emergency-kit.tar.gz.age | tar -xzf -`
3. Install Docker: `sudo apt update && sudo apt install -y docker.io docker-compose-plugin`
4. Restore files to project directory
5. Start services: `docker compose up -d`

## Files Included
- docker-compose.yml - Container configuration
- .env - Environment variables  
- caddy/ - Reverse proxy configuration
- fail2ban/ - Security configuration
- secrets/ - Encrypted secrets (including Age keys)
- data/ - VaultWarden database and files

## Important Notes
- Keep Age private key (secrets/keys/age-key.txt) secure and backed up separately
- Update DNS to point domain to new server IP
- Verify firewall allows ports 80 and 443
- Check service health after startup: `docker compose ps`

Recovery Time: ~15-30 minutes with proper preparation
EOF

    # Create kit info
    local domain admin_email
    domain=$(get_config_value "DOMAIN" "Not configured")
    admin_email=$(get_config_value "ADMIN_EMAIL" "Not configured")

    cat > "$temp_dir/kit-info.txt" << EOF
Emergency Kit Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Source Host: $(hostname -f 2>/dev/null || hostname)  
Domain: $domain
Kit Version: Simplified v1.0
EOF

    # Create encrypted kit
    log_info "Creating encrypted emergency kit..."
    if ! tar -czf "$backup_dir/$kit_file" -C "$temp_dir" .; then
        log_error "Failed to create emergency kit archive"
        return 1
    fi

    # Encrypt kit using library function
    if ! encrypt_file "$backup_dir/$kit_file" "$backup_dir/$encrypted_file"; then
        rm -f "$backup_dir/$kit_file"
        log_error "Failed to encrypt emergency kit"
        return 1
    fi

    # Remove unencrypted file
    rm -f "$backup_dir/$kit_file"
    secure_file "$backup_dir/$encrypted_file" 600

    log_success "Emergency kit created: $encrypted_file"
    log_warn "IMPORTANT: Store this kit and Age key separately and securely!"
    echo "$backup_dir/$encrypted_file"
    return 0
}

# --- Email Function ---
email_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    # Check if SMTP is configured
    local smtp_host
    smtp_host=$(get_config_value "SMTP_HOST" "")
    if [[ -z "$smtp_host" ]]; then
        log_warn "SMTP not configured, cannot email backup"
        log_info "Configure SMTP settings in secrets to enable email"
        return 1
    fi

    log_info "Emailing backup..."
    local subject="VaultWarden Backup - $(date '+%Y-%m-%d %H:%M')"
    local admin_email
    admin_email=$(get_config_value "ADMIN_EMAIL")

    # Use simple mail command if available
    if has_command mail; then
        local size
        size=$(du -h "$backup_file" | cut -f1)
        echo "VaultWarden backup created: $(basename "$backup_file") ($size)" |         mail -s "$subject" -A "$backup_file" "$admin_email"

        log_success "Backup emailed to $admin_email"
    else
        log_warn "Mail command not available, cannot send email"
        log_info "Install mailutils package to enable email: sudo apt install mailutils"
    fi
}

# --- Cleanup Function ---
cleanup_old_backups() {
    log_info "Cleaning up old backups (retention: ${RETENTION_DAYS} days)..."

    local backup_base="$PROJECT_ROOT/backups"
    local cleaned=0

    if [[ -d "$backup_base" ]]; then
        # Find and remove old encrypted backup files
        while IFS= read -r -d '' old_file; do
            log_info "Removing old backup: $(basename "$old_file")"
            rm -f "$old_file"
            ((cleaned++))
        done < <(find "$backup_base" -name "*.age" -mtime +${RETENTION_DAYS} -print0 2>/dev/null)

        if [[ "$cleaned" -gt 0 ]]; then
            log_success "Cleaned up $cleaned old backup(s)"
        else
            log_info "No old backups to clean up"
        fi
    fi
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Backup Tool"

    # Load configuration
    load_env_file || {
        log_error "Failed to load configuration"
        exit 1
    }

    # Check required commands
    require_commands tar gzip age || exit 1

    # Check Age key availability
    if ! check_age_key; then
        log_error "Age encryption key not available"
        log_info "Run ./setup.sh to generate keys"
        exit 1
    fi

    local backup_file=""

    # Create backup based on type
    case "$BACKUP_TYPE" in
        "db")
            backup_file=$(create_db_backup) || exit 1
            ;;
        "full")
            backup_file=$(create_full_backup) || exit 1
            ;;
        "emergency")
            backup_file=$(create_emergency_kit) || exit 1
            ;;
        *)
            log_error "Unknown backup type: $BACKUP_TYPE"
            log_info "Valid types: db, full, emergency"
            exit 1
            ;;
    esac

    # Email if requested
    if [[ "$EMAIL_BACKUP" == "true" ]]; then
        email_backup "$backup_file"
    fi

    # Cleanup old backups
    cleanup_old_backups

    local file_size
    file_size=$(du -h "$backup_file" | cut -f1)

    log_success "Backup completed successfully!"
    echo ""
    echo "Backup Details:"
    echo "  Type: $BACKUP_TYPE"
    echo "  File: $backup_file"  
    echo "  Size: $file_size"
    echo ""
    echo "To restore:"
    echo "  age -d -i secrets/keys/age-key.txt '$backup_file' | tar -xzf -"
}

main "$@"
