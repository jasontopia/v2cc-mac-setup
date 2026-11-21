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
fi

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
