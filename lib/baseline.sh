#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Baseline creation and management
# =============================================================================

[[ "$(type -t log)" == "function" ]] || source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# ─── File list baseline ───────────────────────────────────────────────────────
# Scans:
#   - WP root (depth 1 only — individual files at the root)
#   - wp-content (recursive, excluding dirs in EXCLUDED_DIRS)
#
# Usage: create_file_baseline <site_name> <site_path> "<excluded_dirs (space-sep)>"
create_file_baseline() {
    local site_name="$1"
    local site_path="$2"
    local excluded_dirs="${3:-uploads}"

    local baseline_file="${DATA_DIR}/${site_name}/files.baseline"
    mkdir -p "$(dirname "${baseline_file}")"

    log INFO "Creating file baseline for '${site_name}'..."

    local tmp; tmp=$(mktemp)

    # 1) WP root — files only, depth 1
    find "${site_path}" -maxdepth 1 -type f >> "${tmp}"

    # 2) wp-content — recursive, excluding specified subdirectories
    local excl_args=()
    for dir in ${excluded_dirs}; do
        excl_args+=(-not -path "${site_path}/wp-content/${dir}/*")
    done

    if [[ -d "${site_path}/wp-content" ]]; then
        find "${site_path}/wp-content" -type f "${excl_args[@]}" >> "${tmp}"
    fi

    # Sort and deduplicate into baseline
    sort -u "${tmp}" > "${baseline_file}"
    rm -f "${tmp}"

    local count; count=$(wc -l < "${baseline_file}")
    log INFO "File baseline ready: ${count} files tracked for '${site_name}'"
}

# ─── Checksum baseline for watched files ─────────────────────────────────────
# Format per line: relative_path|sha256|mtime_epoch
#
# Usage: create_checksum_baseline <site_name> <site_path> "<watched_files (space-sep)>"
create_checksum_baseline() {
    local site_name="$1"
    local site_path="$2"
    local watched_files="$3"

    local baseline_file="${DATA_DIR}/${site_name}/checksums.baseline"
    mkdir -p "$(dirname "${baseline_file}")"

    log INFO "Creating checksum baseline for '${site_name}'..."

    : > "${baseline_file}"

    for rel_path in ${watched_files}; do
        local full_path="${site_path}/${rel_path}"
        if [[ -f "${full_path}" ]]; then
            local checksum; checksum=$(sha256sum "${full_path}" | cut -d' ' -f1)
            local mtime;    mtime=$(stat -c%Y "${full_path}")
            printf '%s|%s|%s\n' "${rel_path}" "${checksum}" "${mtime}" >> "${baseline_file}"
            log DEBUG "  Hashed: ${rel_path} → ${checksum:0:12}..."
        else
            log WARN "  Watched file not found at install time: ${full_path}"
            printf '%s|NOT_FOUND|0\n' "${rel_path}" >> "${baseline_file}"
        fi
    done

    local count; count=$(wc -l < "${baseline_file}")
    log INFO "Checksum baseline ready: ${count} files watched for '${site_name}'"
}

# ─── Admin users baseline ─────────────────────────────────────────────────────
# Stores the sorted list of administrator-role logins, one per line.
# The check compares live WP-CLI output against this file.
#
# Usage: create_admin_baseline <site_name> <site_path>
create_admin_baseline() {
    local site_name="$1"
    local site_path="$2"

    local baseline_file="${DATA_DIR}/${site_name}/admin-users.baseline"
    mkdir -p "$(dirname "${baseline_file}")"

    log INFO "Creating admin-users baseline for '${site_name}'..."

    local admins
    admins=$(wp_cli "${site_path}" user list \
        --role=administrator \
        --field=user_login \
        --format=csv 2>&1)

    if [[ $? -ne 0 ]]; then
        log WARN "WP-CLI could not retrieve admin users for '${site_name}': ${admins}"
        # Write an empty baseline so the check can still run later
        : > "${baseline_file}"
        return 1
    fi

    # Sort and strip blank lines for reliable comm(1) comparison later
    echo "${admins}" | sort | grep -v '^$' > "${baseline_file}"

    local count; count=$(wc -l < "${baseline_file}")
    log INFO "Admin-users baseline ready: ${count} administrator(s) tracked for '${site_name}'"
}

# ─── Update all baselines for a site ─────────────────────────────────────────
# Usage: update_all_baselines <site_name> <site_path> <excluded_dirs> <watched_files>
update_all_baselines() {
    local site_name="$1"
    local site_path="$2"
    local excluded_dirs="$3"
    local watched_files="$4"

    log INFO "=== Updating all baselines for '${site_name}' ==="
    create_file_baseline     "${site_name}" "${site_path}" "${excluded_dirs}"
    create_checksum_baseline "${site_name}" "${site_path}" "${watched_files}"
    create_admin_baseline    "${site_name}" "${site_path}"
    log INFO "=== Baselines updated for '${site_name}' ==="
}
