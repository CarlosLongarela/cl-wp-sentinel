# CL WP Sentinel - Global Configuration Example
# ─────────────────────────────────────────────────────────────────────────────
# This file is generated automatically by install.sh.
# The real file lives at /etc/cl-wp-sentinel/config.sh (permissions: 600).
# Edit that file directly to change global settings.
# ─────────────────────────────────────────────────────────────────────────────

# ─── Telegram ─────────────────────────────────────────────────────────────────
# Get your token from @BotFather on Telegram.
# Get your chat ID by messaging your bot then visiting:
#   https://api.telegram.org/bot<TOKEN>/getUpdates
TELEGRAM_BOT_TOKEN="123456789:ABCdef..."
TELEGRAM_CHAT_ID="987654321"

# ─── Alert deduplication ──────────────────────────────────────────────────────
# If the exact same alert has already been sent within this window (in hours),
# it will be silently skipped. Prevents notification spam from cron.
# Set to 0 to disable deduplication (every check sends an alert if failing).
ALERT_DEDUP_HOURS="24"

# ─── Logging ──────────────────────────────────────────────────────────────────
# Rotated logs older than this many days are automatically deleted.
LOG_RETENTION_DAYS="30"
LOG_DIR="/var/log/cl-wp-sentinel"

# ─── Paths ────────────────────────────────────────────────────────────────────
DATA_DIR="/var/lib/cl-wp-sentinel"     # Baseline files and alert state
WP_CLI="/usr/local/bin/wp"          # Path to wp-cli binary
INSTALL_DIR="/opt/cl-wp-sentinel"      # Where scripts are installed
