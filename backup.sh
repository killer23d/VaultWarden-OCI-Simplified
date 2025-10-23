#!/usr/bin/env bash
# backup.sh - Simplified VaultWarden backup creation
# Replaces: Complex backup monitoring and emergency kit creation

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

# --- Load Configuration ---
load_config() {
    if [[ ! -f .env ]]; then
        log_error "Configuration file .env not found"
        return 1
    fi

    set -a
    source .env
    set +a

    # Set defaults
    PROJECT_STATE_DIR="${PROJECT_STATE_DIR:-/var/lib/vaultwarden}"

    return 0
}

# --- Backup Functions ---
create_db_backup() {
    log_info "Creating database backup..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$PROJECT_ROOT/backups/db"
    local backup_file="vw-db-backup-$timestamp.sqlite3.gz"
    local encrypted_file="$backup_file.age"

    mkdir -p "$backup_dir"

    # Check if VaultWarden is running
    local vw_container
    vw_container=$(docker compose ps -q vaultwarden 2>/dev/null || echo "")

    if [[ -n "$vw_container" ]] && docker inspect "$vw_container" >/dev/null 2>&1; then
        # Backup from running container
        log_info "Backing up database from running container..."

        if ! docker exec "$vw_container" sqlite3 /data/db.sqlite3 ".backup /tmp/backup.db"; then
            log_error "Failed to create database backup inside container"
            return 1
        fi

        if ! docker cp "$vw_container:/tmp/backup.db" - | gzip > "$backup_dir/$backup_file"; then
            log_error "Failed to copy database backup from container"
            return 1
        fi

        # Cleanup temporary file in container
        docker exec "$vw_container" rm -f /tmp/backup.db 2>/dev/null || true

    else
        # Backup from filesystem (container stopped)
        local db_file="$PROJECT_STATE_DIR/data/bwdata/db.sqlite3"

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

    # Encrypt backup
    if ! encrypt_backup "$backup_dir/$backup_file" "$backup_dir/$encrypted_file"; then
        rm -f "$backup_dir/$backup_file"
        return 1
    fi

    # Remove unencrypted file
    rm -f "$backup_dir/$backup_file"

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

    mkdir -p "$backup_dir"

    # Create temporary directory for backup content
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT

    # Copy essential files
    log_info "Gathering configuration files..."
    cp docker-compose.yml "$temp_dir/" 2>/dev/null || log_warn "docker-compose.yml not found"
    cp .env "$temp_dir/" 2>/dev/null || log_warn ".env not found"
    cp -r caddy "$temp_dir/" 2>/dev/null || log_warn "caddy/ directory not found"
    cp -r fail2ban "$temp_dir/" 2>/dev/null || log_warn "fail2ban/ directory not found"
    cp -r secrets "$temp_dir/" 2>/dev/null || log_warn "secrets/ directory not found"

    # Copy data directory
    log_info "Including data directory..."
    if [[ -d "$PROJECT_STATE_DIR/data" ]]; then
        mkdir -p "$temp_dir/data"
        cp -r "$PROJECT_STATE_DIR/data"/* "$temp_dir/data/" 2>/dev/null || log_warn "Failed to copy some data files"
    fi

    # Create system info file
    cat > "$temp_dir/backup-info.txt" << EOF
VaultWarden-OCI-NG Full Backup
Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Host: $(hostname -f 2>/dev/null || hostname)
Domain: ${DOMAIN:-Not configured}
Admin Email: ${ADMIN_EMAIL:-Not configured}
EOF

    # Create compressed archive
    log_info "Creating compressed archive..."
    if ! tar -czf "$backup_dir/$backup_file" -C "$temp_dir" .; then
        log_error "Failed to create backup archive"
        return 1
    fi

    # Encrypt backup
    if ! encrypt_backup "$backup_dir/$backup_file" "$backup_dir/$encrypted_file"; then
        rm -f "$backup_dir/$backup_file"
        return 1
    fi

    # Remove unencrypted file
    rm -f "$backup_dir/$backup_file"

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

    mkdir -p "$backup_dir"

    # Create temporary directory
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT

    # Include everything needed for disaster recovery
    log_info "Preparing recovery files..."

    # Configuration and secrets
    cp docker-compose.yml "$temp_dir/" 2>/dev/null || { log_error "docker-compose.yml required"; return 1; }
    cp .env "$temp_dir/" 2>/dev/null || { log_error ".env required"; return 1; }
    cp -r caddy "$temp_dir/" 2>/dev/null || { log_error "caddy/ directory required"; return 1; }
    cp -r fail2ban "$temp_dir/" 2>/dev/null || log_warn "fail2ban/ directory not found"
    cp -r secrets "$temp_dir/" 2>/dev/null || { log_error "secrets/ directory required"; return 1; }

    # Data backup
    mkdir -p "$temp_dir/data"
    if [[ -d "$PROJECT_STATE_DIR/data" ]]; then
        cp -r "$PROJECT_STATE_DIR/data"/* "$temp_dir/data/" 2>/dev/null || log_warn "Some data files could not be copied"
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
    cat > "$temp_dir/kit-info.txt" << EOF
Emergency Kit Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Source Host: $(hostname -f 2>/dev/null || hostname)  
Domain: ${DOMAIN:-Not configured}
Kit Version: Simplified v1.0
EOF

    # Create encrypted kit
    log_info "Creating encrypted emergency kit..."
    if ! tar -czf "$backup_dir/$kit_file" -C "$temp_dir" .; then
        log_error "Failed to create emergency kit archive"
        return 1
    fi

    # Encrypt kit
    if ! encrypt_backup "$backup_dir/$kit_file" "$backup_dir/$encrypted_file"; then
        rm -f "$backup_dir/$kit_file"
        return 1
    fi

    # Remove unencrypted file
    rm -f "$backup_dir/$kit_file"

    log_success "Emergency kit created: $encrypted_file"
    log_warn "IMPORTANT: Store this kit and Age key separately and securely!"
    echo "$backup_dir/$encrypted_file"
    return 0
}

# --- Encryption Function ---
encrypt_backup() {
    local input_file="$1"
    local output_file="$2"

    local public_key_file="secrets/keys/age-public-key.txt"

    if [[ ! -f "$public_key_file" ]]; then
        log_error "Age public key not found: $public_key_file"
        log_info "Run ./setup.sh to generate keys"
        return 1
    fi

    local public_key
    public_key=$(cat "$public_key_file")

    log_info "Encrypting backup with Age..."
    if ! age -r "$public_key" -o "$output_file" "$input_file"; then
        log_error "Failed to encrypt backup"
        return 1
    fi

    # Set secure permissions
    chmod 600 "$output_file"

    return 0
}

# --- Email Function ---
email_backup() {
    local backup_file="$1"

    if [[ ! -f "$backup_file" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi

    # Simple email sending (requires configured SMTP)
    if [[ -z "${SMTP_HOST:-}" ]]; then
        log_warn "SMTP not configured, cannot email backup"
        log_info "Configure SMTP settings in secrets to enable email"
        return 1
    fi

    log_info "Emailing backup..."
    local subject="VaultWarden Backup - $(date '+%Y-%m-%d %H:%M')"
    local size
    size=$(du -h "$backup_file" | cut -f1)

    # Use simple mail command if available
    if command -v mail >/dev/null; then
        echo "VaultWarden backup created: $(basename "$backup_file") ($size)" |         mail -s "$subject" -A "$backup_file" "${ADMIN_EMAIL}"

        log_success "Backup emailed to ${ADMIN_EMAIL}"
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

    load_config || exit 1

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
