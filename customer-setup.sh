#!/bin/bash
#
# V2CC Mac mini setup: the customer's own part.
#
# Run it in the customer account, a standard account without administrator
# rights, after bootstrap.sh has set up the system from the platform
# maintenance administrator account. It never uses sudo and never asks for
# a password. Everything it installs lives in the customer's own account:
#
#   - Claude Code, in ~/.local/bin (Anthropic's official installer);
#   - the shell setup in ~/.zprofile, so that a new Terminal window finds
#     Homebrew's commands, installs casks (apps) into ~/Applications, and
#     finds what `npm install -g` installed;
#   - ~/.npmrc, so that `npm install -g` installs into ~/.npm-global: the
#     preinstalled node lives in the read-only Nix store, where nobody can
#     install, administrator or not.
#
#   ./customer-setup.sh              do it
#   ./customer-setup.sh --dry-run    only report what would be done
#
# Safe to rerun: every line is added only once and Claude Code is installed
# only when it is missing.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh

for arg in "$@"; do
  case "$arg" in
    --dry-run) V2CC_DRY_RUN=1 ;;
    *) die "未知参数：${arg}（可用：--dry-run）" ;;
  esac
done
export V2CC_DRY_RUN

me="$(id -un)"
npm_prefix="$HOME/.npm-global"
# The literal text is what goes into ~/.zprofile; $HOME and $PATH expand
# when the new shell starts.
# shellcheck disable=SC2016
zprofile_lines="$(printf '%s\n' \
  "export PATH=\"$BREW_PREFIX/bin:$BREW_PREFIX/sbin:\$PATH\"" \
  'export HOMEBREW_CASK_OPTS="--appdir=$HOME/Applications"' \
  'export PATH="$HOME/.npm-global/bin:$PATH"')"

step_check() {
  local current_system customer brew_owner
  info "[1/4] 检查本机环境..."
  [ "$(id -u)" -ne 0 ] || die "请在客户账户里直接运行，不要使用 sudo 或 root。"
  current_system="$(resolve_link "$CURRENT_SYSTEM_LINK")"
  [ -n "$current_system" ] ||
    die "本机还没有部署 V2CC 系统配置。请先由平台在平台维护管理员账户里运行 ./bootstrap.sh。"
  customer="$(sys_customer_user "$current_system")"
  [ -n "$customer" ] ||
    die "本机的系统配置没有登记客户账户（部署的是更早的版本）。请先由平台按 docs/ONBOARDING.md 第 15 节「迁移」部署新版本。"
  [ "$me" = "$customer" ] ||
    die "本脚本只在客户账户 ${customer} 里运行，当前账户是 ${me}。系统部分在平台维护管理员账户里用 ./bootstrap.sh。"
  if is_admin "$me"; then
    die "客户账户 ${me} 仍是管理员。客户账户必须是普通账户（标准用户）：请平台先按 docs/ONBOARDING.md 第 15 节「迁移」取消它的管理员权限。"
  fi
  ok "客户账户 ${me}，普通账户（标准用户）"

  brew_owner="$(stat -f '%Su' "$BREW_PREFIX" 2>/dev/null || true)"
  if [ "$brew_owner" = "$me" ]; then
    ok "Homebrew（${BREW_PREFIX}）属于本账户：brew install 不需要管理员密码"
  else
    warn "Homebrew（${BREW_PREFIX}）属于账户「${brew_owner:-不存在}」，不属于本账户：在本账户里不能用 brew 安装。请联系平台（docs/ONBOARDING.md 第 15 节的 M5）。"
  fi
}

step_shell() {
  local line
  info "[2/4] Homebrew、npm 和应用安装位置..."
  while IFS= read -r line; do
    grep -Fqx -- "$line" "$HOME/.zprofile" 2>/dev/null && continue
    if is_dry_run; then
      printf '  [演练] 将在 %s 加入：%s\n' "$HOME/.zprofile" "$line"
    else
      printf '%s\n' "$line" >>"$HOME/.zprofile"
    fi
  done <<<"$zprofile_lines"

  if grep -q '^prefix[[:space:]]*=' "$HOME/.npmrc" 2>/dev/null; then
    ok "$HOME/.npmrc 已经设定了 npm 的安装位置，不改动：$(grep '^prefix[[:space:]]*=' "$HOME/.npmrc" | head -n 1)"
  elif is_dry_run; then
    printf '  [演练] 将在 %s 加入：prefix=%s\n' "$HOME/.npmrc" "$npm_prefix"
  else
    printf 'prefix=%s\n' "$npm_prefix" >>"$HOME/.npmrc"
  fi

  if is_dry_run; then
    printf '  [演练] 将建立目录：%s/bin、%s\n' "$npm_prefix" "$HOME/Applications"
  else
    mkdir -p "$npm_prefix/bin" "$HOME/Applications"
    ok "brew 的命令、npm install -g 的命令在新开的终端窗口里可用；brew install --cask 的应用装进 ~/Applications"
  fi
}

step_claude() {
  info "[3/4] Claude Code..."
  ./install-claude.sh
}

step_verify() {
  info "[4/4] 验证..."
  if is_dry_run; then
    printf '  [演练] 演练模式不做验证。\n'
    return 0
  fi
  ./verify.sh
}

info "V2CC Mac mini 部署：客户账户部分$(is_dry_run && printf '（演练模式，不改动任何东西）' || true)"
step_check
step_shell
step_claude
step_verify

if is_dry_run; then
  info "演练结束，没有任何改动。"
elif window_sees_claude; then
  info "V2CC 客户账户部署完成。现在可以运行 claude 开始使用。"
else
  info "V2CC 客户账户部署完成。"
  info "注意：这个终端窗口是在部署之前打开的，在它里面还找不到 claude 命令。"
  info "请新开一个终端窗口（⌘N），或者在本窗口运行：exec zsh -l"
  info "然后运行 claude 开始使用。"
fi
