#!/bin/bash
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
#   2. Check Mode (`monitor_logs.sh check`)
#
# Requirements:
#   - Root privileges
#   - msmtp and msmtp-mta installed
#   - Valid SMTP2GO credentials in the script
#   - Outbound TCP to SMTP2GO port 2525 allowed
# ----------------------------------------------------------------------

SCRIPT_VERSION="1.1"
SCRIPT_LAST_UPDATED="2025-05-06"

# User Adjustable Variables
FROM_NAME="--EMAIL SENDER NAME--"
EMAIL_FROM="--ENTER SENDER EMAIL ADDRESS--"
EMAIL_TO="--ENTER RECIPIENT EMAIL ADDRESS--"
SMTP_USER="--ENTER SMTP2GO AUTHORIZED SENDING USERNAME--"
SMTP_PASS="--ENTER SMTP2GO AUTHORIZED SENDING PASSWORD--"
SMTP_SERVER="mail.smtp2go.com"
SMTP_PORT="2525"
LOG_DIR="/usr/local/lsws/logs"

# Alert Thresholds
MIN_REL_CHANGE=25                      # Minimum relative change (%) to alert for large dirs
MIN_ABS_DIFF=$((100*1024*1024))        # Minimum absolute growth (100MB) to alert
BIG_DIR_THRESHOLD=$((1*1024*1024*1024))# Directory size threshold (1GB) for relative alerts

# Static Script Variables
WORK_DIR="/root/.lsws_log_work_dir"
SIZE_FILE="$WORK_DIR/lsws_logs_size.txt"
TMP_STDERR="$WORK_DIR/stderr_excerpt.txt"
TMP_ERRORLOG="$WORK_DIR/errorlog_excerpt.txt"
EMAIL_FILE="$WORK_DIR/email_with_attachments.txt"
ALERT_EMAIL_FILE="$WORK_DIR/alert_email.txt"
TEMP_SCRIPT="$WORK_DIR/monitor_logs_update.sh"
SCRIPT_URL="https://raw.githubusercontent.com/packetdog/ScriptsHackedTogetherWithAI/main/CyberPanel%20Server%20Management%20Scripts/monitor_logs.sh"
SCRIPT_COMMIT_URL="https://github.com/packetdog/ScriptsHackedTogetherWithAI/commits/main/CyberPanel%20Server%20Management%20Scripts/monitor_logs.sh"
UPDATE_ALERT=""

# Date/Time Variables
TODAY_RAW=$(date +%s)
TODAY_HUMAN=$(date '+%B %d, %Y %I:%M %p %Z')
YESTERDAY_RAW=$(date -d "yesterday" +%s)
YESTERDAY_HUMAN=$(date -d "yesterday" '+%B %d, %Y %I:%M %p %Z')

# Ensure work dir
mkdir -p "$WORK_DIR"

# Hostname detection
HOSTNAME=$(hostname --all-fqdns | awk '{print $1}')
if [ -z "$HOSTNAME" ] || ! [[ "$HOSTNAME" =~ \. ]]; then
  HOSTNAME=$(curl -s http://checkip.amazonaws.com || echo "unknown-host")
  if [ -z "$HOSTNAME" ]; then
    {
      echo "Subject: 🚨 monitor_logs.sh FATAL ERROR - hostname detection failed"
      echo "From: $FROM_NAME <$EMAIL_FROM>"
      echo "To: $EMAIL_TO"
      echo ""
      echo "Fatal Error: Unable to detect server FQDN or public IP address."
      echo "Time: $TODAY_HUMAN"
      echo "Script Version: $SCRIPT_VERSION"
    } > "$ALERT_EMAIL_FILE"
    msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on \
          --user="$SMTP_USER" --passwordeval="echo $SMTP_PASS" \
          --tls=on -f "$EMAIL_FROM" "$EMAIL_TO" < "$ALERT_EMAIL_FILE"
    rm -f "$ALERT_EMAIL_FILE"
    exit 1
  fi
fi

# Disk usage snapshot
DISK_USAGE_FULL=$(df -h)
DISK_USAGE_LINE_COUNT=$(echo "$DISK_USAGE_FULL" | wc -l)
if [ "$DISK_USAGE_LINE_COUNT" -gt 25 ]; then
  DISK_USAGE_OUTPUT=$(echo "$DISK_USAGE_FULL" | head -n 25)
  DISK_USAGE_NOTE="(truncated, original $DISK_USAGE_LINE_COUNT lines)"
else
  DISK_USAGE_OUTPUT="$DISK_USAGE_FULL"
  DISK_USAGE_NOTE=""
fi

# Uptime
UPTIME_INFO=$(uptime)

# Partition usage (>90%)
HIGH_USAGE_PARTITIONS=$(df --output=target,pcent | grep -v Use | awk '{gsub("%",""); if ($2+0 > 90) print $1 " - " $2 "%"}')
if [ -n "$HIGH_USAGE_PARTITIONS" ]; then
  {
    echo "Subject: 🚨 Partition Usage Alert - $HOSTNAME"
    echo "From: $FROM_NAME <$EMAIL_FROM>"
    echo "To: $EMAIL_TO"
    echo ""
    echo "Partitions >90% usage:" 
    echo "$HIGH_USAGE_PARTITIONS"
    echo ""
    echo "Disk Usage:"; echo "$DISK_USAGE_OUTPUT"
    [ -n "$DISK_USAGE_NOTE" ] && echo "$DISK_USAGE_NOTE"
    echo ""
    echo "Uptime: $UPTIME_INFO"
    echo "Script Version: $SCRIPT_VERSION"
  } > "$ALERT_EMAIL_FILE"
  msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on \
        --user="$SMTP_USER" --passwordeval="echo $SMTP_PASS" \
        --tls=on -f "$EMAIL_FROM" "$EMAIL_TO" < "$ALERT_EMAIL_FILE"
  rm -f "$ALERT_EMAIL_FILE"
fi

MODE="$1"

# --- BEGIN STABLE SECTION 1: Check Mode Logic ---
if [[ "$MODE" == "check" ]]; then
  CURRENT_SIZE_RAW=$(du -sb "$LOG_DIR" | awk '{print $1}')
  PREVIOUS_SIZE_RAW=0; [ -f "$SIZE_FILE" ] && PREVIOUS_SIZE_RAW=$(<"$SIZE_FILE")
  SIZE_DIFF=$((CURRENT_SIZE_RAW - PREVIOUS_SIZE_RAW))
  PERCENT_CHANGE="N/A"
  if [ "$PREVIOUS_SIZE_RAW" -gt 0 ]; then
    PERCENT_CHANGE=$(awk "BEGIN {printf \"%.2f\", ($SIZE_DIFF/$PREVIOUS_SIZE_RAW)*100}")
  fi
  echo "$CURRENT_SIZE_RAW" > "$SIZE_FILE"

  # Alert if significant growth
  if [[ "$PERCENT_CHANGE" != "N/A" ]]; then
    if { [ "$(echo "$PERCENT_CHANGE > $MIN_REL_CHANGE" | bc)" -eq 1 ] && [ "$PREVIOUS_SIZE_RAW" -ge "$BIG_DIR_THRESHOLD" ]; } \
       || [ "$SIZE_DIFF" -ge "$MIN_ABS_DIFF" ]; then
      {
        echo "Subject: 🚨 LSWS Log Size Alert - $HOSTNAME"
        echo "From: $FROM_NAME <$EMAIL_FROM>"
        echo "To: $EMAIL_TO"
        echo ""
        echo "Log grew by $PERCENT_CHANGE% (diff: $(numfmt --to=iec -- $SIZE_DIFF))"
        echo "Prev size: $(numfmt --to=iec -- $PREVIOUS_SIZE_RAW)"
        echo "Curr size: $(numfmt --to=iec -- $CURRENT_SIZE_RAW)"
        echo ""
        echo "Disk Usage:"; echo "$DISK_USAGE_OUTPUT"
        [ -n "$DISK_USAGE_NOTE" ] && echo "$DISK_USAGE_NOTE"
        echo ""
        echo "Uptime: $UPTIME_INFO"
        echo "Script Version: $SCRIPT_VERSION"
      } > "$ALERT_EMAIL_FILE"
      msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on \
            --user="$SMTP_USER" --passwordeval="echo $SMTP_PASS" \
            --tls=on -f "$EMAIL_FROM" "$EMAIL_TO" < "$ALERT_EMAIL_FILE"
      rm -f "$ALERT_EMAIL_FILE"
    fi
  fi
  exit 0
fi
# --- END STABLE SECTION 1 ---

# --- BEGIN STABLE SECTION 2: Self-Update Logic ---
if [[ "$MODE" == "daily" ]]; then
  if [ -f "$WORK_DIR/update_alert.txt" ]; then
    UPDATE_ALERT=$(<"$WORK_DIR/update_alert.txt"); rm -f "$WORK_DIR/update_alert.txt"
  fi
  # carry forward existing settings
  CURRENT_EMAIL_FROM="$EMAIL_FROM"
  CURRENT_EMAIL_TO="$EMAIL_TO"
  CURRENT_FROM_NAME="$FROM_NAME"
  CURRENT_SMTP_USER="$SMTP_USER"
  CURRENT_SMTP_PASS="$SMTP_PASS"
  CURRENT_SMTP_SERVER="$SMTP_SERVER"
  CURRENT_SMTP_PORT="$SMTP_PORT"
  CURRENT_LOG_DIR="$LOG_DIR"
  curl -s -o "$TEMP_SCRIPT" "$SCRIPT_URL"
  if [ ! -s "$TEMP_SCRIPT" ]; then
    UPDATE_ALERT="UPDATE ALERT: failed to download updated script."
  else
    REMOTE_VERSION=$(grep -m1 'SCRIPT_VERSION=' "$TEMP_SCRIPT" | cut -d'\"' -f2)
    if [[ "$REMOTE_VERSION" != "$SCRIPT_VERSION" ]]; then
      UPDATE_ALERT="UPDATE ALERT: script updated from v$SCRIPT_VERSION to v$REMOTE_VERSION. See $SCRIPT_COMMIT_URL"
      echo "$UPDATE_ALERT" > "$WORK_DIR/update_alert.txt"
      # propagate settings into the new script
      sed -i "s|^FROM_NAME=.*|FROM_NAME=\"$CURRENT_FROM_NAME\"|" "$TEMP_SCRIPT"
      sed -i "s|^EMAIL_FROM=.*|EMAIL_FROM=\"$CURRENT_EMAIL_FROM\"|" "$TEMP_SCRIPT"
      sed -i "s|^EMAIL_TO=.*|EMAIL_TO=\"$CURRENT_EMAIL_TO\"|" "$TEMP_SCRIPT"
      sed -i "s|^SMTP_USER=.*|SMTP_USER=\"$CURRENT_SMTP_USER\"|" "$TEMP_SCRIPT"
      sed -i "s|^SMTP_PASS=.*|SMTP_PASS=\"$CURRENT_SMTP_PASS\"|" "$TEMP_SCRIPT"
      sed -i "s|^SMTP_SERVER=.*|SMTP_SERVER=\"$CURRENT_SMTP_SERVER\"|" "$TEMP_SCRIPT"
      sed -i "s|^SMTP_PORT=.*|SMTP_PORT=\"$CURRENT_SMTP_PORT\"|" "$TEMP_SCRIPT"
      sed -i "s|^LOG_DIR=.*|LOG_DIR=\"$CURRENT_LOG_DIR\"|" "$TEMP_SCRIPT"
      BACKUP_DATE=$(date '+%Y-%m-%d')
      BACKUP_FILE="${0}_v${SCRIPT_VERSION}_${BACKUP_DATE}.bak"
      cp "$0" "$BACKUP_FILE"
      cp "$TEMP_SCRIPT" "$0" && chmod +x "$0"
      exec "$0" "$@"
    fi
  fi
  rm -f "$TEMP_SCRIPT"
fi
# --- END STABLE SECTION 2 ---

# --- BEGIN STABLE SECTION 3: Daily Log Workflow ---
if [[ "$MODE" == "daily" ]]; then
  CURRENT_SIZE_RAW=$(du -sb "$LOG_DIR" | awk '{print $1}')
  PREVIOUS_SIZE_RAW=0; [ -f "$SIZE_FILE" ] && PREVIOUS_SIZE_RAW=$(<"$SIZE_FILE")
  SIZE_DIFF=$((CURRENT_SIZE_RAW - PREVIOUS_SIZE_RAW))
  PERCENT_CHANGE="N/A"
  if [ "$PREVIOUS_SIZE_RAW" -gt 0 ]; then
    PERCENT_CHANGE=$(awk "BEGIN {printf \"%.2f\", ($SIZE_DIFF/$PREVIOUS_SIZE_RAW)*100}")
  fi
  echo "$CURRENT_SIZE_RAW" > "$SIZE_FILE"
  find "$LOG_DIR" -type f -name "*.gz" -mtime +0 -exec rm -f {} \

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
    LISTING_NOTE="(truncated $LISTING_LINE_COUNT lines)"
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
    echo "Directory Listing of $LOG_DIR:"; echo "$LISTING_OUTPUT"
    [ -n "$LISTING_NOTE" ] && echo "$LISTING_NOTE"
    echo ""
    echo "Disk Usage:"; echo "$DISK_USAGE_OUTPUT"
    [ -n "$DISK_USAGE_NOTE" ] && echo "$DISK_USAGE_NOTE"
    echo ""
    echo "Server Uptime:"
    echo "$UPTIME_INFO"
    echo "Script Version: $SCRIPT_VERSION"
    echo ""
    echo "--frontier"
    echo "Content-Type: text/plain; charset=us-ascii"
    echo "Content-Disposition: attachment; filename=stderr_excerpt.txt"
    cat "$TMP_STDERR"
    echo ""
    echo "--frontier"
    echo "Content-Type: text/plain; charset=us-ascii"
    echo "Content-Disposition: attachment; filename=errorlog_excerpt.txt"
    cat "$TMP_ERRORLOG"
    echo ""
    echo "--frontier--"
  } > "$EMAIL_FILE"
  msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on \
        --user="$SMTP_USER" --passwordeval="echo $SMTP_PASS" \
        --tls=on -f "$EMAIL_FROM" "$EMAIL_TO" < "$EMAIL_FILE"
  find "$LOG_DIR" -type f \( -name "access.log*" -o -name "error.log*" -o -name "stderr.log*" \) ! -name "*.gz" -exec gzip -f {} \;
  rm -f "$TMP_STDERR" "$TMP_ERRORLOG" "$EMAIL_FILE"
fi

exit 0
