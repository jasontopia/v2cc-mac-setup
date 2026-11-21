#!/bin/bash
#
# Build the system configuration, prove it keeps every account the running
# system manages, then switch to it. Rolls back if activation fails.
#
# Safe to rerun: nothing is activated when the built configuration is
# already the running one.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh
# shellcheck source=lib/always-on.sh
. ./lib/always-on.sh

use_nix_and_brew_path

command -v nix >/dev/null 2>&1 ||
  die "未找到 Nix。请运行 ./bootstrap.sh，它会检查并安装缺失的依赖。"
[ -x "$BREW_PREFIX/bin/brew" ] ||
  die "未找到 Homebrew。请运行 ./bootstrap.sh，它会检查并安装缺失的依赖。"

./prepare.sh

info "构建系统配置（只构建，不改动系统）..."
new_system="$(nix_flakes build "path:$PWD#darwinConfigurations.$FLAKE_ATTR.system" \
  --no-link --print-out-paths)"
[ -n "$new_system" ] && [ -x "$new_system/activate" ] ||
  die "构建没有产出可用的系统配置。"
new_system="$(resolve_link "$new_system")"
ok "新配置：$new_system"

current_system="$(resolve_link "$CURRENT_SYSTEM_LINK")"
profile_system="$(resolve_link "$SYSTEM_PROFILE")"

info "检查新配置是否会影响本机已有的账户..."
if [ -z "$current_system" ]; then
  ok "本机还没有 nix-darwin 系统配置，这是首次部署。"
elif problems="$(guard_compare "$current_system" "$new_system")"; then
  ok "当前系统管理的账户、服务和命令在新配置中全部保留。"
else
  printf '%s\n' "$problems" | while IFS= read -r line; do fail "$line"; done

  # Everything the operator needs to decide what to do, in one file, so
  # nobody has to run diagnostic commands by hand.
  report="$V2CC_STATE_DIR/guard-report.txt"
  mkdir -p "$V2CC_STATE_DIR"
  {
    printf 'V2CC 部署被安全检查拦截 %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '部署版本：%s\n' "$(cat .v2cc-commit 2>/dev/null || printf '未知')"
    printf '运行部署的账户：%s\n\n' "$(id -un)"
    printf '当前系统：%s\n' "$current_system"
    printf '  版本信息：%s\n' "$(tr -d '\n' <"$current_system/darwin-version.json" 2>/dev/null)"
    printf '  主用户：%s\n' "$(sys_primary_user "$current_system")"
    printf '  Home Manager 账户：%s\n\n' "$(sys_hm_users "$current_system" | tr '\n' ' ')"
    printf '新配置：%s\n' "$new_system"
    printf '  主用户：%s\n' "$(sys_primary_user "$new_system")"
    printf '  Home Manager 账户：%s\n\n' "$(sys_hm_users "$new_system" | tr '\n' ' ')"
    printf '拦截原因：\n%s\n\n' "$problems"
    printf '闭包差异（nix store diff-closures）：\n'
    nix_flakes store diff-closures "$current_system" "$new_system" 2>&1 |
      sed -E $'s/\x1b\\[[0-9;]*m//g' || true
  } >"$report"

  cat >&2 <<EOF

已停止，系统没有任何改动。
nix-darwin 的系统配置是整机唯一的一份：切换到新配置后，上面列出的内容
将被移除或改变。这通常说明本机当前的配置不是由本仓库的同一版本生成的
（例如机主有自己的 nix-darwin 配置，或本机部署的是旧版本）。
诊断信息已保存，请把这个文件发给 V2CC 运营方：
  $report
EOF
  exit 3
fi

# The always-on settings are written by the activation itself. They are due
# when the new configuration carries them and nothing on this machine shows
# they were applied: no record of the values from before. That is the case
# on a first rollout, and again after ./rollback.sh --settings.
always_on_due=0
if sys_declares_always_on "$new_system" && [ ! -e "$ALWAYS_ON_BEFORE" ]; then
  always_on_due=1
fi

if [ "$current_system" = "$new_system" ] && [ "$profile_system" = "$new_system" ] &&
  [ "$always_on_due" = "0" ]; then
  ok "新配置已经是当前系统，无需切换。"
  exit 0
fi

if [ -n "$current_system" ] && [ "$current_system" != "$new_system" ]; then
  info "与当前系统相比的变化："
  changes="$(nix_flakes store diff-closures "$current_system" "$new_system" 2>&1 || true)"
  if [ -n "$changes" ]; then
    printf '%s\n' "$changes"
  else
    note "软件包没有增加、减少或版本变化。"
  fi
fi

if [ "$always_on_due" = "1" ]; then
  # A change to the activation script alone does not show in the closure
  # difference above, and these settings reach every account on the Mac.
  info "本次切换会启用 7×24 在线设置。它们对整机生效，机主的账户同样受影响："
  note "系统空闲时不再自动睡眠（显示器仍按原设置自动关闭）"
  note "断电后恢复供电时自动开机"
  note "开启「唤醒以供网络访问」（本机支持时）"
  note "关闭闲置后自动退出登录"
  note "关闭「自动安装 macOS 更新」的开关，更新改为在维护时段由人安装（这个开关在 macOS 27 上能否挡住自动安装和重启，尚未在真机验证，见 docs/test-plan.md C 节阶段 4 的 4.2）；检查更新、更新通知和安全数据的自动安装不变"
  note "改动前的原值会记录在 ${ALWAYS_ON_BEFORE}，可用 ./rollback.sh 恢复"
fi

if is_dry_run; then
  info "[演练] 将把系统切换到 ${new_system}（未执行）。"
  exit 0
fi

if [ -n "$current_system" ]; then
  if [ "$always_on_due" = "1" ]; then
    confirm "将切换整机的系统配置，并启用上面列出的整机设置（已确认现有账户的配置保持不变）。继续？" ||
      die "已取消，系统没有任何改动。"
  else
    confirm "将切换整机的系统配置（已确认不影响现有账户）。继续？" ||
      die "已取消，系统没有任何改动。"
  fi
fi

# Record what to return to. When only the boot profile lags behind an
# already running system, the earlier record still names the real
# predecessor and is kept.
if [ "$current_system" != "$new_system" ]; then
  mkdir -p "$V2CC_STATE_DIR"
  {
    printf 'previous=%s\n' "$current_system"
    printf 'new=%s\n' "$new_system"
    printf 'allow_system_changes=%s\n' "${V2CC_ALLOW_SYSTEM_CHANGES:-0}"
    printf 'at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$V2CC_STATE_DIR/last-deploy"
fi

ensure_sudo "切换系统配置"

# The same two steps `darwin-rebuild switch` performs, applied to exactly
# the closure that was checked above.
info "激活系统配置..."
activated=0
if sudo -H "$NIX_DEFAULT_BIN/nix-env" -p "$SYSTEM_PROFILE" --set "$new_system" &&
  sudo "$new_system/activate"; then
  activated=1
fi

if [ "$activated" != "1" ] || [ "$(resolve_link "$CURRENT_SYSTEM_LINK")" != "$new_system" ]; then
  fail "激活失败。"
  rolled_back=0
  if [ -n "$current_system" ] && [ "$current_system" != "$new_system" ]; then
    info "正在回退到之前的系统配置..."
    ./rollback.sh --auto || die "自动回退失败。请联系 V2CC 运营方，并保留以上全部输出。"
    rolled_back=1
  fi
  # This activation was the one to apply the always-on settings for the
  # first time and may have stopped halfway through them. Returning to a
  # configuration without them has put them back already; in every other
  # case (the same configuration, an earlier one that carries them too, or
  # none at all) it is done here, so a failed activation leaves none behind.
  if [ "$always_on_due" = "1" ] && [ -e "$ALWAYS_ON_BEFORE" ]; then
    info "正在把 7×24 在线设置恢复为原值..."
    ./rollback.sh --auto --settings ||
      die "自动恢复设置失败。请联系 V2CC 运营方，并保留以上全部输出。"
  fi
  if [ "$rolled_back" = "1" ]; then
    die "激活失败，已回退到之前的系统配置。修复上面的错误后可以重新运行。"
  elif [ -n "$current_system" ]; then
    die "激活失败，系统配置没有变化。修复上面的错误后可以重新运行。"
  fi
  die "激活失败。本机此前没有系统配置可回退；修复上面的错误后重新运行即可。"
fi

ok "系统配置已激活：$new_system"
