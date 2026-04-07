#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Active plugins and theme check
#
# Compares the currently active plugins and active theme against the baseline
# snapshot. An attacker who uploads a plugin and then activates it — or who
# activates an already-installed but dormant plugin — will be detected here
# even if the file-integrity checks pass (e.g. the plugin was legitimate).
#
# Alerts when:
#   - A plugin is activated that was not active at baseline time
#   - The active theme changes
#
# Logs (no alert) when:
#   - A plugin is deactivated (could be intentional maintenance)
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
declare -f send_alert &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/notify.sh"

run_active_plugins_check() {
    local site_name="$1"
    local site_path="$2"

    local plugins_baseline="${DATA_DIR}/${site_name}/active-plugins.baseline"
    local theme_baseline="${DATA_DIR}/${site_name}/active-theme.baseline"

    if [[ ! -f "${plugins_baseline}" || ! -f "${theme_baseline}" ]]; then
        log ERROR "No active-plugins/theme baseline for '${site_name}'. Run cl-wp-sentinel-update-baseline first."
        return 1
    fi

    log INFO "Running active plugins/theme check for '${site_name}'..."

    local has_issues=0

    # ── Plugins ───────────────────────────────────────────────────────────────
    local current_plugins
    current_plugins=$(wp_cli "${site_path}" plugin list \
        --status=active \
        --field=name \
        --format=csv 2>&1)

    if [[ $? -ne 0 ]]; then
        log ERROR "WP-CLI failed to list plugins for '${site_name}': ${current_plugins}"
        return 1
    fi

    local tmp_plugins; tmp_plugins=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '${tmp_plugins}'; trap - RETURN" RETURN
    echo "${current_plugins}" | sort | grep -v '^\s*$' > "${tmp_plugins}"

    # Newly activated = in current but not in baseline
    local new_plugins
    new_plugins=$(comm -23 "${tmp_plugins}" "${plugins_baseline}")

    # Deactivated = in baseline but not in current
    local removed_plugins
    removed_plugins=$(comm -13 "${tmp_plugins}" "${plugins_baseline}")

    local current_plugin_count; current_plugin_count=$(wc -l < "${tmp_plugins}")
    local baseline_plugin_count; baseline_plugin_count=$(wc -l < "${plugins_baseline}")

    if [[ -n "${new_plugins}" ]]; then
        has_issues=1
        local new_count; new_count=$(echo "${new_plugins}" | wc -l)
        log WARN "Found ${new_count} newly activated plugin(s) in '${site_name}'"

        local plugin_list
        plugin_list=$(echo "${new_plugins}" | sed 's/^/  • /' | head -20)

        send_alert \
            "${site_name}" \
            "Plugin(s) Activated" \
            "CRITICAL" \
            "${new_count} plugin(s) activated since baseline (was ${baseline_plugin_count} active, now ${current_plugin_count}):
${plugin_list}"
    fi

    if [[ -n "${removed_plugins}" ]]; then
        local rm_count; rm_count=$(echo "${removed_plugins}" | wc -l)
        log INFO "Note: ${rm_count} plugin(s) deactivated in '${site_name}' (may be intentional): $(echo "${removed_plugins}" | tr '\n' ' ')"
    fi

    # ── Active theme ──────────────────────────────────────────────────────────
    # Capture first, then process — checking $? after a pipe checks the last
    # command in the pipe (head), not wp_cli
    local raw_theme wp_theme_exit current_theme
    raw_theme=$(wp_cli "${site_path}" theme list \
        --status=active \
        --field=name \
        --format=csv 2>&1)
    wp_theme_exit=$?
    current_theme=$(echo "${raw_theme}" | grep -v '^\s*$' | head -1)

    if [[ ${wp_theme_exit} -ne 0 ]]; then
        log ERROR "WP-CLI failed to get active theme for '${site_name}': ${raw_theme}"
        has_issues=1
    else
        local baseline_theme
        baseline_theme=$(cat "${theme_baseline}" 2>/dev/null || true)

        if [[ -z "${baseline_theme}" ]]; then
            # Baseline was empty (WP-CLI failed at baseline creation) — skip silently
            log WARN "Theme baseline is empty for '${site_name}' — run cl-wp-sentinel-update-baseline to fix"
        elif [[ "${current_theme}" != "${baseline_theme}" ]]; then
            has_issues=1
            log WARN "Active theme changed in '${site_name}': '${baseline_theme}' → '${current_theme}'"

            send_alert \
                "${site_name}" \
                "Active Theme Changed" \
                "CRITICAL" \
                "Active theme has changed:
  • Was: ${baseline_theme}
  • Now: ${current_theme}"
        fi
    fi

    if (( has_issues == 0 )); then
        log INFO "Active plugins/theme check PASSED for '${site_name}' (${current_plugin_count} plugin(s), theme: ${current_theme})"
    fi

    return ${has_issues}
}
