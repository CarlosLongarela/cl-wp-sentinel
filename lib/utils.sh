#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Common utilities
# =============================================================================

readonly WP_SENTINEL_VERSION="1.0.0"

# Directories (can be overridden before sourcing)
DATA_DIR="${DATA_DIR:-/var/lib/cl-wp-sentinel}"
LOG_DIR="${LOG_DIR:-/var/log/cl-wp-sentinel}"
STATE_DIR="${DATA_DIR}/state"
LOCK_FILE="${DATA_DIR}/.lock"

# ─── Colors (only when interactive) ──────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' BLUE='' BOLD='' RESET=''
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
# Usage: log LEVEL "message"
log() {
    local level="$1"; shift
    local message="$*"
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${LOG_DIR}/cl-wp-sentinel.log"

    mkdir -p "${LOG_DIR}"
    echo "[${timestamp}] [${level}] ${message}" >> "${log_file}"

    case "${level}" in
        ERROR) echo -e "${RED}[${level}]${RESET} ${message}" >&2 ;;
        WARN)  echo -e "${YELLOW}[${level}]${RESET} ${message}" ;;
        INFO)  echo -e "${GREEN}[${level}]${RESET} ${message}" ;;
        DEBUG) [[ "${WP_SENTINEL_DEBUG:-0}" == "1" ]] && echo -e "${BLUE}[${level}]${RESET} ${message}" ;;
    esac

    _rotate_log "${log_file}"
}

_rotate_log() {
    local log_file="$1"
    local max_size=$(( 10 * 1024 * 1024 ))  # 10 MB
    local retention="${LOG_RETENTION_DAYS:-30}"

    [[ -f "${log_file}" ]] || return 0

    local size; size=$(stat -c%s "${log_file}" 2>/dev/null || echo 0)
    if (( size > max_size )); then
        mv "${log_file}" "${log_file}.$(date +%Y%m%d%H%M%S)"
        # Only run the slow find-based cleanup when we actually rotate,
        # not on every log call
        find "${LOG_DIR}" -name "cl-wp-sentinel.log.*" -mtime "+${retention}" -delete 2>/dev/null || true
    fi
}

# ─── Lock management (flock-based, atomic — no TOCTOU race) ──────────────────
# We open fd 9 on the lock file and hold an exclusive non-blocking flock.
# The lock is released automatically when the process exits (fd closes).
acquire_lock() {
    mkdir -p "$(dirname "${LOCK_FILE}")"
    exec 9>>"${LOCK_FILE}"
    if ! flock -n 9; then
        local pid; pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "?")
        log ERROR "Another CL WP Sentinel instance is already running (PID ${pid}). Exiting."
        exit 1
    fi
    # Truncate and write our PID only after acquiring the lock
    truncate -s 0 "${LOCK_FILE}" 2>/dev/null || true
    echo $$ > "${LOCK_FILE}"
}

release_lock() {
    flock -u 9 2>/dev/null || true
    rm -f "${LOCK_FILE}"
}

# ─── WP-CLI wrapper ───────────────────────────────────────────────────────────
# Usage: wp_cli <site_path> [wp-cli args...]
wp_cli() {
    local site_path="$1"; shift
    local bin="${WP_CLI:-/usr/local/bin/wp}"
    "${bin}" --path="${site_path}" --allow-root "$@" 2>&1
}

# ─── HTML escaping (for Telegram HTML mode) ──────────────────────────────────
escape_html() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    echo "${text}"
}

# ─── Truncate long messages ───────────────────────────────────────────────────
truncate_message() {
    local msg="$1"
    local max="${2:-3800}"
    if (( ${#msg} > max )); then
        echo "${msg:0:${max}}"$'\n<i>... (message truncated)</i>'
    else
        echo "${msg}"
    fi
}

# ─── Server hostname ──────────────────────────────────────────────────────────
get_hostname() {
    hostname -f 2>/dev/null || hostname
}

# ─── Prerequisites check ──────────────────────────────────────────────────────
check_prerequisites() {
    local missing=()
    local wp_bin="${WP_CLI:-/usr/local/bin/wp}"

    command -v "${wp_bin}" &>/dev/null || missing+=("wp-cli (expected at ${wp_bin})")
    command -v curl        &>/dev/null || missing+=("curl")
    command -v find        &>/dev/null || missing+=("find")
    command -v sha256sum   &>/dev/null || missing+=("sha256sum (coreutils)")
    command -v comm        &>/dev/null || missing+=("comm (coreutils)")
    command -v stat        &>/dev/null || missing+=("stat (coreutils)")
    command -v flock       &>/dev/null || missing+=("flock (util-linux)")

    if (( ${#missing[@]} > 0 )); then
        log ERROR "Missing required tools: ${missing[*]}"
        exit 1
    fi
}
