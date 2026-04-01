#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - WordPress plugin integrity check
# Uses: wp plugin verify-checksums --all --allow-root
#
# Notes:
#   - Premium/private plugins don't have checksums in wp.org; WP-CLI warns but
#     exits 0. We filter those warnings out and only alert on real failures.
#   - WP-CLI exits 1 when at least one plugin fails checksum verification.
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
declare -f send_alert &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/notify.sh"

# Usage: run_plugins_check <site_name> <site_path>
run_plugins_check() {
    local site_name="$1"
    local site_path="$2"

    log INFO "[plugins] Starting check for '${site_name}'"

    # Confirm WP-CLI can read the site before running the check
    if ! wp_cli "${site_path}" core is-installed &>/dev/null; then
        log WARN "[plugins] Could not verify WP installation at '${site_path}' — skipping"
        return 0
    fi

    local output exit_code
    output=$(wp_cli "${site_path}" plugin verify-checksums --all 2>&1)
    exit_code=$?

    if (( exit_code == 0 )); then
        log INFO "[plugins] PASSED for '${site_name}'"
        return 0
    fi

    log WARN "[plugins] Non-zero exit (${exit_code}) for '${site_name}'"
    log DEBUG "[plugins] Raw output: ${output}"

    # Filter out "no checksums available" warnings (premium/private plugins)
    # These produce exit 1 but are not security issues
    local critical_lines
    critical_lines=$(echo "${output}" \
        | grep -iv 'no verify-checksums available' \
        | grep -iv 'no checksum.*available' \
        | grep -iE '(warning|error|modified|added|removed|deleted|checksum)' \
        | grep -v '^$' \
        | head -30)

    if [[ -z "${critical_lines}" ]]; then
        log INFO "[plugins] Only non-critical warnings (e.g. premium plugins without checksums)"
        return 0
    fi

    send_alert \
        "${site_name}" \
        "Plugin Integrity" \
        "CRITICAL" \
        "wp plugin verify-checksums failed:

${critical_lines}"

    return 1
}
