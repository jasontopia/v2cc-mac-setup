#!/bin/bash
#
# Return the machine to the system configuration that was running before
# the last deploy.
#
#   ./rollback.sh                    roll back to the recorded previous system
#   ./rollback.sh --to <store-path>  roll back to a specific system
#   ./rollback.sh --list             show the available system generations
#
# This re-activates the previous configuration; it does not delete files in
# any home directory.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh

auto=0
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) auto=1 ;;
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

if [ -z "$target" ]; then
  state_file="$V2CC_STATE_DIR/last-deploy"
  [ -r "$state_file" ] ||
    die "没有找到上次部署的记录（${state_file}）。可用 ./rollback.sh --list 查看历史版本，再用 --to 指定。"
  target="$(sed -n 's/^previous=//p' "$state_file" | head -n 1)"
  [ -n "$target" ] ||
    die "上次部署是本机的首次部署，没有可回退的系统配置。"
fi

[ -x "$target/activate" ] ||
  die "系统配置不存在或已被清理：$target"
target="$(resolve_link "$target")"

current_system="$(resolve_link "$CURRENT_SYSTEM_LINK")"
info "回退目标：$target"
ok "该配置管理的账户：$(sys_hm_users "$target" | tr '\n' ' ')"
if [ "$current_system" = "$target" ] && [ "$(resolve_link "$SYSTEM_PROFILE")" = "$target" ]; then
  ok "当前系统已经是该配置，无需回退。"
  exit 0
fi

if is_dry_run; then
  info "[演练] 将把系统回退到 ${target}（未执行）。"
  exit 0
fi

if [ "$auto" != "1" ]; then
  confirm "将把整机的系统配置回退到上面的版本。继续？" || die "已取消。"
  ensure_sudo "回退系统配置"
fi

sudo -H "$NIX_DEFAULT_BIN/nix-env" -p "$SYSTEM_PROFILE" --set "$target"
sudo "$target/activate"

[ "$(resolve_link "$CURRENT_SYSTEM_LINK")" = "$target" ] ||
  die "回退后的系统与目标不一致，请联系 V2CC 运营方。"
ok "已回退到：$target"
