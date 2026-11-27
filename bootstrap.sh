#!/bin/bash
#
# V2CC Mac mini setup: the system part, the single entry point for it.
#
# Run it in the platform maintenance administrator account, never in the
# customer's account: the customer account is a standard account without
# administrator rights. It checks the machine, installs whatever is
# missing, hands Homebrew to the customer account, deploys the system
# configuration and verifies the result. Everything already in place is
# skipped, so it is safe to rerun after a failure.
#
#   ./bootstrap.sh --customer <account>            do it
#   ./bootstrap.sh --customer <account> --dry-run  only report what would be done
#   ./bootstrap.sh                                 rerun for the customer already recorded
#
# The customer's own part (Claude Code and the shell setup for brew, npm
# and casks) is customer-setup.sh, run afterwards in the customer account.
#
# macOS asks for the account password (administrator authorization) and may
# show its own install dialogs; those cannot be automated away.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh

usage="用法：./bootstrap.sh --customer <客户账户名> [--dry-run]"
customer="${V2CC_CUSTOMER:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) V2CC_DRY_RUN=1 ;;
    --customer)
      [ $# -ge 2 ] || die "--customer 需要客户账户名。$usage"
      customer="$2"
      shift
      ;;
    *) die "未知参数：${1}。$usage" ;;
  esac
  shift
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
  info "[1/6] 检查本机环境..."

  [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] ||
    die "仅支持 Apple Silicon Mac。"
  [ "$(id -u)" -ne 0 ] ||
    die "请用平台维护管理员账户直接运行，不要使用 sudo 或 root。"
  is_admin "$(id -un)" ||
    die "当前账户 $(id -un) 不是管理员。本脚本要在平台维护管理员账户里运行；客户账户是普通账户，它自己的部分用 ./customer-setup.sh。"

  # On a rerun the running system remembers the customer.
  [ -n "$customer" ] || customer="$(sys_customer_user "$(resolve_link "$CURRENT_SYSTEM_LINK")")"
  [ -n "$customer" ] || die "请指定客户账户。$usage"
  check_customer_account "$customer"
  export V2CC_CUSTOMER="$customer"

  os_major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$os_major" -ge 14 ] 2>/dev/null ||
    die "需要 macOS 14 或更新版本（当前 $(sw_vers -productVersion)）。"

  free_gb="$(df -g "$HOME" | awk 'NR == 2 { print $4 }')"
  [ "${free_gb:-0}" -ge 15 ] 2>/dev/null ||
    die "磁盘可用空间不足：需要至少 15 GB，当前 ${free_gb:-未知} GB。"

  ok "Apple Silicon，macOS $(sw_vers -productVersion)，可用空间 ${free_gb} GB"
  ok "运行部署的管理员账户：$(id -un)；客户账户（普通账户）：$customer"
}

step_clt() {
  local label waited=0
  info "[2/6] Xcode Command Line Tools..."
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
    if sudo softwareupdate -i "$label"; then
      sudo xcode-select --switch /Library/Developer/CommandLineTools
    else
      warn "softwareupdate 安装未成功，改用系统安装对话框。"
    fi
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
  info "[3/6] Determinate Nix..."
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
  info "[4/6] Homebrew..."
  if brew_installed; then
    ok "已安装。"
  elif is_dry_run; then
    printf '  [演练] 将执行：下载并校验 Homebrew 官方安装脚本（%s），然后安装\n' "$HOMEBREW_INSTALL_COMMIT"
    printf '  [演练] 安装后将把 %s 交给客户账户 %s\n' "$BREW_PREFIX" "$customer"
    pending="$pending brew"
    return 0
  else
    work_dir="$(mktemp -d)"
    info "下载并校验 Homebrew 官方安装脚本..."
    fetch_verified "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$work_dir/install.sh"
    ensure_sudo "安装 Homebrew"
    NONINTERACTIVE=1 /bin/bash "$work_dir/install.sh" ||
      die "Homebrew 安装失败。按上面的提示处理后重新运行本命令即可。"
    rm -rf "$work_dir"
    brew_installed || die "Homebrew 安装后仍找不到 brew 命令。"
    ok "安装完成。"
  fi
  hand_over_brew
}

# Homebrew has exactly one owner, and only that account can install with
# it. Give the copy this account just installed to the customer, with the
# ownership and permissions Homebrew's own installer gives a standard
# account (owner, its group staff, not writable by anyone else), so that
# `brew install` in the customer account needs no password. A Homebrew that
# belongs to another account, such as the machine owner's, is not ours to
# hand over and is only reported.
hand_over_brew() {
  local owner
  owner="$(stat -f '%Su' "$BREW_PREFIX")"
  if [ "$owner" = "$customer" ]; then
    ok "Homebrew 属于客户账户 ${customer}。"
    return 0
  fi
  if [ "$owner" != "$(id -un)" ]; then
    warn "Homebrew（${BREW_PREFIX}）属于账户 ${owner}，不属于客户账户 ${customer}。本脚本不改动别的账户的 Homebrew，所以在这台机器上客户不能自己 brew install。是否交给客户由机主决定，见 docs/ONBOARDING.md 第 15 节「迁移」的 M5。"
    return 0
  fi
  if is_dry_run; then
    printf '  [演练] 将执行：sudo chown -R %s:staff %s，然后 sudo chmod -R go-w %s\n' \
      "$customer" "$BREW_PREFIX" "$BREW_PREFIX"
    return 0
  fi
  ensure_sudo "把 Homebrew 交给客户账户"
  if ! { sudo chown -R "$customer:staff" "$BREW_PREFIX" && sudo chmod -R go-w "$BREW_PREFIX"; }; then
    die "未能把 ${BREW_PREFIX} 交给客户账户 ${customer}。修复上面的错误后重新运行本命令即可。"
  fi
  [ "$(stat -f '%Su' "$BREW_PREFIX")" = "$customer" ] ||
    die "${BREW_PREFIX} 的所属账户仍然不是 ${customer}。"
  ok "Homebrew 已交给客户账户 ${customer}：只有这个账户能用它安装和卸载，不需要管理员密码。"
}

step_deploy() {
  info "[5/6] 系统配置..."
  if [ -n "$pending" ]; then
    printf '  [演练] 依赖尚未安装（%s），无法构建和检查系统配置；实际运行时会在此构建、检查并切换。\n' "${pending# }"
    return 0
  fi
  ./deploy.sh
}

step_verify() {
  info "[6/6] 验证..."
  if is_dry_run; then
    printf '  [演练] 演练模式不做部署后验证。\n'
    return 0
  fi
  ./verify.sh
}

info "V2CC Mac mini 部署：系统部分$(is_dry_run && printf '（演练模式，不改动系统）' || true)"
step_preflight
step_clt
step_nix
use_nix_and_brew_path
step_brew
step_deploy
step_verify

if is_dry_run; then
  info "演练结束，系统没有任何改动。"
else
  info "V2CC 系统部分部署完成。"
  info "接下来在客户账户 ${customer} 里运行客户入口命令（tools/make-entry-command.sh --customer-setup 生成），装好 Claude Code 和 brew、npm 的使用环境。"
fi
