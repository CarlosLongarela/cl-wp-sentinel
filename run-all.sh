#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Run all security checks across all configured sites
#
# Usage:
#   run-all.sh [options]
#
# Options:
#   --dry-run           Print what would be sent without sending Telegram alerts
#   --site=NAME         Only check the specified site (by SITE_NAME in config)
#   --check=TYPE        Only run one check type:
#                         core | plugins | files | watched | admins | uploads | active
#   --help              Show this help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${WP_SENTINEL_CONFIG_DIR:-/etc/cl-wp-sentinel}"
SITES_DIR="${CONFIG_DIR}/sites"

# ─── Parse arguments ──────────────────────────────────────────────────────────
DRY_RUN=0
SPECIFIC_SITE=""
SPECIFIC_CHECK=""

for arg in "$@"; do
    case "${arg}" in
        --dry-run)     DRY_RUN=1 ;;
        --site=*)      SPECIFIC_SITE="${arg#*=}" ;;
        --check=*)     SPECIFIC_CHECK="${arg#*=}" ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}. Use --help for usage." >&2
            exit 1
            ;;
    esac
done

export DRY_RUN

# ─── Load global config ───────────────────────────────────────────────────────
if [[ ! -f "${CONFIG_DIR}/config.sh" ]]; then
    echo "ERROR: Global config not found at ${CONFIG_DIR}/config.sh"
    echo "       Run install.sh to set up CL WP Sentinel."
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_DIR}/config.sh"

# ─── Source libraries and checks ─────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/notify.sh"
source "${SCRIPT_DIR}/lib/baseline.sh"
source "${SCRIPT_DIR}/checks/core.sh"
source "${SCRIPT_DIR}/checks/plugins.sh"
source "${SCRIPT_DIR}/checks/new-files.sh"
source "${SCRIPT_DIR}/checks/watched-files.sh"
source "${SCRIPT_DIR}/checks/admin-users.sh"
source "${SCRIPT_DIR}/checks/php-in-uploads.sh"
source "${SCRIPT_DIR}/checks/active-plugins.sh"

# ─── Validate ─────────────────────────────────────────────────────────────────
check_prerequisites

if [[ ! -d "${SITES_DIR}" ]] || ! compgen -G "${SITES_DIR}/*.conf" > /dev/null 2>&1; then
    log ERROR "No sites configured in ${SITES_DIR}. Run install.sh first."
    exit 1
fi

if [[ -n "${SPECIFIC_CHECK}" ]] && \
   [[ ! "${SPECIFIC_CHECK}" =~ ^(core|plugins|files|watched|admins|uploads|active)$ ]]; then
    log ERROR "Invalid --check value '${SPECIFIC_CHECK}'. Use: core | plugins | files | watched | admins | uploads | active"
    exit 1
fi

# ─── Lock to prevent overlapping cron runs ───────────────────────────────────
trap release_lock EXIT
acquire_lock

# ─── Main loop ────────────────────────────────────────────────────────────────
log INFO "====== CL WP Sentinel started — host: $(get_hostname) ======"
[[ "${DRY_RUN}" == "1" ]] && log INFO "*** DRY-RUN mode — no Telegram messages will be sent ***"

OVERALL_EXIT=0

for site_config in "${SITES_DIR}"/*.conf; do
    [[ -f "${site_config}" ]] || continue

    # Reset site vars to avoid leaking between sites
    unset SITE_NAME SITE_PATH SITE_DOMAIN EXCLUDED_DIRS
    WATCHED_FILES=()

    # shellcheck source=/dev/null
    source "${site_config}"

    # Apply --site filter
    if [[ -n "${SPECIFIC_SITE}" && "${SITE_NAME}" != "${SPECIFIC_SITE}" ]]; then
        continue
    fi

    log INFO "------ Site: ${SITE_NAME} (${SITE_DOMAIN:-${SITE_PATH}}) ------"

    if [[ ! -d "${SITE_PATH}" ]]; then
        log ERROR "Site path not found: ${SITE_PATH} — skipping '${SITE_NAME}'"
        OVERALL_EXIT=1
        continue
    fi

    SITE_EXIT=0
    EXCLUDED="${EXCLUDED_DIRS:-uploads}"

    # Run the appropriate checks
    if [[ -z "${SPECIFIC_CHECK}" || "${SPECIFIC_CHECK}" == "core" ]]; then
        run_core_check    "${SITE_NAME}" "${SITE_PATH}"            || SITE_EXIT=1
    fi

    if [[ -z "${SPECIFIC_CHECK}" || "${SPECIFIC_CHECK}" == "plugins" ]]; then
        run_plugins_check "${SITE_NAME}" "${SITE_PATH}"            || SITE_EXIT=1
    fi

    if [[ -z "${SPECIFIC_CHECK}" || "${SPECIFIC_CHECK}" == "files" ]]; then
        run_new_files_check "${SITE_NAME}" "${SITE_PATH}" "${EXCLUDED}" || SITE_EXIT=1
    fi

    if [[ -z "${SPECIFIC_CHECK}" || "${SPECIFIC_CHECK}" == "watched" ]]; then
        run_watched_files_check "${SITE_NAME}" "${SITE_PATH}"     || SITE_EXIT=1
    fi

    if [[ -z "${SPECIFIC_CHECK}" || "${SPECIFIC_CHECK}" == "admins" ]]; then
        run_admin_users_check       "${SITE_NAME}" "${SITE_PATH}" || SITE_EXIT=1
    fi

    if [[ -z "${SPECIFIC_CHECK}" || "${SPECIFIC_CHECK}" == "uploads" ]]; then
        run_php_in_uploads_check    "${SITE_NAME}" "${SITE_PATH}" || SITE_EXIT=1
    fi

    if [[ -z "${SPECIFIC_CHECK}" || "${SPECIFIC_CHECK}" == "active" ]]; then
        run_active_plugins_check    "${SITE_NAME}" "${SITE_PATH}" || SITE_EXIT=1
    fi

    if (( SITE_EXIT != 0 )); then
        OVERALL_EXIT=1
        log WARN "------ Site '${SITE_NAME}': checks finished WITH ISSUES ------"
    else
        log INFO "------ Site '${SITE_NAME}': all checks PASSED ------"
    fi
done

log INFO "====== CL WP Sentinel finished — status: $( (( OVERALL_EXIT == 0 )) && echo OK || echo FAILED) ======"
exit ${OVERALL_EXIT}
