#!/bin/bash
#
# Return the machine to the system configuration that was running before
# the last deploy.
#
#   ./rollback.sh                    roll back to the recorded previous system
#   ./rollback.sh --to <store-path>  roll back to a specific system
#   ./rollback.sh --list             show the available system generations
#   ./rollback.sh --settings         only put the always-on settings back
#
# This re-activates the previous configuration; it does not delete files in
# any home directory. Run it in the account that deployed, the platform
# maintenance administrator account: the record of the last deploy is kept
# there, and everything but --list needs administrator rights.
#
# The always-on settings (power, auto-logout, macOS update installation)
# live in macOS, not in the Nix store, so re-activating an older
# configuration does not undo them. When the configuration being returned
# to does not carry them, the values recorded before they were first applied
# are put back as well. --settings does only that, for a machine that has no
# earlier configuration to return to.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh
# shellcheck source=lib/always-on.sh
. ./lib/always-on.sh

# Put one machine-level preference back: delete it when it did not exist.
# A value that is already what was recorded is left alone.
restore_default() {
  local domain="$1" key="$2" type="$3" recorded="$4"
  [ "$(sys_default "$domain" "$key")" != "${recorded#absent}" ] || return 0
  case "$type:$recorded" in
    *:absent) run_mut sudo defaults delete "$domain" "$key" ;;
    -bool:1) run_mut sudo defaults write "$domain" "$key" -bool true ;;
    -bool:0) run_mut sudo defaults write "$domain" "$key" -bool false ;;
    -int:*) is_number "$recorded" && run_mut sudo defaults write "$domain" "$key" -int "$recorded" ;;
    *) return 1 ;;
  esac
}

# The same for one power setting on one power source.
restore_power() {
  local src="$1" setting="$2" recorded="$3"
  is_number "$recorded" || return 1
  ! pm_source_is "$src" "$setting" "$recorded" || return 0
  run_mut sudo pmset "-$src" "$setting" "$recorded"
}

# Put back what the system activation recorded before it first applied the
# always-on settings, check each value by reading it, and set the record
# aside so that a later activation records afresh.
restore_always_on() {
  local key value src setting failed=0

  [ -r "$ALWAYS_ON_BEFORE" ] ||
    die "没有找到 7×24 在线设置启用前的原值记录（${ALWAYS_ON_BEFORE}），无法恢复。"
  info "把电源、自动退出登录和系统更新的设置恢复为启用 7×24 在线设置之前的值..."

  # Not on stdin: sudo may want the terminal.
  while IFS='=' read -r key value <&3; do
    case "$key" in
      pmset.[bcu].sleep | pmset.[bcu].autorestart | pmset.[bcu].womp)
        src="${key#pmset.}"
        src="${src%%.*}"
        setting="${key##*.}"
        if restore_power "$src" "$setting" "$value"; then
          is_dry_run || pm_source_is "$src" "$setting" "$value" || {
            fail "pmset ${setting} 没有恢复为 ${value}（当前 $(pm_show "$setting")）"
            failed=1
          }
        else
          fail "未能恢复 pmset ${setting}（记录值「${value}」）"
          failed=1
        fi
        ;;
      autologout)
        if restore_default "$GLOBAL_PREFS" "$AUTOLOGOUT_KEY" -int "$value"; then
          is_dry_run || [ "$(sys_default "$GLOBAL_PREFS" "$AUTOLOGOUT_KEY")" = "${value#absent}" ] || {
            fail "自动退出登录的设置没有恢复为记录值「${value}」"
            failed=1
          }
        else
          fail "未能恢复自动退出登录的设置（记录值「${value}」）"
          failed=1
        fi
        ;;
      macos-update-install)
        if restore_default "$SOFTWARE_UPDATE_PREFS" "$UPDATE_INSTALL_KEY" -bool "$value"; then
          is_dry_run || [ "$(sys_default "$SOFTWARE_UPDATE_PREFS" "$UPDATE_INSTALL_KEY")" = "${value#absent}" ] || {
            fail "macOS 更新自动安装的设置没有恢复为记录值「${value}」"
            failed=1
          }
        else
          fail "未能恢复 macOS 更新自动安装的设置（记录值「${value}」）"
          failed=1
        fi
        ;;
    esac
  done 3<"$ALWAYS_ON_BEFORE"

  if is_dry_run; then
    return 0
  fi
  [ "$failed" = "0" ] ||
    die "有设置没有恢复，记录仍保留在 ${ALWAYS_ON_BEFORE}。处理上面的错误后运行 ./rollback.sh --settings 重试。"
  sudo mv -f "$ALWAYS_ON_BEFORE" "$ALWAYS_ON_BEFORE.restored"
  ok "已恢复为启用前的值（记录已改名为 ${ALWAYS_ON_BEFORE}.restored）"
  if [ -e "$AUTO_LOGIN_MARKER" ]; then
    warn "本机开启了自动登录，但断电后自动开机等设置已恢复原值。不再需要自动登录时请运行 ./auto-login.sh disable。"
  fi
}

auto=0
settings_only=0
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) auto=1 ;;
    --settings) settings_only=1 ;;
    --list)
      info "系统配置的历史版本（$SYSTEM_PROFILE-*-link）："
      for link in "$SYSTEM_PROFILE"-*-link; do
        [ -e "$link" ] && printf '  %s -> %s\n' "$link" "$(resolve_link "$link")"
      done
      exit 0
      ;;
    --to)
      [ $# -ge 2 ] || die "--to 需要一个系统配置的路径。"
      target="$2"
      shift
      ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

require_admin "回退系统配置或恢复系统设置"

if [ "$settings_only" = "1" ]; then
  [ -z "$target" ] || die "--settings 不能和 --to 一起使用。"
  if is_dry_run; then
    restore_always_on
    info "[演练] 以上设置未执行。"
    exit 0
  fi
  if [ "$auto" != "1" ]; then
    confirm "将把整机的电源、自动退出登录和系统更新设置恢复为启用 7×24 在线设置之前的值。继续？" ||
      die "已取消。"
    ensure_sudo "恢复系统设置"
  fi
  restore_always_on
  if [ "$auto" != "1" ] && sys_declares_always_on "$(resolve_link "$CURRENT_SYSTEM_LINK")"; then
    warn "当前系统配置仍然包含 7×24 在线设置：在重新运行 ./bootstrap.sh 之前 ./verify.sh 会报告不一致，重新运行后这些设置会再次启用。"
  fi
  exit 0
fi

if [ -z "$target" ]; then
  state_file="$V2CC_STATE_DIR/last-deploy"
  [ -r "$state_file" ] ||
    die "没有找到上次部署的记录（${state_file}）。记录在运行部署的账户里：请在那个账户里运行；或者用 ./rollback.sh --list 查看历史版本，再用 --to 指定。"
  target="$(sed -n 's/^previous=//p' "$state_file" | head -n 1)"
  [ -n "$target" ] ||
    die "上次部署是本机的首次部署，没有可回退的系统配置。只恢复 7×24 在线设置启用前的原值，可以运行 ./rollback.sh --settings。"
fi

[ -x "$target/activate" ] ||
  die "系统配置不存在或已被清理：$target"
target="$(resolve_link "$target")"

current_system="$(resolve_link "$CURRENT_SYSTEM_LINK")"
info "回退目标：$target"
ok "该配置管理的账户：$(sys_hm_users "$target" | tr '\n' ' ')"

at_target=0
if [ "$current_system" = "$target" ] && [ "$(resolve_link "$SYSTEM_PROFILE")" = "$target" ]; then
  at_target=1
fi
# The target knows nothing about the always-on settings, so returning to it
# means returning them too. Also true when an earlier run got the system
# back but stopped before the settings.
restore_settings=0
if ! sys_declares_always_on "$target" && [ -e "$ALWAYS_ON_BEFORE" ]; then
  restore_settings=1
  ok "该配置不包含 7×24 在线设置：电源、自动退出登录和系统更新设置也会恢复为启用前的值。"
fi

if [ "$at_target" = "1" ] && [ "$restore_settings" = "0" ]; then
  ok "当前系统已经是该配置，无需回退。"
  exit 0
fi

if is_dry_run; then
  [ "$at_target" = "1" ] || info "[演练] 将把系统回退到 ${target}（未执行）。"
  if [ "$restore_settings" = "1" ]; then
    restore_always_on
    info "[演练] 以上设置未执行。"
  fi
  exit 0
fi

if [ "$auto" != "1" ]; then
  confirm "将把整机的系统配置回退到上面的版本。继续？" || die "已取消。"
  ensure_sudo "回退系统配置"
fi

if [ "$at_target" = "0" ]; then
  sudo -H "$NIX_DEFAULT_BIN/nix-env" -p "$SYSTEM_PROFILE" --set "$target"
  sudo "$target/activate"

  [ "$(resolve_link "$CURRENT_SYSTEM_LINK")" = "$target" ] ||
    die "回退后的系统与目标不一致，请联系 V2CC 运营方。"
  ok "已回退到：$target"
fi

if [ "$restore_settings" = "1" ]; then
  restore_always_on
fi
