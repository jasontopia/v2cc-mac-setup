#!/bin/bash
#
# Post-deploy verification. Read-only: it changes nothing and can be rerun
# at any time. Exits non-zero if any check fails.
#
#   ./verify.sh                 run every check
#   ./verify.sh --credentials   only scan for leftover GitHub credentials
set -uo pipefail

cd "$(dirname "$0")" || exit 1
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh
# shellcheck source=lib/always-on.sh
. ./lib/always-on.sh

use_nix_and_brew_path

failures=0
pass() { ok "$1"; }
flunk() {
  fail "$1"
  failures=$((failures + 1))
}
check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else flunk "$label"; fi
}

# Classic and fine-grained personal tokens, OAuth/app tokens, and URLs that
# carry a credential before the host name.
credential_pattern='(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|https?://[^/@[:space:]]+@github\.com)'

# Report where a credential sits, never the credential itself.
scan_file() {
  local file="$1" lines
  [ -f "$file" ] && [ -r "$file" ] || return 0
  lines="$(LC_ALL=C grep -InE -- "$credential_pattern" "$file" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')"
  if [ -n "$lines" ]; then
    flunk "发现疑似 GitHub 凭据：${file}（第 ${lines% } 行）"
  fi
}

check_credentials() {
  local before="$failures" file name
  info "检查是否遗留 GitHub 凭据..."

  for name in .gitconfig .config/git/config .git-credentials .netrc \
    .config/gh/hosts.yml .zsh_history .bash_history \
    .zprofile .zshrc .zshenv .bash_profile .bashrc; do
    scan_file "$HOME/$name"
  done
  if [ -d "$HOME/.zsh_sessions" ]; then
    for file in "$HOME/.zsh_sessions"/*; do scan_file "$file"; done
  fi

  # Everything shipped in or generated into the setup directory.
  while IFS= read -r file; do
    scan_file "$file"
  done <<EOF
$(find "$PWD" -type f -not -path '*/tests/*' 2>/dev/null)
EOF

  if [ -f "$HOME/.config/gh/hosts.yml" ] &&
    grep -q 'oauth_token' "$HOME/.config/gh/hosts.yml" 2>/dev/null; then
    flunk "GitHub CLI 的登录信息仍保存在 $HOME/.config/gh/hosts.yml"
  fi

  for name in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN HOMEBREW_GITHUB_API_TOKEN; do
    if [ -n "$(printenv "$name" 2>/dev/null)" ]; then
      flunk "环境变量 $name 中有 GitHub 凭据"
    fi
  done

  if security find-internet-password -s github.com >/dev/null 2>&1; then
    flunk "登录钥匙串中保存了 github.com 的密码或令牌"
  fi
  if security find-generic-password -s 'gh:github.com' >/dev/null 2>&1; then
    flunk "登录钥匙串中保存了 GitHub CLI 的令牌"
  fi

  if [ "$failures" = "$before" ]; then
    pass "未发现遗留的 GitHub 凭据（配置文件、命令历史、部署目录、环境变量、钥匙串）"
  else
    warn "请删除上述凭据并在 GitHub 上吊销对应的令牌，然后重新运行 ./verify.sh。"
  fi
}

# The always-on settings are machine-wide and are applied when a deploy
# activates, not continuously: if someone changes one in System Settings
# afterwards, this is where it shows.
check_always_on() {
  local value key
  info "检查 7×24 在线设置（整机生效，对所有账户相同）..."
  if ! sys_declares_always_on "$current_system"; then
    warn "当前系统配置不包含 7×24 在线设置（部署的是更早的版本）。重新运行 ./bootstrap.sh 后才会启用。"
    return 0
  fi

  if pm_is sleep 0; then
    pass "系统空闲时不会自动睡眠（显示器仍按原设置自动关闭）"
  else
    flunk "系统空闲时仍会自动睡眠：pmset sleep 应为 0，当前 $(pm_show sleep)"
  fi
  if pm_is autorestart 1; then
    pass "断电后恢复供电时自动开机"
  else
    flunk "断电后恢复供电时不会自动开机：pmset autorestart 应为 1，当前 $(pm_show autorestart)"
  fi
  if ! pm_supported womp; then
    warn "本机没有「唤醒以供网络访问」这项设置，已跳过。"
  elif pm_is womp 1; then
    pass "唤醒以供网络访问已开启"
  else
    flunk "唤醒以供网络访问未开启：pmset womp 应为 1，当前 $(pm_show womp)"
  fi

  value="$(sys_default "$GLOBAL_PREFS" "$AUTOLOGOUT_KEY")"
  if [ -z "$value" ] || [ "$value" = "0" ]; then
    pass "闲置后不会自动退出登录"
  else
    flunk "闲置 ${value} 秒后会自动退出登录（应为关闭）"
  fi

  value="$(sys_default "$SOFTWARE_UPDATE_PREFS" "$UPDATE_INSTALL_KEY")"
  if [ "$value" = "0" ]; then
    pass "macOS 更新不会在无人确认时自动安装和重启（需要在维护时段由人安装）"
  else
    flunk "macOS 更新仍会自动安装并重启：${UPDATE_INSTALL_KEY} 应为 0，当前 ${value:-未设置}"
  fi
  # Left alone by the deploy. Off means the machine no longer hears about
  # updates or no longer gets security data: worth saying, not ours to fix.
  for key in AutomaticCheckEnabled CriticalUpdateInstall ConfigDataInstall; do
    if [ "$(sys_default "$SOFTWARE_UPDATE_PREFS" "$key")" = "0" ]; then
      warn "软件更新的 ${key} 已被关闭（不是本部署改的）。建议在「系统设置 > 通用 > 软件更新 > 自动更新」里重新打开检查更新和安全数据的自动安装。"
    fi
  done

  if [ -r "$ALWAYS_ON_BEFORE" ]; then
    pass "启用前的原值已记录，可用 ./rollback.sh 恢复（${ALWAYS_ON_BEFORE}）"
  else
    flunk "没有找到启用前的原值记录（${ALWAYS_ON_BEFORE}），这些设置无法自动恢复"
  fi
}

# What a restart means on this machine. Mostly information: whether the
# disk unlocks by itself and whether anyone is logged in afterwards decide
# if a remote-desktop tool can come back without a person.
report_restart_state() {
  local login_user marker_user lock_agent
  info "重启后会发生什么（取决于 FileVault 和自动登录）..."
  login_user="$(auto_login_user)"
  marker_user="$(auto_login_marker user)"

  if filevault_is_off; then
    note "FileVault 已关闭：重启后不会停在磁盘解锁界面。"
  else
    note "FileVault 没有关闭（系统的回答：$(filevault_status)）：重启后需要有人在机器旁输入密码才能继续启动，在此之前任何远程软件都连不上。"
  fi

  if [ -n "$marker_user" ]; then
    if ! filevault_is_off; then
      flunk "本机登记为自动登录账户 ${marker_user}，但 FileVault 没有关闭，自动登录不会生效"
    elif [ "$login_user" != "$marker_user" ]; then
      flunk "本机登记为自动登录账户 ${marker_user}，但系统当前的自动登录账户是「${login_user:-无}」"
    elif [ ! -e "$KCPASSWORD" ]; then
      flunk "本机登记为自动登录账户 ${marker_user}，但保存的登录凭据（${KCPASSWORD}）不存在"
    else
      pass "重启后自动登录账户 ${marker_user}（由 auto-login.sh 于 $(auto_login_marker enabled) 设置）"
    fi
    lock_agent="$(auto_login_marker lock_agent)"
    if [ -z "$lock_agent" ]; then
      note "登录后不会自动锁屏：重启后桌面处于已解锁状态。"
    elif [ "$marker_user" != "$me" ]; then
      # Another account's ~/Library cannot be looked into from here.
      note "登录后立即锁屏的登录项在账户 ${marker_user} 的目录里，从当前账户无法检查。"
    elif [ -e "$lock_agent" ]; then
      note "登录后立即关闭显示器并锁屏的登录项已安装（是否生效、锁屏后 UU远程 能否连接，尚未在真机验证）。"
    else
      flunk "本机登记为登录后立即锁屏，但登录项文件不存在：$lock_agent"
    fi
  elif [ -n "$login_user" ]; then
    warn "系统已开启自动登录（账户 ${login_user}），但不是通过 ./auto-login.sh 设置的。"
  else
    note "自动登录未启用：重启后停在登录窗口，需要有人登录后才有用户会话。"
  fi

  # Service names as observed in UU远程 4.48.1. Loaded is not the same as
  # reachable: the permissions and the sign-in cannot be read from here.
  if launchctl print system/com.netease.uuremote.daemon >/dev/null 2>&1; then
    note "UU远程 系统服务：已加载。"
  else
    note "UU远程 系统服务：未加载（未安装，或版本不同）。"
  fi
  if launchctl print "gui/$(id -u)/com.netease.uuremote.agent" >/dev/null 2>&1; then
    note "UU远程 在当前登录会话中：已加载。"
  else
    note "UU远程 在当前登录会话中：未加载。"
  fi
  note "UU远程 的登录状态、「允许本设备被控」「开机自动启动」和「辅助功能」「录屏与系统录音」权限无法由脚本读取，需人工确认。"
  note "登录窗口或锁屏状态下 UU远程 能否无人值守连接，尚未在真机验证（docs/test-plan.md 第二阶段）。"
  note "上次开机：$(sysctl -n kern.boottime 2>/dev/null | sed 's/^.*} //')"
}

finish() {
  if [ "$failures" -eq 0 ]; then
    info "验证通过。"
    exit 0
  fi
  info "验证未通过：$failures 项失败。"
  exit 1
}

if [ "${1:-}" = "--credentials" ]; then
  check_credentials
  finish
fi

me="$(id -un)"
current_system="$(resolve_link "$CURRENT_SYSTEM_LINK")"

info "检查基础依赖..."
check "Xcode Command Line Tools" xcode-select -p
check "Nix" nix --version
check "Homebrew" "$BREW_PREFIX/bin/brew" --version

info "检查系统配置..."
if [ -z "$current_system" ]; then
  flunk "没有正在运行的 nix-darwin 系统配置"
else
  pass "当前系统：$current_system"
  if [ "$(resolve_link "$SYSTEM_PROFILE")" = "$current_system" ]; then
    pass "开机后生效的系统配置与当前系统一致"
  else
    flunk "开机后生效的系统配置（${SYSTEM_PROFILE}）与当前系统不一致"
  fi

  state_file="$V2CC_STATE_DIR/last-deploy"
  if [ -r "$state_file" ]; then
    deployed="$(sed -n 's/^new=//p' "$state_file" | head -n 1)"
    previous="$(sed -n 's/^previous=//p' "$state_file" | head -n 1)"
    if [ "$deployed" = "$current_system" ]; then
      pass "当前系统就是上次部署的配置"
    else
      flunk "当前系统不是上次部署的配置（${deployed}）"
    fi
    if [ -n "$previous" ] && [ -r "$previous/activate" ]; then
      # Hold the result to what was allowed when it was deployed.
      allowed="$(sed -n 's/^allow_system_changes=//p' "$state_file" | head -n 1)"
      if problems="$(V2CC_ALLOW_SYSTEM_CHANGES="${allowed:-0}" guard_compare "$previous" "$current_system")"; then
        pass "部署前已有的账户、服务和命令全部保留"
      else
        flunk "部署前已有的内容发生了变化：$(printf '%s' "$problems" | tr '\n' ' ')"
      fi
    fi
  fi

  if sys_hm_users "$current_system" | grep -Fxq -- "$me"; then
    pass "当前账户 $me 由系统配置管理"
  else
    flunk "当前账户 $me 不在系统配置管理的账户中"
  fi
  pass "系统配置管理的账户：$(sys_hm_users "$current_system" | tr '\n' ' ')"

  expected_home="$(resolve_link "$(sys_hm_generation "$current_system" "$me")")"
  active_home="$(resolve_link "$HOME/.local/state/home-manager/gcroots/current-home")"
  if [ -n "$expected_home" ] && [ "$active_home" = "$expected_home" ]; then
    pass "当前账户的 Home Manager 配置已生效"
  else
    flunk "当前账户的 Home Manager 配置未生效（期望 ${expected_home:-未知}，实际 ${active_home:-无}）"
  fi

  check "系统命令 git" "$current_system/sw/bin/git" --version
  check "系统命令 node" "$current_system/sw/bin/node" --version
  check "开机自动激活服务 org.nixos.activate-system" \
    launchctl print system/org.nixos.activate-system

  check_always_on
fi
report_restart_state

info "检查 Claude Code..."
check "Claude Code 已安装" "$HOME/.local/bin/claude" --version
# Being installed is not the same as being found: test what a newly opened
# terminal window resolves, not an absolute path.
resolved="$(fresh_zsh_claude)"
if [ "${resolved#/}" != "$resolved" ] && [ -x "$resolved" ]; then
  pass "新开的终端窗口能找到 claude 命令（${resolved}）"
else
  flunk "新开的终端窗口找不到 claude 命令。请确认 ~/.zprofile 里有这一行：export PATH=\"\$HOME/.local/bin:\$PATH\"，并且 ~/.zshrc 没有重设 PATH。"
fi

check_credentials
finish
