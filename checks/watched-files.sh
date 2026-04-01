#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Watched file integrity check
#
# For each file in the checksum baseline, verifies:
#   1. File still exists (alerts if deleted)
#   2. SHA-256 checksum is unchanged (alerts if content modified)
#   3. Modification time is unchanged (alerts if mtime tampered — content same
#      but timestamp altered, which is a manipulation indicator)
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
declare -f send_alert &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/notify.sh"

# Usage: run_watched_files_check <site_name> <site_path>
run_watched_files_check() {
    local site_name="$1"
    local site_path="$2"

    local baseline_file="${DATA_DIR}/${site_name}/checksums.baseline"

    if [[ ! -f "${baseline_file}" ]]; then
        log ERROR "[watched] No checksum baseline found for '${site_name}'. Run update-baseline.sh first."
        return 1
    fi

    log INFO "[watched] Starting check for '${site_name}'"

    local issues=()

    while IFS='|' read -r rel_path expected_checksum expected_mtime; do
        # Skip blank lines or comments
        [[ -z "${rel_path}" || "${rel_path}" == \#* ]] && continue

        local full_path="${site_path}/${rel_path}"

        # ── File deleted ──────────────────────────────────────────────────
        if [[ ! -f "${full_path}" ]]; then
            if [[ "${expected_checksum}" != "NOT_FOUND" ]]; then
                issues+=("❌ DELETED: ${rel_path}")
                log WARN "[watched] File deleted: ${full_path}"
            fi
            continue
        fi

        # ── Compute current state ─────────────────────────────────────────
        local current_checksum; current_checksum=$(sha256sum "${full_path}" | cut -d' ' -f1)
        local current_mtime;    current_mtime=$(stat -c%Y "${full_path}")

        # ── Content changed ───────────────────────────────────────────────
        if [[ "${current_checksum}" != "${expected_checksum}" ]]; then
            local modified_date; modified_date=$(date -d "@${current_mtime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                || date -r "${full_path}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                || echo "unknown")
            issues+=("✏️  MODIFIED: ${rel_path}  [last modified: ${modified_date}]")
            log WARN "[watched] Content changed: ${full_path}"
            continue
        fi

        # ── Timestamp tampered (same content, different mtime) ────────────
        if [[ "${current_mtime}" != "${expected_mtime}" ]]; then
            local orig_date; orig_date=$(date -d "@${expected_mtime}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                || echo "unknown")
            local new_date;  new_date=$(date  -d "@${current_mtime}"  '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                || echo "unknown")
            issues+=("⏰ TIMESTAMP CHANGED: ${rel_path}  [was: ${orig_date} → now: ${new_date}]")
            log WARN "[watched] Timestamp changed: ${full_path}"
        fi

    done < "${baseline_file}"

    if (( ${#issues[@]} == 0 )); then
        log INFO "[watched] PASSED for '${site_name}'"
        return 0
    fi

    # Build detail string
    local detail
    detail=$(printf '%s\n' "${issues[@]}")

    send_alert \
        "${site_name}" \
        "Watched Files Changed" \
        "CRITICAL" \
        "Critical file changes detected:

${detail}

Run update-baseline.sh if changes are intentional."

    return 1
}
