# CL WP Sentinel

WordPress security monitor for Linux servers. Runs periodic checks via cron and sends Telegram alerts when something changes.

## What it checks

| Check | How |
|---|---|
| **Core integrity** | `wp core verify-checksums` — compares all WP core files against wp.org checksums |
| **Plugin integrity** | `wp plugin verify-checksums --all` — same for all installed plugins |
| **New files** | Detects files added to the WP root or `wp-content/` that weren't there at baseline |
| **Watched files** | SHA-256 checksum + mtime monitoring of critical files (`wp-config.php`, `.htaccess`, etc.) |
| **Admin users** | Alerts if new administrator accounts appear since the baseline snapshot |
| **PHP in uploads** | Detects `.php`, `.phar`, `.phtml`, etc. inside `wp-content/uploads/` — no baseline needed, zero false positives |
| **Active plugins/theme** | Alerts if a plugin is activated or the active theme changes since baseline |

Alerts are sent via **Telegram** with deduplication (same alert will not repeat within a configurable window).

---

## Requirements

- Linux server running as root (designed for [GridPane](https://gridpane.com) but works on any distro)
- [WP-CLI](https://wp-cli.org/) installed globally at `/usr/local/bin/wp`
- `curl`, `sha256sum`, `find`, `comm`, `stat` — standard on any modern Linux distro
- A Telegram bot token and chat ID (see [Telegram setup](#telegram-setup) below)

---

## Installation

### One-liner (recommended)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/CarlosLongarela/cl-wp-sentinel/main/install.sh)
```

The installer will:
1. Check prerequisites (`curl`, `sha256sum`, `wp-cli`, etc.)
2. Clone the repository to `/opt/cl-wp-sentinel`
3. Ask for your Telegram bot token and chat ID, and test the connection live
4. Auto-detect WordPress installations (`/var/www/*/wp-config.php` — GridPane convention)
5. Let you confirm each detected site and add more manually
6. Configure each site: excluded dirs, watched files
7. Write `/etc/cl-wp-sentinel/config.sh` and per-site configs under `/etc/cl-wp-sentinel/sites/`
8. Create initial baselines for all sites
9. Set up a cron job in `/etc/cron.d/cl-wp-sentinel`
10. Create convenience commands: `cl-wp-sentinel` and `cl-wp-sentinel-update-baseline`

### Manual installation

```bash
git clone https://github.com/CarlosLongarela/cl-wp-sentinel /opt/cl-wp-sentinel
chmod +x /opt/cl-wp-sentinel/*.sh \
         /opt/cl-wp-sentinel/checks/*.sh \
         /opt/cl-wp-sentinel/lib/*.sh
bash /opt/cl-wp-sentinel/install.sh
```

---

## Telegram setup

You need a Telegram bot to receive alerts. This takes about 2 minutes.

### 1. Create the bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot`
3. Follow the prompts — choose a name and a username (must end in `bot`)
4. BotFather will reply with your **bot API token**: `123456789:ABCdef...`
   → Copy this, you will need it during installation

### 2. Get your Chat ID

The Chat ID tells the bot where to send messages (your personal chat, a group, or a channel).

**Personal chat (simplest):**
1. Send any message to your new bot (e.g. `/start`)
2. Open this URL in a browser (replace `TOKEN` with your actual token):
   ```
   https://api.telegram.org/botTOKEN/getUpdates
   ```
3. Find `"chat":{"id": 123456789}` in the JSON — that number is your Chat ID

**Group chat:**
1. Add the bot to the group
2. Send a message in the group mentioning the bot
3. Call `getUpdates` as above — the Chat ID will be a negative number like `-1001234567890`

**Channel:**
1. Add the bot as an administrator of the channel
2. Forward any channel message to `@userinfobot` to get the channel ID
3. Channel IDs look like `-1001234567890`

### 3. Testing without installing

You can test your credentials manually before running the installer:

```bash
curl -X POST "https://api.telegram.org/botTOKEN/sendMessage" \
  -d "chat_id=CHAT_ID" \
  -d "text=Test from CL WP Sentinel"
```

You should receive a Telegram message. If not, check your token and chat ID.

### If Telegram configuration fails or needs updating

Edit the global config file directly:

```bash
nano /etc/cl-wp-sentinel/config.sh
```

Update `TELEGRAM_BOT_TOKEN` and/or `TELEGRAM_CHAT_ID`, then test:

```bash
cl-wp-sentinel --dry-run
```

---

## Usage

```bash
# Run all checks on all sites
cl-wp-sentinel

# Test mode — shows what would be alerted without sending Telegram messages
cl-wp-sentinel --dry-run

# Check a specific site only
cl-wp-sentinel --site=example_com

# Run only one type of check (across all sites)
cl-wp-sentinel --check=core       # WP core file integrity
cl-wp-sentinel --check=plugins    # Plugin file integrity
cl-wp-sentinel --check=files      # New file detection
cl-wp-sentinel --check=watched    # Watched file checksums/timestamps
cl-wp-sentinel --check=admins     # Admin user count
cl-wp-sentinel --check=uploads    # PHP files in uploads
cl-wp-sentinel --check=active     # Active plugins and theme

# Combine filters
cl-wp-sentinel --site=example_com --check=watched
```

### Updating the baseline

Run this after any **intentional** change: core update, plugin install/update, editing `wp-config.php`, adding a new admin user, activating a plugin, etc.

```bash
# Update baseline for all sites
cl-wp-sentinel-update-baseline

# Update baseline for a specific site only
cl-wp-sentinel-update-baseline --site=example_com

# Update without sending a Telegram confirmation
cl-wp-sentinel-update-baseline --no-notify
```

After a baseline update, the alert deduplication state is cleared so that any new issues generate fresh alerts immediately.

---

## Adding a new site after installation

```bash
# 1. Copy the example site config
cp /opt/cl-wp-sentinel/config/site.example.conf /etc/cl-wp-sentinel/sites/newsite_com.conf

# 2. Edit it with your site details
nano /etc/cl-wp-sentinel/sites/newsite_com.conf

# 3. Create the initial baseline for the new site
cl-wp-sentinel-update-baseline --site=newsite_com

# 4. Do a dry-run to verify everything works
cl-wp-sentinel --site=newsite_com --dry-run
```

---

## File structure

```
/opt/cl-wp-sentinel/               Scripts — managed by git, do not edit
├── install.sh
├── run-all.sh
├── update-baseline.sh
├── lib/
│   ├── utils.sh                   Logging, lock management, WP-CLI wrapper
│   ├── notify.sh                  Telegram alerts with deduplication
│   └── baseline.sh                Baseline creation and management
├── checks/
│   ├── core.sh                    WP core integrity
│   ├── plugins.sh                 Plugin integrity
│   ├── new-files.sh               New file detection
│   ├── watched-files.sh           Watched file checksums/timestamps
│   ├── admin-users.sh             Admin user monitoring
│   ├── php-in-uploads.sh          PHP files in uploads
│   └── active-plugins.sh          Active plugins and theme
└── config/
    ├── config.example.sh          Global config template
    └── site.example.conf          Per-site config template

/etc/cl-wp-sentinel/               Configuration — yours to edit
├── config.sh                      Global settings (Telegram token, paths) — mode 600
└── sites/
    ├── example_com.conf           Per-site configuration
    └── another_site.conf

/var/lib/cl-wp-sentinel/           Baseline data — generated, do not edit manually
├── example_com/
│   ├── files.baseline             List of all tracked files
│   ├── checksums.baseline         SHA-256 + mtime for watched files
│   ├── admin-users.baseline       List of administrator logins
│   ├── active-plugins.baseline    List of active plugin slugs
│   └── active-theme.baseline      Currently active theme name
└── state/
    └── example_com/
        └── alert_<hash>           Dedup timestamps for sent alerts

/var/log/cl-wp-sentinel/           Logs
├── cl-wp-sentinel.log             Main log (auto-rotated at 10 MB, kept 30 days)
└── cron.log                       stdout/stderr from cron runs

/etc/cron.d/cl-wp-sentinel         Cron job definition
/usr/local/bin/cl-wp-sentinel      Symlink → run-all.sh
/usr/local/bin/cl-wp-sentinel-update-baseline   Symlink → update-baseline.sh
```

---

## Configuration reference

### Global config — `/etc/cl-wp-sentinel/config.sh`

> **Security:** This file contains your Telegram token. Permissions are set to `600` automatically.

```bash
# Telegram
TELEGRAM_BOT_TOKEN="123456789:ABCdef..."   # From @BotFather
TELEGRAM_CHAT_ID="123456789"               # Your chat / group / channel ID

# Alert behaviour
ALERT_DEDUP_HOURS="24"     # Same alert will not repeat within this many hours

# Logging
LOG_RETENTION_DAYS="30"    # Days to keep rotated log files
LOG_DIR="/var/log/cl-wp-sentinel"

# Paths
DATA_DIR="/var/lib/cl-wp-sentinel"
WP_CLI="/usr/local/bin/wp"
INSTALL_DIR="/opt/cl-wp-sentinel"
```

### Per-site config — `/etc/cl-wp-sentinel/sites/SITE_NAME.conf`

```bash
SITE_NAME="example_com"                     # Identifier — no spaces, used in filenames
SITE_PATH="/var/www/example.com/htdocs"     # Absolute path to WP root
SITE_DOMAIN="example.com"                   # Shown in alert messages

# Directories inside wp-content/ excluded from new-file detection.
# Add any folder where your setup legitimately creates files dynamically.
EXCLUDED_DIRS="uploads cache et-cache wpo-cache"

# Files watched for content (SHA-256) and timestamp (mtime) changes.
# Paths are relative to SITE_PATH.
WATCHED_FILES=(
    wp-config.php
    .htaccess
    wp-login.php
    index.php
)
```

See [`config/site.example.conf`](config/site.example.conf) for a fully commented template.

---

## Updating the scripts

```bash
# Re-run the installer and choose option 1 — "Update scripts only"
bash <(curl -fsSL https://raw.githubusercontent.com/CarlosLongarela/cl-wp-sentinel/main/install.sh)

# Or if installed via git (faster):
cd /opt/cl-wp-sentinel && git pull
```

---

## Telegram alert examples

**Core integrity failure:**
```
🚨 CL WP Sentinel Alert
📍 Host:     myserver.example.com
🌐 Site:     example_com
🔍 Check:    Core Integrity
🔴 Severity: CRITICAL
📅 Time:     2025-03-24 14:30:00

Warning: File modified: wp-includes/class-wp.php
Warning: File added:    wp-includes/evil.php
```

**New file detected:**
```
🚨 CL WP Sentinel Alert
🔍 Check:    New Files Detected

2 new file(s) detected (not in baseline):
  wp-content/themes/twentytwenty/shell.php
  wp-content/plugins/contact-form-7/eval.php
```

**PHP in uploads:**
```
🚨 CL WP Sentinel Alert
🔍 Check:    PHP File(s) in Uploads

1 executable file(s) found in wp-content/uploads/:
  wp-content/uploads/2025/03/image.php

These files should be removed immediately.
```

**New admin user:**
```
🚨 CL WP Sentinel Alert
🔍 Check:    New Admin User(s)

1 new administrator account(s) detected (was 2, now 3):
  • hacker_user
```

**Plugin activated:**
```
🚨 CL WP Sentinel Alert
🔍 Check:    Plugin(s) Activated

1 plugin(s) activated since baseline (was 14 active, now 15):
  • malicious-plugin
```

---

## Troubleshooting

**Alerts not being sent**
- Check the log: `tail -50 /var/log/cl-wp-sentinel/cl-wp-sentinel.log`
- Test with dry-run: `cl-wp-sentinel --dry-run`
- Verify Telegram credentials: `nano /etc/cl-wp-sentinel/config.sh`
- Check if alerts are being deduplicated: `ls /var/lib/cl-wp-sentinel/state/`
  To reset dedup state: `rm -rf /var/lib/cl-wp-sentinel/state/`

**"No baseline found" error**
```bash
cl-wp-sentinel-update-baseline
```

**Too many alerts for premium plugins (no checksums available)**
- CL WP Sentinel already filters out "no checksums available" warnings for plugins not in wp.org
- Check manually: `wp --path=/path/to/site --allow-root plugin verify-checksums --all`

**Lock file error (previous run crashed)**
```bash
rm /var/lib/cl-wp-sentinel/.lock
```

**Enable verbose debug output**
```bash
WP_SENTINEL_DEBUG=1 cl-wp-sentinel --dry-run
```

**Telegram credentials need updating after install**
```bash
nano /etc/cl-wp-sentinel/config.sh   # edit TELEGRAM_BOT_TOKEN and/or TELEGRAM_CHAT_ID
cl-wp-sentinel --dry-run             # verify it works
```

---

## License

MIT
