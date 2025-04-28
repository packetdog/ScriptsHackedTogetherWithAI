#!/bin/bash
#
# ----------------------------------------------------------------------
# Script: monitor_logs.sh
#
# Purpose:
#   Monitors and manages LiteSpeed Web Server logs under /usr/local/lsws/logs.
#   Prevents log overgrowth on CyberPanel installs by purging and compressing
#   logs daily, and alerting on abnormal size growth or disk usage issues.
#
# Modes:
#   1. Daily Mode (`monitor_logs.sh daily`)
#      - Runs once daily (e.g., at 6 AM).
#      - Gathers last 75 critical (non-INFO, non-NOTICE) lines from stderr.log
#        and latest error.log.*.
#      - Sends daily report email including:
#        - Log directory size and percent change.
#        - Truncated `ls -al` output (up to 25 lines).
#        - Disk usage (`df -h`) output.
#        - Server uptime (`uptime`) output.
#        - Attachments: stderr and error log excerpts.
#      - Compresses uncompressed logs (*.log) into .gz.
#      - Cleans up temporary working files after sending.
#
#   2. Check Mode (`monitor_logs.sh check`)
#      - Runs every 3 hours.
#      - Compares current log size to previous.
#      - Sends alert email if size grows >25%.
#      - Sends alert if any disk partition exceeds 90% usage.
#
# Features:
#   - Secure email sending via SMTP2GO and msmtp with TLS on port 2525.
#   - Filters non-critical log lines automatically.
#   - Cleans up old compressed logs daily.
#   - Fails gracefully with email alerts if critical failures occur.
#   - Organizes temp files inside /root/.lsws_log_work_dir/.
#
# Crontab Deployment:
#   (Run `crontab -e` as root and add:)
#
#   0 */3 * * * /root/monitor_logs.sh check
#   0 6 * * * /root/monitor_logs.sh daily
#
# Requirements:
#   - Root privileges or run as root user.
#   - msmtp and msmtp-mta installed (apt-get install msmtp msmtp-mta -y).
#   - Valid SMTP2GO credentials set in script.
#   - Server must allow outbound TCP traffic on port 2525.
#
# Notes:
#   Written and revised by ChatGPT-4o on 2025/04/28 with guidance, testing,
#   and validation on CyberPanel 2.4.0 running Ubuntu 22.04.5 LTS.
# ----------------------------------------------------------------------
SCRIPT_VERSION="1.0"
SCRIPT_LAST_UPDATED="2025-04-28"

# User Adjustable Variables
FROM_NAME="--EMAIL SENDER NAME--"
EMAIL_FROM="--ENTER SENDER EMAIL ADDRESS--"
EMAIL_TO="--ENTER RECIPIENT EMAIL ADDRESS--"
SMTP_USER="--ENTER SMTP2GO AUTHORIZED SENDING USERNAME--"
SMTP_PASS="--ENTER SMTP2GO AUTHORIZED SENDING PASSWORD--"
SMTP_SERVER="mail.smtp2go.com"
SMTP_PORT="2525"
LOG_DIR="/usr/local/lsws/logs"

# Static Script Variables - These shouldn't need adjustments
WORK_DIR="/root/.lsws_log_work_dir"
SIZE_FILE="$WORK_DIR/lsws_logs_size.txt"
TMP_STDERR="$WORK_DIR/stderr_excerpt.txt"
TMP_ERRORLOG="$WORK_DIR/errorlog_excerpt.txt"
EMAIL_FILE="$WORK_DIR/email_with_attachments.txt"
ALERT_EMAIL_FILE="$WORK_DIR/alert_email.txt"
TEMP_SCRIPT="$WORK_DIR/monitor_logs_update.sh"
SCRIPT_URL="https://raw.githubusercontent.com/packetdog/ScriptsHackedTogetherWithAI/main/CyberPanel%20Server%20Management%20Scripts/monitor_logs.sh"
SCRIPT_COMMIT_URL="https://github.com/packetdog/ScriptsHackedTogetherWithAI/blob/main/Cyberpanel%20Server%20Management%20Scripts/monitor_logs.sh?tab=log"
UPDATE_ALERT="" # Default - may be overwritten by persisted alert

# Date/Time In-Flight Variables
TODAY_RAW=$(date +%s)
TODAY_HUMAN=$(date '+%B %d, %Y %I:%M %p %Z')
YESTERDAY_RAW=$(date -d "yesterday" +%s)
YESTERDAY_HUMAN=$(date -d "yesterday" '+%B %d, %Y %I:%M %p %Z')

# Ensure work dir exists
mkdir -p "$WORK_DIR"

# Detect server hostname
HOSTNAME=$(hostname --all-fqdns | awk '{print $1}')

# Validate hostname
if [ -z "$HOSTNAME" ] || ! [[ "$HOSTNAME" =~ \. ]]; then
  HOSTNAME=$(curl -s http://checkip.amazonaws.com || echo "unknown-host")
  if [ -z "$HOSTNAME" ]; then
    {
      echo "Subject: 🚨 monitor_logs.sh FATAL ERROR - hostname detection failed"
      echo "From: $FROM_NAME <$EMAIL_FROM>"
      echo "To: $EMAIL_TO"
      echo ""
      echo "Fatal Error: Unable to detect server FQDN or public IP address."
      echo "Script exiting without full hostname information."
      echo "Time: $TODAY_HUMAN"
      echo "Script Version: $SCRIPT_VERSION"
    } > "$ALERT_EMAIL_FILE"
    msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on --user="$SMTP_USER" --passwordeval="echo $SMTP_PASS" --tls=on --from="$EMAIL_FROM" "$EMAIL_TO" < "$ALERT_EMAIL_FILE"
    rm -f "$ALERT_EMAIL_FILE"
    exit 1
  fi
fi

# Capture global disk usage (for partition alerts)
DISK_USAGE_FULL=$(df -h)
DISK_USAGE_LINE_COUNT=$(echo "$DISK_USAGE_FULL" | wc -l)
if [ "$DISK_USAGE_LINE_COUNT" -gt 25 ]; then
  DISK_USAGE_OUTPUT=$(echo "$DISK_USAGE_FULL" | head -n 25)
  DISK_USAGE_NOTE="(Disk Usage output truncated to 25 lines. Original lines: $DISK_USAGE_LINE_COUNT)"
else
  DISK_USAGE_OUTPUT="$DISK_USAGE_FULL"
  DISK_USAGE_NOTE=""
fi

# Capture uptime
UPTIME_INFO=$(uptime)

# Partition usage check (>90%)
HIGH_USAGE_PARTITIONS=$(df --output=target,pcent | grep -v Use | awk '{gsub("%",""); if ($2+0 > 90) print $1 " - " $2 "%"}')
if [ -n "$HIGH_USAGE_PARTITIONS" ]; then
  {
    echo "Subject: 🚨 Partition Usage Alert - $HOSTNAME"
    echo "From: $FROM_NAME <$EMAIL_FROM>"
    echo "To: $EMAIL_TO"
    echo ""
    echo "The following partitions have exceeded 90% usage:"
    echo ""
    echo "$HIGH_USAGE_PARTITIONS"
    echo ""
    echo "Full Disk Usage:"
    echo "$DISK_USAGE_OUTPUT"
    if [ -n "$DISK_USAGE_NOTE" ]; then echo ""; echo "$DISK_USAGE_NOTE"; fi
    echo ""
    echo "Server Uptime:"
    echo "$UPTIME_INFO"
    echo ""
    echo "Script Version: $SCRIPT_VERSION"
  } > "$ALERT_EMAIL_FILE"
  msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on --user="$SMTP_USER" --passwordeval="echo $SMTP_PASS" --tls=on --from="$EMAIL_FROM" "$EMAIL_TO" < "$ALERT_EMAIL_FILE"
  rm -f "$ALERT_EMAIL_FILE"
fi

# Determine mode
MODE="$1"

# --- BEGIN STABLE SECTION 1: Check Mode Logic ---
if [[ "$MODE" == "check" ]]; then
  # Calculate current size
  CURRENT_SIZE_RAW=$(du -sb "$LOG_DIR" | awk '{print $1}')
  CURRENT_SIZE_HUMAN=$(du -sh "$LOG_DIR" | awk '{print $1}')
  # Read previous size
  PREVIOUS_SIZE_RAW=0
  [ -f "$SIZE_FILE" ] && PREVIOUS_SIZE_RAW=$(<"$SIZE_FILE")
  # Calculate percentage change
  if [ "$PREVIOUS_SIZE_RAW" -gt 0 ]; then
    SIZE_DIFF=$((CURRENT_SIZE_RAW - PREVIOUS_SIZE_RAW))
    PERCENT_CHANGE=$(awk "BEGIN {printf \"%.2f\", ($SIZE_DIFF/$PREVIOUS_SIZE_RAW)*100}")
  else
    PERCENT_CHANGE="N/A"
  fi
  # Save today's raw size for next check
  echo "$CURRENT_SIZE_RAW" > "$SIZE_FILE"

  # Alert if size grown >25%
  if [[ "$PERCENT_CHANGE" != "N/A" && $(echo "$PERCENT_CHANGE > 25" | bc) -eq 1 ]]; then
    {
      echo "Subject: 🚨 LSWS Log Size Alert - $HOSTNAME"
      echo "From: $FROM_NAME <$EMAIL_FROM>"
      echo "To: $EMAIL_TO"
      echo ""
      echo "Log size grew by $PERCENT_CHANGE% since last check!"
      echo ""
      echo "Previous Size: $(numfmt --to=iec -- $PREVIOUS_SIZE_RAW)"
      echo "Current Size: $(numfmt --to=iec -- $CURRENT_SIZE_RAW)"
      echo "Difference: $(numfmt --to=iec -- $SIZE_DIFF)"
      echo ""
      echo "Disk Usage:"
      echo "$DISK_USAGE_OUTPUT"
      [ -n "$DISK_USAGE_NOTE" ] && { echo ""; echo "$DISK_USAGE_NOTE"; }
      echo ""
      echo "Server Uptime:"
      echo "$UPTIME_INFO"
      echo ""
      echo "Script Version: $SCRIPT_VERSION"
    } > "$ALERT_EMAIL_FILE"
    msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on --user="$SMTP_USER" --passwordeval="echo $SMTP_PASS" --tls=on --from="$EMAIL_FROM" "$EMAIL_TO" < "$ALERT_EMAIL_FILE"
    rm -f "$ALERT_EMAIL_FILE"
  fi
  exit 0
fi
# --- END STABLE SECTION 1: Check Mode Logic ---

# --- BEGIN STABLE SECTION 2: Self-Update Logic ---
if [[ "$MODE" == "daily" ]]; then
  # Load persisted alert if any
  if [ -f "$WORK_DIR/update_alert.txt" ]; then
    UPDATE_ALERT=$(<"$WORK_DIR/update_alert.txt")
    rm -f "$WORK_DIR/update_alert.txt"
  else
    UPDATE_ALERT=""
  fi

  CURRENT_EMAIL_FROM="$EMAIL_FROM"
  CURRENT_EMAIL_TO="$EMAIL_TO"
  CURRENT_FROM_NAME="$FROM_NAME"
  CURRENT_SMTP_USER="$SMTP_USER"
  CURRENT_SMTP_PASS="$SMTP_PASS"

  curl -s -o "$TEMP_SCRIPT" "$SCRIPT_URL"
  if [ ! -s "$TEMP_SCRIPT" ]; then
    UPDATE_ALERT="UPDATE ALERT: Attempted update failed — unable to download script."
  else
    REMOTE_VERSION=$(grep -m1 'SCRIPT_VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)
    if [ -z "$REMOTE_VERSION" ]; then
      UPDATE_ALERT="UPDATE ALERT: Attempted update failed — remote script missing version."
    else
      LOCAL_STABLE_SUM=$(sed -n '/# --- BEGIN STABLE SECTION 1/,/# --- END STABLE SECTION 1/p' "$0" | md5sum | awk '{print $1}')
      REMOTE_STABLE_SUM=$(sed -n '/# --- BEGIN STABLE SECTION 1/,/# --- END STABLE SECTION 1/p' "$TEMP_SCRIPT" | md5sum | awk '{print $1}')
      if [[ "$REMOTE_VERSION" != "$SCRIPT_VERSION" ]]; then
        UPDATE_ALERT="UPDATE ALERT: Script updated from v$SCRIPT_VERSION to v$REMOTE_VERSION. Please see $SCRIPT_COMMIT_URL for details."
        echo "$UPDATE_ALERT" > "$WORK_DIR/update_alert.txt"
        sed -i "s|--ENTER SENDER EMAIL ADDRESS--|$CURRENT_EMAIL_FROM|g" "$TEMP_SCRIPT"
        sed -i "s|--ENTER RECIPIENT EMAIL ADDRESS--|$CURRENT_EMAIL_TO|g" "$TEMP_SCRIPT"
        sed -i "s|--EMAIL SENDER NAME--|$CURRENT_FROM_NAME|g" "$TEMP_SCRIPT"
        sed -i "s|--ENTER SMTP2GO AUTHORIZED SENDING USERNAME--|$CURRENT_SMTP_USER|g" "$TEMP_SCRIPT"
        sed -i "s|--ENTER SMTP2GO AUTHORIZED SENDING PASSWORD--|$CURRENT_SMTP_PASS|g" "$TEMP_SCRIPT"
        BACKUP_DATE=$(date '+%Y-%m-%d')
        BACKUP_FILE="${0}_v${SCRIPT_VERSION}_${BACKUP_DATE}.bak"
        cp "$0" "$BACKUP_FILE"
        BACKUPS=$(ls -1t "${0}_v"*.bak 2>/dev/null)
        [ $(echo "$BACKUPS" | wc -l) -gt 1 ] && rm -f $(echo "$BACKUPS" | tail -n 1)
        cp "$TEMP_SCRIPT" "$0" && chmod +x "$0"
        exec "$0" "$@"
      else
        [ "$LOCAL_STABLE_SUM" != "$REMOTE_STABLE_SUM" ] && UPDATE_ALERT="UPDATE ALERT: Scripts differ materially despite same version v$SCRIPT_VERSION. Please see $SCRIPT_COMMIT_URL for details."
      fi
    fi
  fi
  rm -f "$TEMP_SCRIPT"
fi
# --- END STABLE SECTION 2: Self-Update Logic ---

if [[ "$MODE" == "daily" ]]; then
  # Calculate current size (after update)
  CURRENT_SIZE_RAW=$(du -sb "$LOG_DIR" | awk '{print $1}')
  CURRENT_SIZE_HUMAN=$(du -sh "$LOG_DIR" | awk '{print $1}')
  PREVIOUS_SIZE_RAW=0
  [ -f "$SIZE_FILE" ] && PREVIOUS_SIZE_RAW=$(<"$SIZE_FILE")
  if [ "$PREVIOUS_SIZE_RAW" -gt 0 ]; then
    SIZE_DIFF=$((CURRENT_SIZE_RAW - PREVIOUS_SIZE_RAW))
    PERCENT_CHANGE=$(awk "BEGIN {printf \"%.2f\", ($SIZE_DIFF/$PREVIOUS_SIZE_RAW)*100}")
  else
    PERCENT_CHANGE="N/A"
  fi
  echo "$CURRENT_SIZE_RAW" > "$SIZE_FILE"

  # --- BEGIN STABLE SECTION 3: Daily Log Workflow ---
  find "$LOG_DIR" -type f -name "*.gz" -mtime +0 -exec rm -f {} \;

  if [ -f "$LOG_DIR/stderr.log" ]; then
    grep -Ev 'INFO|NOTICE' "$LOG_DIR/stderr.log" | tail -n 75 > "$TMP_STDERR"
  else
    echo "stderr.log not found." > "$TMP_STDERR"
  fi

  LATEST_ERROR_LOG=$(find "$LOG_DIR" -type f -name 'error.log*' ! -name '*.gz' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
  if [ -n "$LATEST_ERROR_LOG" ]; then
    grep -Ev 'INFO|NOTICE' "$LATEST_ERROR_LOG" | tail -n 75 > "$TMP_ERRORLOG"
  else
    echo "No error.log found." > "$TMP_ERRORLOG"
  fi

  LISTING_FULL=$(ls -al "$LOG_DIR")
  LISTING_LINE_COUNT=$(echo "$LISTING_FULL" | wc -l)
  if [ "$LISTING_LINE_COUNT" -gt 25 ]; then
    LISTING_OUTPUT=$(echo "$LISTING_FULL" | head -n 25)
    LISTING_NOTE="(Directory Listing truncated to 25 lines. Original lines: $LISTING_LINE_COUNT)"
  else
    LISTING_OUTPUT="$LISTING_FULL"
    LISTING_NOTE=""
  fi

  {
    echo "Subject: $HOSTNAME Daily LSWS Error Log Report - $TODAY_HUMAN"
    echo "From: $FROM_NAME <$EMAIL_FROM>"
    echo "To: $EMAIL_TO"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/mixed; boundary=\"frontier\""
    echo ""
    [ -n "$UPDATE_ALERT" ] && { echo "$UPDATE_ALERT"; echo ""; }
    echo "--frontier"
    echo "Content-Type: text/plain"
    echo ""
    echo "Log Directory Size Report:"
    echo "Previous Size (as of $YESTERDAY_HUMAN): $(numfmt --to=iec -- $PREVIOUS_SIZE_RAW)"
    echo "Current Size (as of $TODAY_HUMAN): $(numfmt --to=iec -- $CURRENT_SIZE_RAW)"
    echo "Size Change: $(numfmt --to=iec -- $SIZE_DIFF) ($PERCENT_CHANGE%)"
    echo ""
    echo "Directory Listing of $LOG_DIR:"
    echo ""
    echo "$LISTING_OUTPUT"
    [ -n "$LISTING_NOTE" ] && { echo ""; echo "$LISTING_NOTE"; }
    echo ""
    echo "Disk Usage:"
    echo ""
    echo "$DISK_USAGE_OUTPUT"
    [ -n "$DISK_USAGE_NOTE" ] && { echo ""; echo "$DISK_USAGE_NOTE"; }
    echo ""
    echo "Server Uptime:"
    echo "$UPTIME_INFO"
    echo ""
    echo "Script Version: $SCRIPT_VERSION"
    echo ""
    echo "--frontier"
    echo "Content-Type: text/plain; charset=\"us-ascii\""
    echo "Content-Disposition: attachment; filename=\"stderr_excerpt.txt\""
    echo ""
    cat "$TMP_STDERR"
    echo ""
    echo "--frontier"
    echo "Content-Type: text/plain; charset=\"us-ascii\""
    echo "Content-Disposition: attachment; filename=\"errorlog_excerpt.txt\""
    echo ""
    cat "$TMP_ERRORLOG"
    echo ""
    echo "--frontier--"
  } > "$EMAIL_FILE"

  msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on --user="$SMTP_USER" --passwordeval="echo $SMTP_PASS" --tls=on --from="$EMAIL_FROM" "$EMAIL_TO" < "$EMAIL_FILE"

  find "$LOG_DIR" -type f \( -name "access.log*" -o -name "error.log*" -o -name "stderr.log*" \) ! -name "*.gz" -exec gzip -f {} \;

  rm -f "$TMP_STDERR" "$TMP_ERRORLOG" "$EMAIL_FILE"
  # --- END STABLE SECTION 3: Daily Log Workflow ---
fi

exit 0
