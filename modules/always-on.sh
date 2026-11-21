# shellcheck shell=bash
#
# V2CC always-on: the part of the system activation that keeps a V2CC Mac
# online. modules/always-on.nix puts this file, exactly as it is, into the
# nix-darwin activation script. It runs as root under `set -e` and
# `set -o pipefail` whenever a deploy activates the system, not at boot.
#
# Everything here is machine-wide: it applies to the owner's account exactly
# as much as to the customer's.
#
# Every value is written out on its own line on purpose. deploy.sh compares
# activation scripts line by line, so a later change to any value is seen
# and refused unless it is explicitly allowed. Do not move the values into
# variables or into a helper script in the Nix store.
#
# tests/run.sh runs this same file against stub pmset and defaults commands.

# verify.sh, deploy.sh and rollback.sh recognise a system that carries these
# settings by this line (sys_declares_always_on in lib/always-on.sh).
echo "v2cc always-on: machine-wide settings..." >&2

# What this Mac had before the first always-on activation. Rolling back the
# Nix generation does not undo the settings below: they live in macOS, not
# in the Nix store. ./rollback.sh puts these values back and then renames
# the file, so a later activation records afresh.
if [ ! -e /var/db/v2cc/always-on-before.txt ]; then
  mkdir -p /var/db/v2cc
  {
    echo "# V2CC always-on: the values this Mac had before the first activation."
    echo "# Written once by the system activation, restored by ./rollback.sh."
    echo "# pmset.<power source>.<setting>: c = wall power, b = battery, u = UPS."
    echo "recorded=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    pmset -g custom | awk '
      /^Battery Power:/ { src = "b"; next }
      /^AC Power:/ { src = "c"; next }
      /^UPS Power:/ { src = "u"; next }
      src != "" && NF == 2 && ($1 == "sleep" || $1 == "autorestart" || $1 == "womp") {
        print "pmset." src "." $1 "=" $2
      }'
    echo "autologout=$(defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>/dev/null || echo absent)"
    echo "macos-update-install=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates 2>/dev/null || echo absent)"
  } >/var/db/v2cc/always-on-before.txt.tmp
  # Nothing is changed unless the current power settings could be read:
  # without them there would be nothing to restore.
  if ! grep -q '^pmset\.' /var/db/v2cc/always-on-before.txt.tmp; then
    rm -f /var/db/v2cc/always-on-before.txt.tmp
    echo "v2cc always-on: could not read the current power settings (pmset -g custom); nothing was changed" >&2
    exit 1
  fi
  mv /var/db/v2cc/always-on-before.txt.tmp /var/db/v2cc/always-on-before.txt
fi

# A power setting this Mac does not have is skipped rather than failing the
# whole activation. verify.sh then reports it.
v2cc_power_caps="$(pmset -g cap)"
v2cc_pmset() {
  if grep -qx "[[:space:]]*$1" <<<"$v2cc_power_caps"; then
    pmset -a "$1" "$2"
  else
    echo "v2cc always-on: this Mac has no '$1' power setting, skipped" >&2
  fi
}

# No idle system sleep. displaysleep is not touched, so the display still
# turns off.
v2cc_pmset sleep 0
# Start up again when power returns after a power failure.
v2cc_pmset autorestart 1
# Wake for network access, where the Mac supports it.
v2cc_pmset womp 1

# Idle auto-logout off. 0 means off; macOS's own default is no key at all.
defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0

# Do not install macOS updates unattended, so an update never restarts the
# Mac by itself. Updates are installed by a person in a planned maintenance
# window. Checking for updates, their notifications, and the automatic
# security data and background security updates are not touched.
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
