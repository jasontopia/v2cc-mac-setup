#!/bin/bash
# shellcheck shell=bash
#
# Read-only facts about the always-on settings (modules/always-on.sh) and
# about automatic login (auto-login.sh). Nothing here needs root or changes
# anything. Source lib/common.sh first.
#
# The functions that print a value print nothing when there is none and
# still succeed, so they are safe to call under `set -e`.
#
# The constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

V2CC_DB_DIR="$V2CC_SYSROOT/var/db/v2cc"
# Written by the system activation before it first changes a setting.
ALWAYS_ON_BEFORE="$V2CC_DB_DIR/always-on-before.txt"
# Written by auto-login.sh: this machine is meant to log in by itself.
AUTO_LOGIN_MARKER="$V2CC_DB_DIR/auto-login"
# Where macOS keeps the automatic-login password. Root-only, and only
# obfuscated: treat whatever is in it as readable by anyone with root.
KCPASSWORD="$V2CC_SYSROOT/etc/kcpassword"

GLOBAL_PREFS="/Library/Preferences/.GlobalPreferences"
SOFTWARE_UPDATE_PREFS="/Library/Preferences/com.apple.SoftwareUpdate"
LOGINWINDOW_PREFS="/Library/Preferences/com.apple.loginwindow"
AUTOLOGOUT_KEY="com.apple.autologout.AutoLogOutDelay"
UPDATE_INSTALL_KEY="AutomaticallyInstallMacOSUpdates"

LOCK_AGENT_LABEL="com.v2cc.lock-after-login"
# Root-owned and shared by every account's login session; it acts only in
# the customer account's session. Earlier versions put it in the customer's
# own ~/Library/LaunchAgents, and the marker still names that path there.
LOCK_AGENT="$V2CC_SYSROOT/Library/LaunchAgents/$LOCK_AGENT_LABEL.plist"

# True when the system closure applies the always-on settings.
sys_declares_always_on() {
  grep -Fq 'v2cc always-on:' "$1/activate" 2>/dev/null
}

# One "source=value" line per power source for one power setting
# (c = wall power, b = battery, u = UPS), as `pmset -c|-b|-u` names them.
pm_values() {
  { pmset -g custom 2>/dev/null || true; } | awk -v key="$1" '
    /^Battery Power:/ { src = "b"; next }
    /^AC Power:/ { src = "c"; next }
    /^UPS Power:/ { src = "u"; next }
    src != "" && NF == 2 && $1 == key { print src "=" $2 }'
}

# The same on one line, for messages.
pm_show() {
  local values
  values="$(pm_values "$1" | tr '\n' ' ' | sed 's/ *$//')"
  printf '%s' "${values:-读不到}"
}

# True when the setting exists and has this value on every power source.
pm_is() {
  local values
  values="$(pm_values "$1")"
  [ -n "$values" ] && ! grep -qv -- "=$2\$" <<<"$values"
}

# True when one power source (c, b or u) has the setting at this value.
pm_source_is() {
  local values
  values="$(pm_values "$2")"
  grep -Fxq -- "$1=$3" <<<"$values"
}

# True when this Mac has the power setting at all.
pm_supported() {
  local caps
  caps="$(pmset -g cap 2>/dev/null || true)"
  grep -qx "[[:space:]]*$1" <<<"$caps"
}

# A machine-level preference, or nothing when the key does not exist.
sys_default() {
  defaults read "$1" "$2" 2>/dev/null || true
}

is_number() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Everything `fdesetup status` says, on one line.
filevault_status() {
  { fdesetup status 2>/dev/null || true; } | tr '\n' ' ' | sed 's/ *$//'
}

# True only for the one answer that means off and finished. Anything else,
# including a decryption still in progress or an unreadable answer, is not
# off.
filevault_is_off() {
  [ "$(filevault_status)" = "FileVault is Off." ]
}

# sysadminctl writes through the system log format; keep only its message.
sysadminctl_message() {
  { sysadminctl "$@" 2>&1 || true; } |
    sed -E 's/^[0-9-]+ [0-9:.]+ sysadminctl\[[0-9:]+\] //' | tr '\n' ' ' | sed 's/ *$//'
}

# The account macOS logs in at startup, or nothing.
auto_login_user() {
  sys_default "$LOGINWINDOW_PREFS" autoLoginUser
}

# One field of the auto-login marker, or nothing.
auto_login_marker() {
  [ -r "$AUTO_LOGIN_MARKER" ] || return 0
  sed -n "s/^$1=//p" "$AUTO_LOGIN_MARKER" | sed -n 1p
}

# True when the running system has the always-on settings and the two that
# decide whether a power cut ends in a running Mac are really in effect.
always_on_in_effect() {
  sys_declares_always_on "$1" && pm_is sleep 0 && pm_is autorestart 1
}
