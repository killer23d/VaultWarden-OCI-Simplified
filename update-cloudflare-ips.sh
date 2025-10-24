#!/usr/bin/env bash
# update-cloudflare-ips.sh - Fetches Cloudflare IPs, updates Caddy config, and reloads Caddy.
# Includes error handling and sends email notification ONLY on failure.

set -euo pipefail

# --- Project Root Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
cd "$PROJECT_ROOT"

# --- Source Libraries ---
source "lib/common.sh"
init_common_lib "$0"
# docker lib needed for 'docker compose exec'
source "lib/docker.sh"

# --- Main Update Function ---
update_cloudflare_ips() {
    log_info "Updating Cloudflare IP ranges..."

    local cf_ips_v4 cf_ips_v6
    local temp_file="caddy/cloudflare-ips.caddy.new"
    local final_file="caddy/cloudflare-ips.caddy"
    local backup_file="caddy/cloudflare-ips.caddy.backup" # Backup file path

    # Fetch IP ranges with timeout
    log_info "Fetching IPv4 ranges..."
    if ! cf_ips_v4=$(curl -sL --fail --max-time 30 https://www.cloudflare.com/ips-v4); then
        log_error "Failed to fetch Cloudflare IPv4 ranges using curl."
        return 1
    fi

    log_info "Fetching IPv6 ranges..."
    if ! cf_ips_v6=$(curl -sL --fail --max-time 30 https://www.cloudflare.com/ips-v6); then
        log_error "Failed to fetch Cloudflare IPv6 ranges using curl."
        return 1
    fi

    # Validate IP ranges (basic check: ensure we got multiple lines/ranges)
    if [[ $(echo "$cf_ips_v4" | wc -l) -lt 5 || $(echo "$cf_ips_v6" | wc -l) -lt 3 ]]; then
        log_error "Cloudflare IP ranges appear invalid (too few ranges fetched)."
        log_debug "IPv4 lines: $(echo "$cf_ips_v4" | wc -l), IPv6 lines: $(echo "$cf_ips_v6" | wc -l)"
        return 1
    fi
    log_info "IP ranges fetched and basic validation passed."

    # Create new config file content
    local file_content
    file_content=$(cat << EOF
# Cloudflare IP ranges (auto-updated $(date -uIs))
@cloudflare {
    # Cloudflare IPv4 ranges
    remote_ip $cf_ips_v4
    # Cloudflare IPv6 ranges
    remote_ip $cf_ips_v6
}
EOF
)

    # Write to temporary file
    if ! echo "$file_content" > "$temp_file"; then
        log_error "Failed to write new IP list to temporary file: $temp_file"
        return 1
    fi

    # --- START Enhancement: Backup previous file ---
    if [[ -f "$final_file" ]]; then
        log_info "Backing up existing IP list to $backup_file"
        cp "$final_file" "$backup_file" || log_warn "Could not backup previous config file $final_file"
    fi
    # --- END Enhancement ---

    # Atomic replacement: Set ownership/permissions then move
    if [[ -f "$backup_file" ]]; then
        # If backup exists, use it as reference for perms/ownership
        chown --reference="$backup_file" "$temp_file" || log_warn "Could not set ownership on $temp_file"
        chmod --reference="$backup_file" "$temp_file" || log_warn "Could not set permissions on $temp_file"
    elif [[ -f "$final_file" ]]; then
         # Fallback to using original file if backup failed
        chown --reference="$final_file" "$temp_file" || log_warn "Could not set ownership on $temp_file"
        chmod --reference="$final_file" "$temp_file" || log_warn "Could not set permissions on $temp_file"
    else
        # Fallback permissions if original doesn't exist
        chmod 644 "$temp_file" || log_warn "Could not set permissions on $temp_file"
    fi

    if ! mv "$temp_file" "$final_file"; then
        log_error "Failed to move temporary file to final location: $final_file"
        rm -f "$temp_file" # Clean up temp file on failure
        return 1
    fi
    log_success "Successfully updated $final_file"

    # Reload Caddy using docker compose exec
    log_info "Reloading Caddy configuration..."
    if docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile > /dev/null; then
        log_success "Cloudflare IPs updated and Caddy reloaded successfully."
        return 0
    else
        log_error "Failed to reload Caddy after IP update. Caddy might be using old IPs."
        # --- START Enhancement: Restore backup on reload failure ---
        log_warn "Attempting to restore previous IP list from backup..."
        if [[ -f "$backup_file" ]]; then
            if mv "$backup_file" "$final_file"; then
                log_info "Successfully restored previous IP list. Reloading Caddy again..."
                if docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile > /dev/null; then
                     log_success "Caddy reloaded successfully with restored IP list."
                else
                     log_error "Failed to reload Caddy even after restoring backup. Manual intervention required."
                fi
            else
                log_error "Failed to restore backup file $backup_file. Manual intervention required."
            fi
        else
            log_error "No backup file found to restore. Manual intervention required."
        fi
        # --- END Enhancement ---
        return 1
    fi
}

# --- Main Execution ---
main() {
    # Load environment needed for docker compose
    load_env_file || {
        log_error "Failed to load .env file. Cannot run docker compose."
        exit 1
    }

    # Ensure Docker is available
    require_docker || exit 1

    if ! update_cloudflare_ips; then
        log_error "Cloudflare IP update process failed."
        # Send email notification ONLY on failure
        send_notification_email "Cloudflare IP Update Failed" \
            "The automated process to update Cloudflare IP ranges failed on $(hostname -f 2>/dev/null || hostname). Caddy may not trust incoming connections correctly. Please check logs ($PROJECT_ROOT/logs/cron.log or similar) or run the script manually."
        exit 1
    fi

    log_info "Cloudflare IP update completed successfully."
    exit 0
}

# Ensure script is not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

