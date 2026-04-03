#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Update baseline for one or all sites
#
# Run this after:
#   - Installing / updating WordPress core
#   - Installing / updating / removing plugins or themes
#   - Intentionally modifying watched files (wp-config.php, .htaccess, etc.)
#
# After updating the baseline, existing alert dedup state for the site is
# cleared so that new issues can generate fresh alerts.
#
# Usage:
#   update-baseline.sh [options]
#
# Options:
#   --site=NAME       Update only the specified site (default: all sites)
#   --no-notify       Do not send a Telegram confirmation after update
#   --help            Show this help
# =============================================================================

set -euo pipefail

# Resolve real script path so symlinked entrypoints in /usr/local/bin work.
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "${SOURCE}" ]]; do
    DIR="$(cd -P "$(dirname "${SOURCE}")" && pwd)"
    SOURCE="$(readlink "${SOURCE}")"
    [[ "${SOURCE}" != /* ]] && SOURCE="${DIR}/${SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SOURCE}")" && pwd)"
CONFIG_DIR="${WP_SENTINEL_CONFIG_DIR:-/etc/cl-wp-sentinel}"
SITES_DIR="${CONFIG_DIR}/sites"

# ─── Parse arguments ──────────────────────────────────────────────────────────
SPECIFIC_SITE=""
NOTIFY=1

for arg in "$@"; do
    case "${arg}" in
        --site=*)    SPECIFIC_SITE="${arg#*=}" ;;
        --no-notify) NOTIFY=0 ;;
        --help|-h)
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}. Use --help for usage." >&2
            exit 1
            ;;
    esac
done

# ─── Load global config and libraries ────────────────────────────────────────
if [[ ! -f "${CONFIG_DIR}/config.sh" ]]; then
    echo "ERROR: Config not found at ${CONFIG_DIR}/config.sh. Run install.sh first."
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_DIR}/config.sh"
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/notify.sh"
source "${SCRIPT_DIR}/lib/baseline.sh"

check_prerequisites

# ─── Main ─────────────────────────────────────────────────────────────────────
log INFO "====== CL WP Sentinel baseline update — host: $(get_hostname) ======"

UPDATED=0

for site_config in "${SITES_DIR}"/*.conf; do
    [[ -f "${site_config}" ]] || continue

    unset SITE_NAME SITE_PATH SITE_DOMAIN EXCLUDED_DIRS PHP_UPLOADS_IGNORE
    WATCHED_FILES=()

    # shellcheck source=/dev/null
    source "${site_config}"

    if [[ -n "${SPECIFIC_SITE}" && "${SITE_NAME}" != "${SPECIFIC_SITE}" ]]; then
        continue
    fi

    if [[ ! -d "${SITE_PATH}" ]]; then
        log ERROR "Site path not found: ${SITE_PATH} for '${SITE_NAME}' — skipping"
        continue
    fi

    log INFO "------ Updating baseline for: ${SITE_NAME} ------"

    EXCLUDED="${EXCLUDED_DIRS:-uploads}"
    WATCHED="${WATCHED_FILES[*]+${WATCHED_FILES[*]}}"
    WATCHED="${WATCHED:-wp-config.php .htaccess}"

    if update_all_baselines "${SITE_NAME}" "${SITE_PATH}" "${EXCLUDED}" "${WATCHED}"; then
        # Clear dedup state so alerts can fire fresh after the baseline change
        clear_alert_state "${SITE_NAME}"

        if (( NOTIFY == 1 )); then
            send_telegram "🔄 <b>CL WP Sentinel — Baseline Updated</b>
📍 <b>Host:</b> $(escape_html "$(get_alert_host)")
🌐 <b>Site:</b> $(escape_html "${SITE_NAME}")
📅 <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

Alert history cleared. Fresh monitoring is now active."
        fi

        UPDATED=$(( UPDATED + 1 ))
    else
        log ERROR "Baseline update had errors for '${SITE_NAME}' — check log for details"
        if (( NOTIFY == 1 )); then
            send_telegram "⚠️ <b>CL WP Sentinel — Baseline Update Warning</b>
📍 <b>Host:</b> $(escape_html "$(get_alert_host)")
🌐 <b>Site:</b> $(escape_html "${SITE_NAME}")
📅 <b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')

Baseline update completed with errors. Check the log for details."
        fi
    fi
done

if (( UPDATED == 0 )); then
    if [[ -n "${SPECIFIC_SITE}" ]]; then
        log ERROR "Site '${SPECIFIC_SITE}' not found in ${SITES_DIR}"
        exit 1
    else
        log WARN "No site configs found in ${SITES_DIR}"
    fi
fi

log INFO "====== Baseline update complete (${UPDATED} site(s) updated) ======"
