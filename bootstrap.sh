#!/bin/bash
#
# V2CC Mac mini setup: the single entry point.
#
# Run it in the account that will use Claude Code (a separate administrator
# account such as `v2cc`). It checks the machine, installs whatever is
# missing, deploys the system configuration, installs Claude Code and
# verifies the result. Everything already in place is skipped, so it is
# safe to rerun after a failure.
#
#   ./bootstrap.sh              do it
#   ./bootstrap.sh --dry-run    only report what would be done
#
# macOS asks for the account password (administrator authorization) and may
# show its own install dialogs; those cannot be automated away.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh

for arg in "$@"; do
  case "$arg" in
    --dry-run) V2CC_DRY_RUN=1 ;;
    *) die "未知参数：${arg}（可用：--dry-run）" ;;
  esac
done
export V2CC_DRY_RUN

# What a dry run could not actually install, so later steps know why
# something is missing.
pending=""

clt_installed() {
  local dir
  dir="$(xcode-select -p 2>/dev/null)" || return 1
  [ -e "$V2CC_SYSROOT$dir/usr/bin/git" ]
}

nix_installed() { [ -x "$NIX_DEFAULT_BIN/nix" ]; }
brew_installed() { [ -x "$BREW_PREFIX/bin/brew" ]; }

step_preflight() {
  local os_major free_gb
  info "[1/7] 检查本机环境..."

  [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] ||
    die "仅支持 Apple Silicon Mac。"
  [ "$(id -u)" -ne 0 ] ||
    die "请用要使用 Claude Code 的账户直接运行，不要使用 sudo 或 root。"
  id -Gn | tr ' ' '\n' | grep -Fxq admin ||
    die "当前账户 $(id -un) 不是管理员。请机主在「系统设置 > 用户与群组」中把它设为管理员后重试。"

  os_major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$os_major" -ge 14 ] 2>/dev/null ||
    die "需要 macOS 14 或更新版本（当前 $(sw_vers -productVersion)）。"

  free_gb="$(df -g "$HOME" | awk 'NR == 2 { print $4 }')"
  [ "${free_gb:-0}" -ge 15 ] 2>/dev/null ||
    die "磁盘可用空间不足：需要至少 15 GB，当前 ${free_gb:-未知} GB。"

  ok "Apple Silicon，macOS $(sw_vers -productVersion)，管理员账户 $(id -un)，可用空间 ${free_gb} GB"
}

step_clt() {
  local label waited=0
  info "[2/7] Xcode Command Line Tools..."
  if clt_installed; then
    ok "已安装，跳过。"
    return 0
  fi
  if is_dry_run; then
    printf '  [演练] 将执行：通过 softwareupdate 安装 Xcode Command Line Tools\n'
    pending="$pending clt"
    return 0
  fi

  ensure_sudo "安装 Xcode Command Line Tools"
  # The placeholder makes softwareupdate offer the Command Line Tools, the
  # same way Homebrew's installer does it.
  sudo /usr/bin/touch "$CLT_PLACEHOLDER"
  label="$(softwareupdate -l 2>/dev/null |
    sed -n 's/^.*Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -n 1)"
  if [ -n "$label" ]; then
    info "正在安装 ${label}（需要几分钟）..."
    sudo softwareupdate -i "$label" || warn "softwareupdate 安装未成功，改用系统安装对话框。"
  fi
  sudo /bin/rm -f "$CLT_PLACEHOLDER"

  if ! clt_installed; then
    info "请在弹出的系统对话框中点击「安装」，完成后本脚本会自动继续。"
    xcode-select --install >/dev/null 2>&1 || true
    while ! clt_installed; do
      [ "$waited" -lt 3600 ] ||
        die "等待 Xcode Command Line Tools 安装超时。安装完成后重新运行本命令即可。"
      sleep 10
      waited=$((waited + 10))
    done
  fi
  ok "安装完成。"
}

step_nix() {
  local work_dir
  info "[3/7] Determinate Nix..."
  if nix_installed; then
    ok "已安装，跳过（$("$NIX_DEFAULT_BIN/nix" --version)）。"
    return 0
  fi
  [ ! -e "$NIX_RECEIPT" ] ||
    die "检测到不完整的 Nix 安装（存在 $NIX_RECEIPT 但没有 nix 命令）。请先运行 /nix/nix-installer uninstall 再重试。"
  if is_dry_run; then
    printf '  [演练] 将执行：下载并校验 Determinate Nix 安装器 %s，然后安装\n' "$DETERMINATE_NIX_VERSION"
    pending="$pending nix"
    return 0
  fi

  work_dir="$(mktemp -d)"
  info "下载并校验 Determinate Nix 安装器 $DETERMINATE_NIX_VERSION..."
  fetch_verified "$DETERMINATE_NIX_URL" "$DETERMINATE_NIX_SHA256" "$work_dir/nix-installer"
  chmod u+x "$work_dir/nix-installer"
  ensure_sudo "安装 Determinate Nix"
  "$work_dir/nix-installer" install --no-confirm ||
    die "Determinate Nix 安装失败。按上面的提示处理后重新运行本命令即可。"
  rm -rf "$work_dir"
  nix_installed || die "Determinate Nix 安装后仍找不到 nix 命令。"
  ok "安装完成。"
}

step_brew() {
  local work_dir
  info "[4/7] Homebrew..."
  if brew_installed; then
    ok "已安装，跳过。"
    return 0
  fi
  if is_dry_run; then
    printf '  [演练] 将执行：下载并校验 Homebrew 官方安装脚本（%s），然后安装\n' "$HOMEBREW_INSTALL_COMMIT"
    pending="$pending brew"
    return 0
  fi

  work_dir="$(mktemp -d)"
  info "下载并校验 Homebrew 官方安装脚本..."
  fetch_verified "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$work_dir/install.sh"
  ensure_sudo "安装 Homebrew"
  NONINTERACTIVE=1 /bin/bash "$work_dir/install.sh" ||
    die "Homebrew 安装失败。按上面的提示处理后重新运行本命令即可。"
  rm -rf "$work_dir"
  brew_installed || die "Homebrew 安装后仍找不到 brew 命令。"
  ok "安装完成。"
}

step_deploy() {
  info "[5/7] 系统配置..."
  if [ -n "$pending" ]; then
    printf '  [演练] 依赖尚未安装（%s），无法构建和检查系统配置；实际运行时会在此构建、检查并切换。\n' "${pending# }"
    return 0
  fi
  ./deploy.sh
}

step_claude() {
  info "[6/7] Claude Code..."
  ./install-claude.sh
}

step_verify() {
  info "[7/7] 验证..."
  if is_dry_run; then
    printf '  [演练] 演练模式不做部署后验证。\n'
    return 0
  fi
  ./verify.sh
}

info "V2CC Mac mini 部署$(is_dry_run && printf '（演练模式，不改动系统）' || true)"
step_preflight
step_clt
step_nix
use_nix_and_brew_path
step_brew
step_deploy
step_claude
step_verify

if is_dry_run; then
  info "演练结束，系统没有任何改动。"
else
  info "V2CC 部署完成。请重新打开终端，然后运行 claude 开始使用。"
fi
