# CL WP Sentinel

WordPress security monitor for Linux servers. Runs periodic checks via cron and sends Telegram alerts when something changes.

## What it checks

| Check | How |
|---|---|
| **Core integrity** | `wp core verify-checksums` — compares all WP core files against wp.org checksums |
| **Plugin integrity** | `wp plugin verify-checksums --all` — same for all installed plugins |
| **New files** | Detects files added to the WP root or `wp-content/` that weren't there at baseline |
| **Watched files** | SHA-256 checksum + mtime monitoring of critical files (wp-config.php, .htaccess, etc.) |
| **Admin users** | Alerts if new administrator accounts appear since the baseline snapshot |
| **PHP en uploads** | Detecta archivos `.php`, `.phar`, `.phtml`, etc. en `wp-content/uploads/` — sin baseline, cero falsos positivos |
| **Plugins/tema activos** | Alerta si se activa un plugin o cambia el tema activo respecto al baseline |

Alerts are sent via **Telegram** with deduplication (same alert won't repeat within a configurable window).

---

## Requirements

- Linux server running as root (designed for [GridPane](https://gridpane.com) but works anywhere)
- [WP-CLI](https://wp-cli.org/) installed globally (`/usr/local/bin/wp`)
- `curl`, `sha256sum`, `find`, `comm`, `stat` (standard on any modern distro)
- A Telegram bot token and chat ID ([how to create a bot](https://core.telegram.org/bots#creating-a-new-bot))

---

## Installation

### One-liner (recommended)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/cl-wp-sentinel/main/install.sh)
```

The installer will:
1. Check prerequisites
2. Clone the repository to `/opt/cl-wp-sentinel`
3. Ask for your Telegram bot token and chat ID (and test the connection)
4. Auto-detect WordPress installations (GridPane convention: `/var/www/*/htdocs`)
5. Configure each site (excluded dirs, watched files)
6. Create initial baselines
7. Set up a cron job in `/etc/cron.d/cl-wp-sentinel`
8. Create convenience commands: `cl-wp-sentinel` and `cl-wp-sentinel-update-baseline`

### Manual installation

```bash
git clone https://github.com/YOUR_USER/cl-wp-sentinel /opt/cl-wp-sentinel
chmod +x /opt/cl-wp-sentinel/*.sh /opt/cl-wp-sentinel/checks/*.sh /opt/cl-wp-sentinel/lib/*.sh
bash /opt/cl-wp-sentinel/install.sh
```

---

## Usage

```bash
# Run all checks on all sites
cl-wp-sentinel

# Run all checks without sending Telegram messages (test mode)
cl-wp-sentinel --dry-run

# Run checks for a specific site only
cl-wp-sentinel --site=example_com

# Run only one type of check
cl-wp-sentinel --check=core
cl-wp-sentinel --check=plugins
cl-wp-sentinel --check=files
cl-wp-sentinel --check=watched

# Combine filters
cl-wp-sentinel --site=example_com --check=watched
```

### Updating the baseline

Run this after any intentional change: core update, plugin install/update, editing wp-config.php, etc.

```bash
# Update baseline for all sites
cl-wp-sentinel-update-baseline

# Update baseline for a specific site
cl-wp-sentinel-update-baseline --site=example_com

# Update without sending Telegram confirmation
cl-wp-sentinel-update-baseline --no-notify
```

After a baseline update, the alert deduplication state is cleared so that any new issues can generate fresh alerts.

---

## File structure (after installation)

```
/opt/cl-wp-sentinel/           Scripts (git-managed)
  install.sh
  run-all.sh
  update-baseline.sh
  lib/
    utils.sh                Logging, lock management, WP-CLI wrapper
    notify.sh               Telegram alerts with deduplication
    baseline.sh             Baseline creation and management
  checks/
    core.sh
    plugins.sh
    new-files.sh
    watched-files.sh

/etc/cl-wp-sentinel/           Configuration (you own this)
  config.sh                 Global settings (Telegram token, paths, etc.) — mode 600
  sites/
    example_com.conf        Per-site configuration
    another_site.conf

/var/lib/cl-wp-sentinel/       Data (generated, do not edit)
  example_com/
    files.baseline          List of all tracked files
    checksums.baseline      SHA-256 + mtime for watched files
  state/
    example_com/
      alert_<hash>          Dedup timestamps for sent alerts

/var/log/cl-wp-sentinel/       Logs
  cl-wp-sentinel.log           Main log (rotated at 10 MB)
  cron.log                  stdout/stderr from cron runs

/etc/cron.d/cl-wp-sentinel     Cron job definition
```

---

## Configuration

### Global config — `/etc/cl-wp-sentinel/config.sh`

```bash
TELEGRAM_BOT_TOKEN="..."     # Your bot's API token
TELEGRAM_CHAT_ID="..."       # Destination chat / group / channel ID

ALERT_DEDUP_HOURS="24"       # Hours before the same alert is re-sent
LOG_RETENTION_DAYS="30"      # Days to keep rotated log files

LOG_DIR="/var/log/cl-wp-sentinel"
DATA_DIR="/var/lib/cl-wp-sentinel"
WP_CLI="/usr/local/bin/wp"
```

### Per-site config — `/etc/cl-wp-sentinel/sites/SITE_NAME.conf`

```bash
SITE_NAME="example_com"                    # Identifier (no spaces)
SITE_PATH="/var/www/example.com/htdocs"    # Absolute WP root path
SITE_DOMAIN="example.com"                  # Shown in alerts

# Directories inside wp-content/ excluded from new-file detection
EXCLUDED_DIRS="uploads cache et-cache wpo-cache"

# Files watched for checksum + mtime changes (relative to SITE_PATH)
WATCHED_FILES=(
    wp-config.php
    .htaccess
    wp-login.php
    index.php
)
```

See [`config/site.example.conf`](config/site.example.conf) for a fully commented template.

---

## Adding a new site

```bash
# Copy the example config
cp /opt/cl-wp-sentinel/config/site.example.conf /etc/cl-wp-sentinel/sites/newsite_com.conf

# Edit it
nano /etc/cl-wp-sentinel/sites/newsite_com.conf

# Create the initial baseline for the new site
cl-wp-sentinel-update-baseline --site=newsite_com

# Test it
cl-wp-sentinel --site=newsite_com --dry-run
```

---

## Updating the scripts

```bash
# Re-run the installer and choose option 1 (update scripts only)
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/cl-wp-sentinel/main/install.sh)

# Or if installed via git:
cd /opt/cl-wp-sentinel && git pull
```

---

## Telegram alert examples

**Core integrity failure:**
```
🚨 CL WP Sentinel Alert
📍 Host: myserver.example.com
🌐 Site: example_com
🔍 Check: Core Integrity
🔴 Severity: CRITICAL
📅 Time: 2025-03-24 14:30:00

wp core verify-checksums failed:
Warning: File modified: wp-includes/class-wp.php
Warning: File added: wp-includes/evil.php
```

**New file detected:**
```
🚨 CL WP Sentinel Alert
🔍 Check: New Files Detected
...
2 new file(s) detected (not in baseline):
wp-content/themes/twentytwenty/shell.php
wp-content/plugins/contact-form-7/eval.php
```

**Watched file changed:**
```
🚨 CL WP Sentinel Alert
🔍 Check: Watched Files Changed
...
✏️  MODIFIED: wp-config.php  [last modified: 2025-03-24 14:28:15]
⏰ TIMESTAMP CHANGED: .htaccess  [was: 2025-01-10 09:00:00 → now: 2025-03-24 14:29:00]
```

---

## Troubleshooting

**No alerts being sent**
- Check `/var/log/cl-wp-sentinel/cl-wp-sentinel.log` for errors
- Test manually: `cl-wp-sentinel --dry-run`
- Verify Telegram credentials in `/etc/cl-wp-sentinel/config.sh`
- Check if alert is being deduplicated: delete files in `/var/lib/cl-wp-sentinel/state/`

**"No baseline found" error**
- Run: `cl-wp-sentinel-update-baseline`

**Too many alerts for premium plugins**
- CL WP Sentinel already filters out "no checksums available" warnings for plugins not in wp.org
- If still getting noise, check the raw output: `wp --path=/path/to/site --allow-root plugin verify-checksums --all`

**Lock file error**
- If a previous run crashed: `rm /tmp/cl-wp-sentinel.lock`

**Enable debug logging**
```bash
WP_SENTINEL_DEBUG=1 cl-wp-sentinel --dry-run
```

---

## License

MIT
