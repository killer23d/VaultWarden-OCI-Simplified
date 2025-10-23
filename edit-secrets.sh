#!/usr/bin/env bash
# edit-secrets.sh - Simplified secrets management with SOPS/Age
# Replaces: Complex secrets editing with validation

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
EDITOR="${EDITOR:-nano}"
SECRETS_FILE="secrets/secrets.yaml"
AGE_KEY_FILE="secrets/keys/age-key.txt"

# --- Help ---
show_help() {
    cat << 'EOF'
VaultWarden Secrets Editor

USAGE:
    ./edit-secrets.sh [OPTIONS]

OPTIONS:
    --editor EDITOR  Editor to use (default: nano, or $EDITOR)
    --init          Initialize secrets file with templates
    --show          Show decrypted secrets (careful!)
    --help          Show this help

DESCRIPTION:
    Safely edit encrypted secrets using SOPS and Age encryption.
    Secrets are automatically re-encrypted after editing.

EXAMPLES:
    ./edit-secrets.sh           # Edit secrets with default editor
    ./edit-secrets.sh --editor vim   # Use vim as editor
    ./edit-secrets.sh --init    # Create new secrets file from template
    ./edit-secrets.sh --show    # Display current secrets (be careful!)
EOF
}

# --- Argument Parsing ---
SHOW_MODE=false
INIT_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --editor) EDITOR="$2"; shift 2 ;;
        --init) INIT_MODE=true; shift ;;
        --show) SHOW_MODE=true; shift ;;
        --help) show_help; exit 0 ;;
        *) log_error "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- Validation ---
check_prerequisites() {
    # Check required commands
    local missing=()
    for cmd in age sops "$EDITOR"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Install with: sudo apt install age sops ${missing[*]}"
        return 1
    fi

    # Check Age key exists
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        log_error "Age private key not found: $AGE_KEY_FILE"
        log_info "Run ./setup.sh to generate keys"
        return 1
    fi

    # Check key permissions
    local perms
    perms=$(stat -c "%a" "$AGE_KEY_FILE" 2>/dev/null)
    if [[ "$perms" != "600" ]]; then
        log_warn "Age key has incorrect permissions ($perms), fixing..."
        chmod 600 "$AGE_KEY_FILE"
    fi

    return 0
}

# --- Initialize Secrets ---
init_secrets() {
    log_info "Initializing secrets file from template..."

    if [[ -f "$SECRETS_FILE" ]]; then
        log_warn "Secrets file already exists: $SECRETS_FILE"
        read -p "Overwrite existing file? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            return 0
        fi
    fi

    # Ensure secrets directory exists
    mkdir -p "$(dirname "$SECRETS_FILE")"

    # Generate secure random values
    local admin_token smtp_pass backup_pass
    admin_token=$(openssl rand -hex 32)
    smtp_pass="CHANGE_ME_SMTP_PASSWORD"
    backup_pass=$(openssl rand -base64 32)

    # Create template secrets file
    cat > "$SECRETS_FILE" << EOF
# VaultWarden Secrets Configuration
# Edit these values for your installation

# Admin token for VaultWarden admin panel
# Generate with: openssl rand -hex 32
admin_token: $admin_token

# Basic auth hash for admin panel protection  
# Generate with: echo -n 'password' | argon2 \$(openssl rand -base64 32) -e -id -k 65536 -t 3 -p 4
# Or use online bcrypt generator
admin_basic_auth_hash: CHANGE_ME_BCRYPT_HASH

# SMTP password for email notifications
smtp_password: $smtp_pass

# Backup encryption passphrase
backup_passphrase: $backup_pass

# Push notifications (optional)
push_installation_key: CHANGE_ME_OR_LEAVE_EMPTY

# Cloudflare API token (optional)
cloudflare_api_token: CHANGE_ME_OR_LEAVE_EMPTY
EOF

    log_success "Template secrets file created"
    log_info "Now encrypting with SOPS..."

    # Encrypt the file
    if sops --encrypt --in-place "$SECRETS_FILE"; then
        log_success "Secrets file encrypted successfully"
        chmod 600 "$SECRETS_FILE"
    else
        log_error "Failed to encrypt secrets file"
        return 1
    fi

    log_warn "IMPORTANT: Update the CHANGE_ME values:"
    log_info "  1. Run: ./edit-secrets.sh"
    log_info "  2. Update admin_basic_auth_hash (use bcrypt generator)"
    log_info "  3. Update smtp_password if using email notifications"
    log_info "  4. Update other values as needed"

    return 0
}

# --- Show Secrets ---
show_secrets() {
    log_warn "⚠️  SECURITY WARNING: Displaying decrypted secrets!"
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        return 0
    fi

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        log_info "Run: ./edit-secrets.sh --init"
        return 1
    fi

    echo ""
    echo "=== DECRYPTED SECRETS ==="
    if sops -d "$SECRETS_FILE"; then
        echo "========================="
        echo ""
        log_warn "Remember to keep these values secure!"
    else
        log_error "Failed to decrypt secrets file"
        return 1
    fi

    return 0
}

# --- Edit Secrets ---
edit_secrets() {
    log_info "Opening encrypted secrets for editing..."

    if [[ ! -f "$SECRETS_FILE" ]]; then
        log_error "Secrets file not found: $SECRETS_FILE"
        log_info "Run: ./edit-secrets.sh --init to create it"
        return 1
    fi

    # Check if file is encrypted by trying to decrypt it
    if ! sops -d "$SECRETS_FILE" >/dev/null 2>&1; then
        log_error "Cannot decrypt secrets file with current Age key"
        log_info "Check that Age key is correct and SOPS config is valid"
        return 1
    fi

    log_info "Using editor: $EDITOR"
    log_info "The file will be automatically re-encrypted when you save and exit"
    echo ""

    # Use SOPS to edit the file directly
    if sops "$SECRETS_FILE"; then
        log_success "Secrets updated successfully"

        # Verify the file is still properly encrypted
        if sops -d "$SECRETS_FILE" >/dev/null 2>&1; then
            log_success "Secrets file encryption verified"
        else
            log_error "Warning: Secrets file may not be properly encrypted"
            return 1
        fi

        # Remind about restarting services
        echo ""
        log_info "To apply changes to running services:"
        log_info "  ./startup.sh --force-restart"

    else
        log_error "Editor exited with error or was cancelled"
        return 1
    fi

    return 0
}

# --- Generate Password Hash ---
generate_password_hash() {
    log_info "Password Hash Generator"
    echo ""

    if ! command -v argon2 >/dev/null 2>&1; then
        log_warn "argon2 command not found, using openssl alternative"
        log_info "Install argon2: sudo apt install argon2"
        echo ""

        read -s -p "Enter password: " password
        echo ""
        local salt
        salt=$(openssl rand -base64 16)
        local hash
        hash=$(echo -n "$password" | openssl dgst -sha256 -binary | openssl base64)
        echo ""
        log_info "Basic SHA256 hash (less secure than bcrypt/argon2):"
        echo "$hash"
        echo ""
        log_warn "Use a proper bcrypt generator online for production:"
        log_info "https://bcrypt-generator.com/"
    else
        read -s -p "Enter password: " password
        echo ""
        local salt hash
        salt=$(openssl rand -base64 32)
        hash=$(echo -n "$password" | argon2 "$salt" -e -id -k 65536 -t 3 -p 4)
        echo ""
        log_success "Argon2 hash generated:"
        echo "$hash"
    fi

    echo ""
    log_info "Copy this hash to your secrets file as admin_basic_auth_hash"
}

# --- Main Execution ---
main() {
    log_info "VaultWarden Secrets Manager"

    # Check prerequisites first
    check_prerequisites || exit 1

    # Handle different modes
    if [[ "$INIT_MODE" == "true" ]]; then
        init_secrets
    elif [[ "$SHOW_MODE" == "true" ]]; then
        show_secrets
    else
        # Check if secrets file exists, offer to create it
        if [[ ! -f "$SECRETS_FILE" ]]; then
            log_warn "No secrets file found"
            read -p "Create new secrets file from template? (Y/n): " create_new
            if [[ ! "$create_new" =~ ^[Nn]$ ]]; then
                init_secrets || exit 1
                echo ""
                log_info "Now opening for editing..."
                sleep 2
            else
                log_info "Cancelled"
                exit 0
            fi
        fi

        # Show menu for existing file
        echo ""
        echo "What would you like to do?"
        echo "1) Edit secrets"
        echo "2) Generate password hash"
        echo "3) Show current secrets"
        echo "4) Exit"
        echo ""
        read -p "Choice (1-4): " choice

        case "$choice" in
            1) edit_secrets ;;
            2) generate_password_hash ;;
            3) show_secrets ;;
            4) log_info "Goodbye"; exit 0 ;;
            *) log_error "Invalid choice"; exit 1 ;;
        esac
    fi
}

main "$@"
