#!/bin/bash
# shellcheck shell=bash
#
# Shared helpers for the V2CC Mac setup scripts.
#
# A blank Mac only ships /bin/bash 3.2, so everything here and in the
# scripts that source it must stay bash 3.2 compatible.
#
# The constants below are used by the scripts that source this file.
# shellcheck disable=SC2034

# Test hook: every absolute system path below is resolved under this prefix.
# It is empty on a real machine.
V2CC_SYSROOT="${V2CC_SYSROOT:-}"

# 1 = print what would change instead of changing it.
V2CC_DRY_RUN="${V2CC_DRY_RUN:-0}"

# 1 = answer the script's own yes/no questions with yes. It never bypasses
# macOS authorization prompts or any safety block.
V2CC_ASSUME_YES="${V2CC_ASSUME_YES:-0}"

V2CC_STATE_DIR="${V2CC_STATE_DIR:-$HOME/.local/state/v2cc}"

FLAKE_ATTR="v2cc-test"
CURRENT_SYSTEM_LINK="$V2CC_SYSROOT/run/current-system"
SYSTEM_PROFILE="$V2CC_SYSROOT/nix/var/nix/profiles/system"
NIX_DEFAULT_BIN="$V2CC_SYSROOT/nix/var/nix/profiles/default/bin"
NIX_RECEIPT="$V2CC_SYSROOT/nix/receipt.json"
BREW_PREFIX="$V2CC_SYSROOT/opt/homebrew"
CLT_PLACEHOLDER="$V2CC_SYSROOT/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

# Third-party installers are fetched from immutable, versioned URLs and
# checked against these hashes before anything is executed.
DETERMINATE_NIX_VERSION="v3.24.3"
DETERMINATE_NIX_URL="https://install.determinate.systems/nix/tag/${DETERMINATE_NIX_VERSION}/nix-installer-aarch64-darwin"
DETERMINATE_NIX_SHA256="538c267c0bd419e02cb36f938fbf13683aa7046444d76306da2b5a72f4e340db"
HOMEBREW_INSTALL_COMMIT="ca45114992228ce6d708d49ef6becf5fb19100a1"
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_COMMIT}/install.sh"
HOMEBREW_INSTALL_SHA256="8fd2f1a5287a7c2e3d7362924c677edcc04c5a0e16448c77132d056bc88cf1ed"
# Anthropic publishes no versioned URL for this script. It verifies the
# binary it downloads against Anthropic's own release manifest.
CLAUDE_INSTALL_URL="https://claude.ai/install.sh"

info() { printf '==> %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '  ✗ %s\n' "$*" >&2; }

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

is_dry_run() { [ "$V2CC_DRY_RUN" = "1" ]; }

# Run a command that changes the machine, or only print it in a dry run.
run_mut() {
  if is_dry_run; then
    printf '  [演练] 将执行：%s\n' "$*"
    return 0
  fi
  "$@"
}

# Ask a yes/no question. Refuses rather than guesses when nobody can answer.
confirm() {
  local answer
  if [ "$V2CC_ASSUME_YES" = "1" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "需要人工确认「$1」，但当前不是交互终端。请在终端中直接运行。"
  fi
  read -r -p "$1 [y/N] " answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# macOS requires an administrator password for system changes. Ask once,
# up front, so the reason is clear.
ensure_sudo() {
  if is_dry_run; then
    return 0
  fi
  info "${1}需要管理员授权，请按提示输入当前账户的登录密码。"
  sudo -v || die "未获得管理员授权，已停止。"
}

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# fetch_verified URL SHA256 DEST: download over HTTPS and keep the file only
# if it matches the pinned hash.
fetch_verified() {
  local url="$1" expected="$2" dest="$3" actual
  curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$dest" ||
    die "下载失败：$url"
  actual="$(sha256_of "$dest")"
  if [ "$actual" != "$expected" ]; then
    rm -f "$dest"
    die "完整性校验失败，已删除下载内容：$url"
  fi
}

# Account names end up inside a Nix string and a shell command line.
valid_username() {
  case "$1" in
    '' | *[!a-z0-9_.-]* | -* | .*) return 1 ;;
    *) return 0 ;;
  esac
}

# Print the store path a symlink resolves to, or nothing when it is absent.
resolve_link() {
  if [ -e "$1" ]; then
    (cd -P "$1" 2>/dev/null && pwd -P)
  fi
}

use_nix_and_brew_path() {
  PATH="$NIX_DEFAULT_BIN:$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"
  export PATH
}

nix_flakes() {
  nix --extra-experimental-features 'nix-command flakes' "$@"
}
