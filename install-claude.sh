#!/bin/bash
#
# Install Claude Code for the current account with Anthropic's official
# installer. Skips the install when it is already there.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh

claude_bin="$HOME/.local/bin/claude"
# The literal text is what goes into ~/.zprofile.
# shellcheck disable=SC2016
path_line='export PATH="$HOME/.local/bin:$PATH"'

if [ -x "$claude_bin" ]; then
  ok "Claude Code 已安装，跳过。"
elif is_dry_run; then
  printf '  [演练] 将执行：Claude Code 官方安装脚本 %s\n' "$CLAUDE_INSTALL_URL"
else
  info "安装 Claude Code..."
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  # Download completely before running, so a broken connection can never
  # execute half a script.
  curl --proto '=https' --tlsv1.2 -fsSL "$CLAUDE_INSTALL_URL" -o "$work_dir/install.sh" ||
    die "下载 Claude Code 安装脚本失败。"
  /bin/bash "$work_dir/install.sh"
fi

if ! grep -Fqx "$path_line" "$HOME/.zprofile" 2>/dev/null; then
  if is_dry_run; then
    printf '  [演练] 将执行：把 ~/.local/bin 加入 %s\n' "$HOME/.zprofile"
  else
    printf '%s\n' "$path_line" >>"$HOME/.zprofile"
  fi
fi

if [ -x "$claude_bin" ]; then
  ok "Claude Code：$("$claude_bin" --version)"
elif ! is_dry_run; then
  die "Claude Code 安装后仍不可用：$claude_bin"
fi
