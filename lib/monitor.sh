#!/bin/bash
# shellcheck shell=bash
#
# Where the monitor lives and read-only facts about it, for monitor.sh,
# bootstrap.sh and verify.sh. Source lib/common.sh first. Nothing here needs
# root or changes anything.
#
# The constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

MON_LABEL="com.v2cc.monitor"
MON_PLIST="$V2CC_SYSROOT/Library/LaunchDaemons/$MON_LABEL.plist"
MON_DIR="$V2CC_SYSROOT/Library/Application Support/V2CC/monitor"
MON_PROG="$MON_DIR/v2cc-monitor"
MON_SCHEMA="$MON_DIR/schema.txt"
MON_CONFIG="$MON_DIR/config"
MON_CRED="$MON_DIR/upload-credential"
MON_RECORDS="$MON_DIR/records"
# Written by the monitor after every round, readable by every account:
# times and states only, nothing that was recorded.
MON_STATUS="$V2CC_SYSROOT/var/db/v2cc/monitor-status"
# Every 5 minutes; a record older than 15 minutes means it stopped.
MON_INTERVAL=300
MON_STALE_SECONDS=900

mon_installed() { [ -e "$MON_PLIST" ] && [ -e "$MON_PROG" ]; }
mon_loaded() { launchctl print "system/$MON_LABEL" >/dev/null 2>&1; }

# mon_status KEY: one value of the status file, or nothing.
mon_status() { [ -r "$MON_STATUS" ] || return 0; sed -n "s/^$1=//p" "$MON_STATUS" 2>/dev/null | head -n 1; }
# mon_config KEY: one value of the configuration (not secret, world-readable).
mon_config() { [ -r "$MON_CONFIG" ] || return 0; sed -n "s/^$1=//p" "$MON_CONFIG" 2>/dev/null | tail -n 1; }

# The LaunchDaemon. A fixed PATH: root only ever runs system tools.
mon_plist_text() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$MON_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$MON_PROG</string>
    <string>run</string>
  </array>
  <key>StartInterval</key>
  <integer>$MON_INTERVAL</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>Nice</key>
  <integer>10</integer>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$MON_DIR/state/launchd.log</string>
  <key>StandardErrorPath</key>
  <string>$MON_DIR/state/launchd.log</string>
</dict>
</plist>
EOF
}

# An internal name for the machine, never its serial number.
mon_new_machine_id() { printf 'mac-%s' "$(openssl rand -hex 4)"; }
