#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Telegram notifications with alert deduplication
# =============================================================================

declare -f log &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# ─── Send raw Telegram message ────────────────────────────────────────────────
# Usage: send_telegram "<html_message>"
send_telegram() {
    local message="$1"

    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        log WARN "Telegram credentials not set — skipping notification"
        return 0
    fi

    local response
    response=$(curl -s \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" \
        --data-urlencode "text=${message}" 2>&1)

    if echo "${response}" | grep -q '"ok":true'; then
        return 0
    else
        log ERROR "Telegram send failed: ${response}"
        return 1
    fi
}

# ─── Alert with deduplication ─────────────────────────────────────────────────
# Usage: send_alert <site_name> <check_type> <severity> <detail_html>
#
# Severity: CRITICAL | WARNING | INFO
# detail_html: HTML-formatted detail lines (will be wrapped in <pre>)
#
# Deduplication: if the same alert (same hash of site+check+detail) was sent
# within ALERT_DEDUP_HOURS, it is silently skipped.
send_alert() {
    local site_name="$1"
    local check_type="$2"
    local severity="${3:-WARNING}"
    local detail="$4"

    # Compute dedup key from content (ignoring timestamps)
    local alert_hash
    alert_hash=$(printf '%s|%s|%s|%s' \
        "$(get_hostname)" "${site_name}" "${check_type}" "${detail}" \
        | sha256sum | cut -d' ' -f1)

    local site_state_dir="${STATE_DIR}/${site_name}"
    local state_file="${site_state_dir}/alert_${alert_hash}"
    local dedup_secs=$(( ${ALERT_DEDUP_HOURS:-24} * 3600 ))

    # Check deduplication window
    if [[ -f "${state_file}" ]]; then
        local last_sent; last_sent=$(cat "${state_file}" 2>/dev/null || echo 0)
        local now; now=$(date +%s)
        local age=$(( now - last_sent ))
        if (( age < dedup_secs )); then
            log DEBUG "Alert deduplicated: ${check_type} / ${site_name} (sent ${age}s ago, window=${dedup_secs}s)"
            return 0
        fi
    fi

    # Choose icon
    local icon
    case "${severity}" in
        CRITICAL) icon="🚨" ;;
        WARNING)  icon="⚠️"  ;;
        INFO)     icon="ℹ️"  ;;
        *)        icon="🔔" ;;
    esac

    # Build message
    local escaped_detail; escaped_detail=$(escape_html "${detail}")
    local message
    message="${icon} <b>CL WP Sentinel Alert</b>
📍 <b>Host:</b> $(escape_html "$(get_hostname)")
🌐 <b>Site:</b> $(escape_html "${site_name}")
🔍 <b>Check:</b> $(escape_html "${check_type}")
🔴 <b>Severity:</b> ${severity}
📅 <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<pre>${escaped_detail}</pre>"

    message=$(truncate_message "${message}")

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "[DRY-RUN] Alert would be sent (${severity} / ${check_type} / ${site_name}):"
        echo "---"
        echo "${message}"
        echo "---"
        return 0
    fi

    log INFO "Sending ${severity} alert [${check_type}] for site '${site_name}'"

    if send_telegram "${message}"; then
        mkdir -p "${site_state_dir}"
        date +%s > "${state_file}"
    fi
}

# ─── Recovery notification (no dedup) ────────────────────────────────────────
# Usage: send_recovery <site_name> <check_type> [detail]
send_recovery() {
    local site_name="$1"
    local check_type="$2"
    local detail="${3:-All checks passed}"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "[DRY-RUN] Recovery notification: ${check_type} / ${site_name}"
        return 0
    fi

    local escaped_detail; escaped_detail=$(escape_html "${detail}")
    local message
    message="✅ <b>CL WP Sentinel — Resolved</b>
📍 <b>Host:</b> $(escape_html "$(get_hostname)")
🌐 <b>Site:</b> $(escape_html "${site_name}")
🔍 <b>Check:</b> $(escape_html "${check_type}")
📅 <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

<i>${escaped_detail}</i>"

    send_telegram "${message}"
}

# ─── Clear dedup state for a site ────────────────────────────────────────────
# Called after baseline update so alerts can fire fresh
clear_alert_state() {
    local site_name="$1"
    local site_state_dir="${STATE_DIR}/${site_name}"

    if [[ -d "${site_state_dir}" ]]; then
        rm -f "${site_state_dir}"/alert_*
        log INFO "Alert dedup state cleared for '${site_name}'"
    fi
}
