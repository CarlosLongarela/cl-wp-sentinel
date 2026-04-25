#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - WordPress plugin integrity check
# Uses: wp plugin verify-checksums --all --allow-root
#
# Notes:
#   - Premium/private plugins don't have checksums in wp.org; WP-CLI warns but
#     exits 0. We filter those warnings out and only alert on real failures.
#   - WP-CLI exits 1 when at least one plugin fails checksum verification.
#   - Per-site VERIFY_CHECKSUMS_SKIP array (defined in site config) lists
#     plugin slugs to exclude from verification (premium/private plugins).
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

    # Build verify-checksums arguments.
    # If VERIFY_CHECKSUMS_SKIP is defined and non-empty, retrieve the full
    # plugin list and pass only the non-excluded slugs to avoid wasted HTTP
    # requests and false-positive warnings for premium/private plugins.
    local -a verify_args
    if [[ ${#VERIFY_CHECKSUMS_SKIP[@]} -gt 0 ]]; then
        local all_plugins
        all_plugins=$(wp_cli "${site_path}" plugin list --field=name --format=csv 2>/dev/null | grep -v '^$')

        local -a included_plugins=()
        local plugin skip excluded
        while IFS= read -r plugin; do
            [[ -z "${plugin}" ]] && continue
            skip=0
            for excluded in "${VERIFY_CHECKSUMS_SKIP[@]}"; do
                [[ "${plugin}" == "${excluded}" ]] && { skip=1; break; }
            done
            (( skip )) || included_plugins+=("${plugin}")
        done <<< "${all_plugins}"

        if [[ ${#included_plugins[@]} -eq 0 ]]; then
            log INFO "[plugins] All plugins are in VERIFY_CHECKSUMS_SKIP — nothing to verify"
            return 0
        fi

        log INFO "[plugins] Skipping ${#VERIFY_CHECKSUMS_SKIP[@]} plugin(s) not in WordPress.org (VERIFY_CHECKSUMS_SKIP)"
        verify_args=("${included_plugins[@]}")
    else
        verify_args=(--all)
    fi

    local output exit_code
    output=$(wp_cli "${site_path}" plugin verify-checksums "${verify_args[@]}" 2>&1)
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
