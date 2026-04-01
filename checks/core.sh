#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - WordPress core integrity check
# Uses: wp core verify-checksums --allow-root
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
declare -f send_alert &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/notify.sh"

# Usage: run_core_check <site_name> <site_path>
run_core_check() {
    local site_name="$1"
    local site_path="$2"

    log INFO "[core] Starting check for '${site_name}'"

    local output exit_code
    output=$(wp_cli "${site_path}" core verify-checksums 2>&1)
    exit_code=$?

    if (( exit_code == 0 )); then
        log INFO "[core] PASSED for '${site_name}'"
        return 0
    fi

    log WARN "[core] FAILED for '${site_name}' (exit ${exit_code})"
    log DEBUG "[core] Raw output: ${output}"

    # Filter for actionable lines — wp-cli outputs "Warning: File ..." or "Error: ..."
    local issues
    issues=$(echo "${output}" \
        | grep -iE '(warning|error|checksum|modified|added|removed|deleted)' \
        | grep -v '^$' \
        | head -30)

    [[ -z "${issues}" ]] && issues="${output}"

    send_alert \
        "${site_name}" \
        "Core Integrity" \
        "CRITICAL" \
        "wp core verify-checksums failed:

${issues}"

    return 1
}
