#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - New file detection
#
# Compares the current file list against the stored baseline and alerts on:
#   - New files found in WP root (depth 1) or wp-content (excluding excluded dirs)
#
# Also logs (but does NOT alert on) files that were in the baseline but are now
# gone — those are expected during plugin/theme removals and updates.
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
declare -f send_alert &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/notify.sh"

# Usage: run_new_files_check <site_name> <site_path> "<excluded_dirs (space-sep)>"
run_new_files_check() {
    local site_name="$1"
    local site_path="$2"
    local excluded_dirs="${3:-uploads}"

    local baseline_file="${DATA_DIR}/${site_name}/files.baseline"

    if [[ ! -f "${baseline_file}" ]]; then
        log ERROR "[new-files] No baseline found for '${site_name}'. Run update-baseline.sh first."
        return 1
    fi

    log INFO "[new-files] Starting check for '${site_name}'"

    # ── Build current file list ──────────────────────────────────────────────
    local tmp_current; tmp_current=$(mktemp)
    trap 'rm -f "${tmp_current}"' RETURN

    # WP root — depth 1
    find "${site_path}" -maxdepth 1 -type f >> "${tmp_current}"

    # wp-content — recursive, excluding specified dirs
    local excl_args=()
    for dir in ${excluded_dirs}; do
        excl_args+=(-not -path "${site_path}/wp-content/${dir}/*")
    done

    if [[ -d "${site_path}/wp-content" ]]; then
        find "${site_path}/wp-content" -type f "${excl_args[@]}" >> "${tmp_current}"
    fi

    sort -u -o "${tmp_current}" "${tmp_current}"

    # ── Compare against baseline ─────────────────────────────────────────────
    # comm requires both files sorted (baseline already is, current just sorted above)
    local new_files deleted_files
    new_files=$(comm -23 "${tmp_current}" "${baseline_file}")
    deleted_files=$(comm -13 "${tmp_current}" "${baseline_file}")
    # tmp_current is removed by the RETURN trap above

    # ── Handle deletions (informational only) ────────────────────────────────
    if [[ -n "${deleted_files}" ]]; then
        local del_count; del_count=$(echo "${deleted_files}" | grep -c .)
        log INFO "[new-files] ${del_count} file(s) from baseline no longer exist in '${site_name}' (normal after updates)"
    fi

    # ── Handle new files (security alert) ───────────────────────────────────
    if [[ -z "${new_files}" ]]; then
        log INFO "[new-files] PASSED for '${site_name}' (no new files)"
        return 0
    fi

    local new_count; new_count=$(echo "${new_files}" | grep -c .)
    log WARN "[new-files] ${new_count} new file(s) found in '${site_name}'"

    # Convert to relative paths and limit output for readability
    local formatted
    formatted=$(echo "${new_files}" | sed "s|${site_path}/||g" | head -25)

    local extra=""
    if (( new_count > 25 )); then
        extra=$'\n'"... and $(( new_count - 25 )) more files"
    fi

    send_alert \
        "${site_name}" \
        "New Files Detected" \
        "CRITICAL" \
        "${new_count} new file(s) detected (not in baseline):

${formatted}${extra}

Run update-baseline.sh if these changes are intentional."

    return 1
}
