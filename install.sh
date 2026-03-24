#!/usr/bin/env bash
# =============================================================================
# CL WP Sentinel - Interactive installer
#
# One-liner install:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/cl-wp-sentinel/main/install.sh)
#
# What this script does:
#   1. Checks prerequisites (wp-cli, curl, sha256sum, ...)
#   2. Downloads / updates CL WP Sentinel scripts to /opt/cl-wp-sentinel
#   3. Asks for Telegram credentials and tests the connection
#   4. Detects WordPress installations (GridPane convention) or asks manually
#   5. Configures each site (excluded dirs, watched files)
#   6. Writes /etc/cl-wp-sentinel/config.sh and per-site configs
#   7. Creates initial baselines for all sites
#   8. Sets up a cron job in /etc/cron.d/cl-wp-sentinel
#   9. Creates convenience symlinks in /usr/local/bin
# =============================================================================

set -euo pipefail

# ─── Repo settings (update before distributing) ───────────────────────────────
GITHUB_USER="YOUR_GITHUB_USER"
GITHUB_REPO="cl-wp-sentinel"
GITHUB_BRANCH="main"
REPO_URL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# ─── Install paths ────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/cl-wp-sentinel"
CONFIG_DIR="/etc/cl-wp-sentinel"
DATA_DIR="/var/lib/cl-wp-sentinel"
LOG_DIR="/var/log/cl-wp-sentinel"
CRON_FILE="/etc/cron.d/cl-wp-sentinel"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── UI helpers ───────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${BOLD}${BLUE}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║          CL WP Sentinel  v1.0.0             ║"
    echo "  ║    WordPress Security Monitor & Alert    ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${RESET}"
}

step()    { echo -e "\n${BOLD}${BLUE}▶ $*${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
err()     { echo -e "  ${RED}✗${RESET}  $*" >&2; }
info()    { echo -e "  ${BLUE}ℹ${RESET}  $*"; }

ask() {
    local prompt="$1" default="${2:-}" response
    if [[ -n "${default}" ]]; then
        read -rp "  $(echo -e "${BOLD}${prompt}${RESET}") [${default}]: " response
        echo "${response:-${default}}"
    else
        while true; do
            read -rp "  $(echo -e "${BOLD}${prompt}${RESET}"): " response
            [[ -n "${response}" ]] && break
            err "Value required"
        done
        echo "${response}"
    fi
}

ask_optional() {
    local prompt="$1" default="${2:-}" response
    read -rp "  $(echo -e "${BOLD}${prompt}${RESET}") [${default}]: " response
    echo "${response:-${default}}"
}

ask_secret() {
    local prompt="$1" response
    read -rsp "  $(echo -e "${BOLD}${prompt}${RESET}"): " response
    echo "" >&2  # newline after hidden input
    echo "${response}"
}

confirm() {
    local prompt="$1" default="${2:-y}" response
    read -rp "  $(echo -e "${BOLD}${prompt}${RESET}") [${default}]: " response
    response="${response:-${default}}"
    [[ "${response,,}" =~ ^y ]]
}

# ─── Step 1: Prerequisites ────────────────────────────────────────────────────
check_prerequisites() {
    step "Checking prerequisites"

    if [[ "${EUID}" -ne 0 ]]; then
        err "Must be run as root (sudo or root user)"
        exit 1
    fi
    ok "Running as root"

    # Required tools
    local all_ok=1
    for cmd in curl find sha256sum comm stat; do
        if command -v "${cmd}" &>/dev/null; then
            ok "Found: ${cmd}"
        else
            err "Missing required tool: ${cmd}"
            all_ok=0
        fi
    done

    # WP-CLI (warn but don't block — user may have it elsewhere)
    if command -v wp &>/dev/null; then
        WP_CLI_PATH=$(command -v wp)
        ok "Found wp-cli: ${WP_CLI_PATH}"
    elif [[ -x "/usr/local/bin/wp" ]]; then
        WP_CLI_PATH="/usr/local/bin/wp"
        ok "Found wp-cli: ${WP_CLI_PATH}"
    else
        warn "wp-cli not found in PATH or /usr/local/bin/wp"
        info "Install with:"
        info "  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
        info "  chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp"
        if ! confirm "Continue without verifying wp-cli?" "n"; then
            exit 1
        fi
        WP_CLI_PATH=$(ask_optional "wp-cli path" "/usr/local/bin/wp")
    fi

    # git (optional, for clone)
    command -v git &>/dev/null && HAS_GIT=1 || HAS_GIT=0

    (( all_ok == 1 )) || exit 1
}

# ─── Step 2: Download scripts ─────────────────────────────────────────────────
download_scripts() {
    step "Downloading CL WP Sentinel scripts to ${INSTALL_DIR}"

    if (( HAS_GIT == 1 )); then
        if [[ -d "${INSTALL_DIR}/.git" ]]; then
            info "Existing git repo found — pulling latest changes..."
            git -C "${INSTALL_DIR}" pull --ff-only
            ok "Scripts updated via git pull"
        else
            git clone --depth=1 "${REPO_URL}" "${INSTALL_DIR}"
            ok "Repository cloned to ${INSTALL_DIR}"
        fi
    else
        warn "git not available — downloading individual files"
        mkdir -p "${INSTALL_DIR}"/{lib,checks,config}

        local files=(
            "run-all.sh"
            "update-baseline.sh"
            "lib/utils.sh"
            "lib/notify.sh"
            "lib/baseline.sh"
            "checks/core.sh"
            "checks/plugins.sh"
            "checks/new-files.sh"
            "checks/watched-files.sh"
        )

        for f in "${files[@]}"; do
            curl -fsSL "${GITHUB_RAW}/${f}" -o "${INSTALL_DIR}/${f}"
            ok "Downloaded: ${f}"
        done
    fi

    find "${INSTALL_DIR}" -name "*.sh" -exec chmod +x {} \;
    ok "Scripts are executable"
}

# ─── Step 3: Telegram configuration ──────────────────────────────────────────
configure_telegram() {
    step "Configuring Telegram notifications"

    echo ""
    info "You need a Telegram bot. If you don't have one:"
    info "  1. Open Telegram and message @BotFather"
    info "  2. Send /newbot and follow the prompts"
    info "  3. Copy the API token you receive"
    echo ""

    local bot_token chat_id

    while true; do
        bot_token=$(ask_secret "Telegram Bot Token (input hidden)")
        [[ -n "${bot_token}" ]] && break
        err "Token cannot be empty"
    done

    echo ""
    info "To get your Chat ID:"
    info "  1. Send any message to your bot first"
    info "  2. Open: https://api.telegram.org/bot<TOKEN>/getUpdates"
    info "  3. Look for: \"chat\":{\"id\": 123456789}"
    info "  (Negative IDs like -100... are group/channel chats)"
    echo ""

    chat_id=$(ask "Telegram Chat ID")

    # Test the connection
    echo ""
    info "Testing Telegram connection..."
    local response
    response=$(curl -s \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=🔐 <b>CL WP Sentinel installed</b>
📍 <b>Host:</b> $(hostname -f 2>/dev/null || hostname)
📅 $(date '+%Y-%m-%d %H:%M:%S')

Monitoring is now active." 2>&1)

    if echo "${response}" | grep -q '"ok":true'; then
        ok "Telegram test message sent successfully!"
    else
        warn "Telegram test failed. Response:"
        echo "    ${response}" | head -3
        if ! confirm "Continue anyway?" "n"; then
            exit 1
        fi
    fi

    TELEGRAM_BOT_TOKEN="${bot_token}"
    TELEGRAM_CHAT_ID="${chat_id}"
}

# ─── Step 4: General settings ─────────────────────────────────────────────────
configure_general() {
    step "General settings"

    ALERT_DEDUP_HOURS=$(ask_optional "Alert dedup window (hours) — same alert won't repeat within this window" "24")
    LOG_RETENTION_DAYS=$(ask_optional "Log retention (days)" "30")
}

# ─── Step 5: Discover WordPress sites ────────────────────────────────────────
discover_sites() {
    step "WordPress site discovery"

    local detected=()

    # GridPane: wp-config.php lives one level above htdocs for security
    #   /var/www/DOMAIN/wp-config.php  ← detected here
    #   /var/www/DOMAIN/htdocs/        ← used as site path (WP-CLI searches parent dirs)
    # This naturally excludes /22222, phpmyadmin and *.gridpanevps.com stat dirs
    # (those don't have wp-config.php directly under /var/www/DOMAIN/).
    for wp_config in /var/www/*/wp-config.php; do
        [[ -f "${wp_config}" ]] || continue
        local htdocs="${wp_config%/wp-config.php}/htdocs"
        [[ -d "${htdocs}" ]] && detected+=("${htdocs}")
    done

    # Fallback for non-GridPane layouts
    for candidate in /var/www/html /srv/www/*/public_html /home/*/public_html; do
        [[ -f "${candidate}/wp-config.php" ]] && detected+=("${candidate}")
    done

    SITES=()

    if (( ${#detected[@]} > 0 )); then
        echo ""
        info "Detected WordPress installations — confirm each one to monitor:"
        echo ""

        for site_path in "${detected[@]}"; do
            local display_name
            display_name=$(echo "${site_path}" | sed 's|/var/www/||; s|/htdocs||')
            if confirm "  Monitor '${display_name}' (${site_path})?" "y"; then
                SITES+=("${site_path}")
                ok "Added: ${site_path}"
            else
                info "Skipped: ${site_path}"
            fi
        done

        echo ""
        if confirm "Add more sites manually?" "n"; then
            while true; do
                local path; path=$(ask_optional "WordPress path (empty to finish)" "")
                [[ -z "${path}" ]] && break
                if [[ ! -f "${path}/wp-config.php" ]]; then
                    warn "wp-config.php not found at '${path}'"
                    confirm "Add anyway?" "n" && SITES+=("${path}") || true
                else
                    SITES+=("${path}")
                    ok "Added: ${path}"
                fi
            done
        fi
    else
        warn "No WordPress installations found in /var/www/*/htdocs/"
        info "Enter paths manually (empty to finish):"
        while true; do
            local path; path=$(ask_optional "WordPress path (empty to finish)" "")
            [[ -z "${path}" ]] && break
            SITES+=("${path}")
            ok "Added: ${path}"
        done
    fi

    if (( ${#SITES[@]} == 0 )); then
        err "No sites configured — aborting"
        exit 1
    fi

    ok "${#SITES[@]} site(s) will be configured"
}

# ─── Step 6: Configure each site ─────────────────────────────────────────────
configure_site() {
    local site_path="$1"

    # Try to auto-detect domain from path (GridPane: /var/www/DOMAIN/htdocs)
    local auto_name
    auto_name=$(echo "${site_path}" \
        | sed 's|/var/www/||; s|/htdocs||; s|/public_html||; s|/html||' \
        | tr -cd '[:alnum:]._-' )

    # Try wp-cli for the actual site URL
    local wp_domain=""
    if [[ -x "${WP_CLI_PATH:-/usr/local/bin/wp}" ]]; then
        wp_domain=$("${WP_CLI_PATH}" --path="${site_path}" --allow-root \
            option get siteurl 2>/dev/null \
            | sed 's|https\?://||; s|/$||' || true)
    fi

    local suggested_domain="${wp_domain:-${auto_name}}"
    local suggested_name
    suggested_name=$(echo "${suggested_domain}" \
        | sed 's/[^a-zA-Z0-9_-]/_/g' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/__*/_/g; s/^_//; s/_$//')

    echo ""
    step "Configuring site: ${site_path}"

    local site_name; site_name=$(ask_optional "Site identifier (used in alerts & filenames)" "${suggested_name}")
    local site_domain; site_domain=$(ask_optional "Site domain (shown in alerts)" "${suggested_domain}")

    echo ""
    info "Directories to EXCLUDE from new-file monitoring (relative to wp-content/):"
    info "  e.g. uploads cache et-cache wpo-cache w3tc"
    local excluded_dirs
    excluded_dirs=$(ask_optional "Excluded dirs (space-separated)" "uploads cache et-cache")

    echo ""
    info "Files to WATCH for content/timestamp changes (relative to WP root):"
    info "  e.g. wp-config.php .htaccess wp-login.php index.php"
    local watched_files
    watched_files=$(ask_optional "Watched files (space-separated)" "wp-config.php .htaccess wp-login.php index.php")

    echo ""

    # Write site config
    mkdir -p "${CONFIG_DIR}/sites"
    local conf_file="${CONFIG_DIR}/sites/${site_name}.conf"

    cat > "${conf_file}" << EOF
# CL WP Sentinel - Site Configuration
# Site:      ${site_domain}
# Path:      ${site_path}
# Generated: $(date)
#
# Edit this file to adjust per-site settings.
# Run update-baseline.sh --site=${site_name} after changes.

SITE_NAME="${site_name}"
SITE_PATH="${site_path}"
SITE_DOMAIN="${site_domain}"

# Directories excluded from new-file monitoring (relative to wp-content/)
# Add any cache or dynamic-content directories your plugins use.
EXCLUDED_DIRS="${excluded_dirs}"

# Files watched for content and timestamp changes (relative to WP root).
# Alert fires if SHA-256 checksum or mtime changes.
WATCHED_FILES=(${watched_files})
EOF

    ok "Site config: ${conf_file}"
    echo "${site_name}"  # return value
}

# ─── Step 7: Write global config ──────────────────────────────────────────────
write_global_config() {
    step "Writing global configuration"

    mkdir -p "${CONFIG_DIR}"

    cat > "${CONFIG_DIR}/config.sh" << EOF
# CL WP Sentinel - Global Configuration
# Generated: $(date)
#
# SECURITY: This file contains your Telegram token. Keep permissions at 600.

# ─── Telegram ─────────────────────────────────────────────────────────────────
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"

# ─── Alert deduplication ──────────────────────────────────────────────────────
# Same alert will not be re-sent within this many hours.
ALERT_DEDUP_HOURS="${ALERT_DEDUP_HOURS:-24}"

# ─── Logging ──────────────────────────────────────────────────────────────────
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOG_DIR="${LOG_DIR}"

# ─── Paths ────────────────────────────────────────────────────────────────────
DATA_DIR="${DATA_DIR}"
WP_CLI="${WP_CLI_PATH:-/usr/local/bin/wp}"
INSTALL_DIR="${INSTALL_DIR}"
EOF

    chmod 600 "${CONFIG_DIR}/config.sh"
    ok "Global config: ${CONFIG_DIR}/config.sh (permissions: 600)"
}

# ─── Step 8: Create directories ───────────────────────────────────────────────
create_directories() {
    mkdir -p "${CONFIG_DIR}/sites"
    mkdir -p "${DATA_DIR}"
    mkdir -p "${LOG_DIR}"
    ok "Directories created"
}

# ─── Step 9: Create initial baselines ────────────────────────────────────────
create_initial_baselines() {
    step "Creating initial baselines"

    # shellcheck source=/dev/null
    source "${CONFIG_DIR}/config.sh"
    source "${INSTALL_DIR}/lib/utils.sh"
    source "${INSTALL_DIR}/lib/baseline.sh"

    for site_config in "${CONFIG_DIR}/sites/"*.conf; do
        [[ -f "${site_config}" ]] || continue

        unset SITE_NAME SITE_PATH EXCLUDED_DIRS
        WATCHED_FILES=()

        # shellcheck source=/dev/null
        source "${site_config}"

        local watched="${WATCHED_FILES[*]:-wp-config.php .htaccess}"
        update_all_baselines \
            "${SITE_NAME}" \
            "${SITE_PATH}" \
            "${EXCLUDED_DIRS:-uploads}" \
            "${watched}"
    done

    ok "All baselines created"
}

# ─── Step 10: Cron setup ──────────────────────────────────────────────────────
setup_cron() {
    step "Setting up cron job"

    echo ""
    info "How often should checks run?"
    echo "    1) Every 15 minutes  (recommended)"
    echo "    2) Every 30 minutes"
    echo "    3) Every hour"
    echo "    4) Custom cron expression"
    echo ""

    local choice; choice=$(ask_optional "Choice" "1")
    local schedule
    case "${choice}" in
        1) schedule="*/15 * * * *" ;;
        2) schedule="*/30 * * * *" ;;
        3) schedule="0 * * * *"    ;;
        4) schedule=$(ask "Custom cron expression") ;;
        *) schedule="*/15 * * * *" ;;
    esac

    cat > "${CRON_FILE}" << EOF
# CL WP Sentinel - WordPress Security Monitor
# Generated: $(date)
# Edit schedule or remove this file to disable monitoring.

SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Security checks
${schedule} root ${INSTALL_DIR}/run-all.sh >> ${LOG_DIR}/cron.log 2>&1

# Weekly cleanup of old rotated logs
0 3 * * 0 root find ${LOG_DIR} -name "cl-wp-sentinel.log.*" -mtime +${LOG_RETENTION_DAYS:-30} -delete 2>/dev/null
EOF

    chmod 644 "${CRON_FILE}"
    ok "Cron: ${CRON_FILE} (schedule: ${schedule})"
}

# ─── Step 11: Convenience symlinks ────────────────────────────────────────────
create_symlinks() {
    ln -sf "${INSTALL_DIR}/run-all.sh"         /usr/local/bin/cl-wp-sentinel
    ln -sf "${INSTALL_DIR}/update-baseline.sh" /usr/local/bin/cl-wp-sentinel-update-baseline
    ok "Commands available: cl-wp-sentinel, cl-wp-sentinel-update-baseline"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${GREEN}  ║    CL WP Sentinel installed successfully!   ║${RESET}"
    echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Quick reference:${RESET}"
    echo "    cl-wp-sentinel                        Run all checks now"
    echo "    cl-wp-sentinel --dry-run              Test without sending alerts"
    echo "    cl-wp-sentinel --site=NAME            Check one site"
    echo "    cl-wp-sentinel --check=core           Run only core check"
    echo "    cl-wp-sentinel-update-baseline        Refresh baseline (all sites)"
    echo "    cl-wp-sentinel-update-baseline --site=NAME   Refresh one site"
    echo ""
    echo -e "  ${BOLD}Key paths:${RESET}"
    echo "    Config:    ${CONFIG_DIR}/config.sh"
    echo "    Sites:     ${CONFIG_DIR}/sites/"
    echo "    Data:      ${DATA_DIR}/"
    echo "    Logs:      ${LOG_DIR}/cl-wp-sentinel.log"
    echo "    Cron:      ${CRON_FILE}"
    echo ""
    echo -e "  ${BOLD}After plugin/core updates, run:${RESET}"
    echo "    cl-wp-sentinel-update-baseline"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    print_banner

    # Handle update-only mode
    if [[ -d "${INSTALL_DIR}" ]] && [[ -f "${CONFIG_DIR}/config.sh" ]]; then
        warn "CL WP Sentinel is already installed at ${INSTALL_DIR}"
        echo ""
        echo "    1) Update scripts only (keep all configuration)"
        echo "    2) Full reinstall (reconfigure everything)"
        echo "    3) Abort"
        echo ""
        local choice; choice=$(ask_optional "Choice" "1")
        case "${choice}" in
            1)
                check_prerequisites
                download_scripts
                ok "Scripts updated. Configuration unchanged."
                exit 0
                ;;
            2) : ;;  # continue with full install
            *) echo "Aborted."; exit 0 ;;
        esac
    fi

    check_prerequisites
    download_scripts
    configure_telegram
    configure_general
    create_directories
    write_global_config
    discover_sites

    CONFIGURED_SITES=()
    for site_path in "${SITES[@]}"; do
        site_name=$(configure_site "${site_path}")
        CONFIGURED_SITES+=("${site_name}")
    done

    create_initial_baselines
    setup_cron
    create_symlinks
    print_summary
}

main "$@"
