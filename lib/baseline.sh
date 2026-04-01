#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Baseline creation and management
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

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
    # Guarantee cleanup even on early exit or error.
    # Double-quotes expand ${tmp} NOW (at trap-set time) so the literal path is
    # embedded in the trap string. 'trap - RETURN' inside the handler resets the
    # trap after it fires, preventing it from leaking to the caller under set -u.
    # shellcheck disable=SC2064
    trap "rm -f '${tmp}'; trap - RETURN" RETURN

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
        local full_path
        full_path=$(resolve_watched_file_path "${site_path}" "${rel_path}")
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

# ─── Active plugins and theme baseline ───────────────────────────────────────
# Stores the sorted list of active plugin slugs and the active theme name.
# No baseline needed for php-in-uploads (any PHP there is always wrong).
#
# Usage: create_active_plugins_baseline <site_name> <site_path>
create_active_plugins_baseline() {
    local site_name="$1"
    local site_path="$2"

    local plugins_file="${DATA_DIR}/${site_name}/active-plugins.baseline"
    local theme_file="${DATA_DIR}/${site_name}/active-theme.baseline"
    mkdir -p "$(dirname "${plugins_file}")"

    log INFO "Creating active-plugins baseline for '${site_name}'..."

    # Active plugins
    local plugins
    plugins=$(wp_cli "${site_path}" plugin list \
        --status=active \
        --field=name \
        --format=csv 2>&1)

    if [[ $? -ne 0 ]]; then
        log WARN "WP-CLI could not list plugins for '${site_name}': ${plugins}"
        : > "${plugins_file}"
    else
        echo "${plugins}" | sort | grep -v '^\s*$' > "${plugins_file}"
        local count; count=$(wc -l < "${plugins_file}")
        log INFO "Active-plugins baseline ready: ${count} active plugin(s) for '${site_name}'"
    fi

    # Active theme — capture first, then pipe, so $? reflects wp_cli exit code
    local raw_theme theme wp_theme_exit
    raw_theme=$(wp_cli "${site_path}" theme list \
        --status=active \
        --field=name \
        --format=csv 2>&1)
    wp_theme_exit=$?
    theme=$(echo "${raw_theme}" | grep -v '^\s*$' | head -1)

    if [[ ${wp_theme_exit} -ne 0 || -z "${theme}" ]]; then
        log WARN "WP-CLI could not get active theme for '${site_name}': ${raw_theme}"
        : > "${theme_file}"
    else
        echo "${theme}" > "${theme_file}"
        log INFO "Active-theme baseline ready: '${theme}' for '${site_name}'"
    fi
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
    echo "${admins}" | sort | grep -v '^\s*$' > "${baseline_file}"

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
    local errors=0
    create_file_baseline            "${site_name}" "${site_path}" "${excluded_dirs}" || { log WARN "File baseline failed for '${site_name}'";           errors=$(( errors + 1 )); }
    create_checksum_baseline        "${site_name}" "${site_path}" "${watched_files}" || { log WARN "Checksum baseline failed for '${site_name}'";       errors=$(( errors + 1 )); }
    create_admin_baseline           "${site_name}" "${site_path}"                    || { log WARN "Admin-users baseline failed for '${site_name}'";    errors=$(( errors + 1 )); }
    create_active_plugins_baseline  "${site_name}" "${site_path}"                    || { log WARN "Active-plugins baseline failed for '${site_name}'"; errors=$(( errors + 1 )); }

    if (( errors > 0 )); then
        log WARN "=== Baseline update for '${site_name}' completed with ${errors} error(s) ==="
    else
        log INFO "=== Baselines updated for '${site_name}' ==="
    fi
    return ${errors}
}
