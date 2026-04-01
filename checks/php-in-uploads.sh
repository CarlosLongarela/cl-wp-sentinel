#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - PHP files in uploads check
#
# wp-content/uploads/ should never contain executable files.
# Any PHP (or similar) file there is a strong indicator of a webshell or
# malicious upload — no baseline needed, zero false positives by design.
#
# Alerts when:
#   - Any file with a PHP-executable extension is found inside uploads/
#
# Extensions checked: .php .php3 .php4 .php5 .php7 .phtml .phar .shtml
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/utils.sh"
declare -f send_alert &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../lib/notify.sh"

# Dangerous extensions — anything the web server might execute
readonly _PHP_EXTENSIONS=("php" "php3" "php4" "php5" "php7" "phtml" "phar" "shtml")

run_php_in_uploads_check() {
    local site_name="$1"
    local site_path="$2"

    local uploads_dir="${site_path}/wp-content/uploads"

    if [[ ! -d "${uploads_dir}" ]]; then
        log INFO "No uploads directory found for '${site_name}' — skipping php-in-uploads check"
        return 0
    fi

    log INFO "Running PHP-in-uploads check for '${site_name}'..."

    # Build -name patterns for find (OR-joined)
    local find_args=()
    for ext in "${_PHP_EXTENSIONS[@]}"; do
        if (( ${#find_args[@]} > 0 )); then
            find_args+=(-o)
        fi
        find_args+=(-iname "*.${ext}")
    done

    local found_files
    found_files=$(find "${uploads_dir}" -type f \( "${find_args[@]}" \) 2>/dev/null | sort)

    if [[ -z "${found_files}" ]]; then
        log INFO "PHP-in-uploads check PASSED for '${site_name}'"
        return 0
    fi

    local count; count=$(echo "${found_files}" | wc -l)
    log WARN "Found ${count} executable file(s) in uploads for '${site_name}'"

    # Show relative paths to keep the message readable
    local rel_files
    rel_files=$(echo "${found_files}" | sed "s|${site_path}/||g" | sed 's/^/  • /' | head -20)
    local extra=""
    if (( count > 20 )); then
        extra=$'\n'"  ... and $(( count - 20 )) more"
    fi

    send_alert \
        "${site_name}" \
        "PHP File(s) in Uploads" \
        "CRITICAL" \
        "${count} executable file(s) found in wp-content/uploads/:
${rel_files}${extra}
These files should be removed immediately."

    return 1
}
