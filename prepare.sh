#!/bin/bash
#
# Generate machine.nix from the live machine.
#
# Run in the platform maintenance administrator account, for the customer
# account named by V2CC_CUSTOMER (bootstrap.sh --customer sets it), or else
# the customer the running system already records.
#
# The set of managed accounts is the accounts the running system already
# manages plus the customer account. It never shrinks here, so no deploy
# can drop another account. The administrator running the deploy is not
# added: it needs no Home Manager configuration of its own.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh

current_user="$(id -un)"
[ "$(id -u)" -ne 0 ] || die "请用平台维护管理员账户直接运行，不要使用 sudo 或 root。"
valid_username "$current_user" || die "账户名「${current_user}」含有不支持的字符。"

current_system="$(resolve_link "$CURRENT_SYSTEM_LINK")"
existing_users=""
primary_user=""
recorded_customer=""
if [ -n "$current_system" ]; then
  existing_users="$(sys_hm_users "$current_system")"
  primary_user="$(sys_primary_user "$current_system")"
  recorded_customer="$(sys_customer_user "$current_system")"
fi
[ -n "$primary_user" ] || primary_user="$current_user"

customer="${V2CC_CUSTOMER:-$recorded_customer}"
[ -n "$customer" ] ||
  die "没有指定客户账户，本机的系统配置里也没有登记。请用 ./bootstrap.sh --customer <客户账户名> 运行。"
check_customer_account "$customer"

users="$(printf '%s\n%s\n' "$existing_users" "$customer" | sed '/^$/d' | sort -u)"

for user in $users "$primary_user"; do
  valid_username "$user" || die "账户名「${user}」含有不支持的字符。"
  id -u -- "$user" >/dev/null 2>&1 ||
    die "当前系统配置管理的账户「${user}」在本机已不存在。请先由机主确认如何处理，再重新部署。"
done

# homebrew.user is "the user that owns the Homebrew installation". After
# bootstrap.sh that is the customer account.
if [ -e "$BREW_PREFIX" ]; then
  homebrew_user="$(stat -f '%Su' "$BREW_PREFIX")"
  valid_username "$homebrew_user" ||
    die "无法确定 Homebrew 目录 $BREW_PREFIX 的所属账户。"
else
  homebrew_user="$customer"
fi

tmp_file="$(mktemp ./machine.nix.XXXXXX)"
{
  printf '# 由 prepare.sh 根据本机状态生成，请勿手工修改或提交。\n'
  printf '{\n'
  printf '  primaryUser = "%s";\n' "$primary_user"
  printf '  homebrewUser = "%s";\n' "$homebrew_user"
  printf '  customerUser = "%s";\n' "$customer"
  printf '  users = ['
  for user in $users; do
    printf ' "%s"' "$user"
  done
  printf ' ];\n'
  printf '}\n'
} >"$tmp_file"
mv "$tmp_file" machine.nix

info "本机配置已生成"
ok "运行部署的账户：$current_user"
ok "客户账户（普通账户）：$customer"
ok "受管理的账户：$(printf '%s' "$users" | tr '\n' ' ')"
ok "主用户（system.primaryUser）：$primary_user"
ok "Homebrew 所属账户：$homebrew_user"
if [ -n "$existing_users" ] && [ "$existing_users" != "$customer" ]; then
  ok "已保留当前系统中已有的账户配置：$(printf '%s' "$existing_users" | tr '\n' ' ')"
fi
