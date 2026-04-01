#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Admin user count check
#
# Reads the list of administrator-role users via WP-CLI and compares it
# against the baseline snapshot taken at install time (or last baseline update).
#
# Alerts when:
#   - New admin accounts appear (count increases or unknown login found)
#
# Logs (no alert) when:
#   - Admin accounts disappear (could be intentional removal)
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
declare -f send_alert &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/notify.sh"

run_admin_users_check() {
    local site_name="$1"
    local site_path="$2"

    local baseline_file="${DATA_DIR}/${site_name}/admin-users.baseline"

    if [[ ! -f "${baseline_file}" ]]; then
        log ERROR "No admin-users baseline for '${site_name}'. Run update-baseline.sh first."
        return 1
    fi

    log INFO "Running admin users check for '${site_name}'..."

    # Get current admin list via WP-CLI (sorted for reliable diff)
    local current_admins
    current_admins=$(wp_cli "${site_path}" user list \
        --role=administrator \
        --field=user_login \
        --format=csv 2>&1)

    if [[ $? -ne 0 ]]; then
        log ERROR "WP-CLI failed to retrieve users for '${site_name}': ${current_admins}"
        return 1
    fi

    # Sort and strip any blank lines
    local tmp_current; tmp_current=$(mktemp)
    echo "${current_admins}" | sort | grep -v '^$' > "${tmp_current}"

    local current_count; current_count=$(wc -l < "${tmp_current}")
    local baseline_count; baseline_count=$(wc -l < "${baseline_file}")

    # New admins = in current but not in baseline
    local new_admins
    new_admins=$(comm -23 "${tmp_current}" "${baseline_file}")

    # Removed admins = in baseline but not in current
    local removed_admins
    removed_admins=$(comm -13 "${tmp_current}" "${baseline_file}")

    rm -f "${tmp_current}"

    local has_issues=0

    if [[ -n "${new_admins}" ]]; then
        has_issues=1
        local new_count; new_count=$(echo "${new_admins}" | wc -l)
        log WARN "Found ${new_count} new admin account(s) in '${site_name}'"

        local user_list
        user_list=$(echo "${new_admins}" | sed 's/^/  • /' | head -20)

        send_alert \
            "${site_name}" \
            "New Admin User(s)" \
            "CRITICAL" \
            "$(escape_html "${new_count}") new administrator account(s) detected (was ${baseline_count}, now ${current_count}):
<pre>$(escape_html "${user_list}")</pre>"
    fi

    if [[ -n "${removed_admins}" ]]; then
        local rm_count; rm_count=$(echo "${removed_admins}" | wc -l)
        # Removal may be intentional — log only, no alert
        log INFO "Note: ${rm_count} admin account(s) no longer present in '${site_name}' (may be intentional): $(echo "${removed_admins}" | tr '\n' ' ')"
    fi

    if (( has_issues == 0 )); then
        log INFO "Admin users check PASSED for '${site_name}' (${current_count} admin(s))"
    fi

    return ${has_issues}
}
