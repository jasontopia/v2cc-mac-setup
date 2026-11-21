#!/bin/bash
# shellcheck shell=bash
#
# Read facts out of a nix-darwin system closure and compare two of them.
#
# A nix-darwin system is one machine-wide generation. Activating a closure
# that declares fewer accounts than the running one silently stops managing
# the others. Everything here is read-only, works without root, and takes
# plain paths, so the same functions inspect /run/current-system and a
# freshly built closure.

# The single system.primaryUser of a closure, or nothing.
sys_primary_user() {
  sed -n "s/^[[:space:]]*primaryUser=//p" "$1/activate" 2>/dev/null |
    head -n 1 | tr -d "'\""
}

# Accounts whose Home Manager configuration the closure activates.
sys_hm_users() {
  sed -n 's/^[[:space:]]*echo Activating home-manager configuration for \(.*\) >&2$/\1/p' \
    "$1/activate" 2>/dev/null | sort -u
}

# The Home Manager generation the closure activates for one account.
sys_hm_generation() {
  local wrapper
  wrapper="$(awk -v suffix="-activation-$2" '
    {
      for (i = 1; i <= NF; i++) {
        n = length($i) - length(suffix)
        if (n > 0 && substr($i, n + 1) == suffix) { print $i; exit }
      }
    }' "$1/activate" 2>/dev/null)"
  [ -n "$wrapper" ] && [ -r "$wrapper" ] || return 0
  sed -n 's/^[[:space:]]*exec \(.*\)\/activate --driver-version.*$/\1/p' "$wrapper" |
    head -n 1
}

sys_list() {
  local entry
  [ -d "$1" ] || return 0
  for entry in "$1"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    printf '%s\n' "${entry##*/}"
  done | sort
}

sys_profile_users() { sys_list "$1/etc/profiles/per-user"; }
sys_bin_names() { sys_list "$1/sw/bin"; }

sys_launchd_units() {
  sys_list "$1/Library/LaunchDaemons" | sed 's/^/daemon:/'
  sys_list "$1/user/Library/LaunchAgents" | sed 's/^/agent:/'
}

# True when the closure mentions Home Manager but no account could be read
# out of it: the format changed and the guard must not pretend all is well.
sys_hm_unparsed() {
  grep -q 'home-manager' "$1/activate" 2>/dev/null && [ -z "$(sys_hm_users "$1")" ]
}

# Every store path the closure depends on, itself included.
sys_requisites() {
  nix-store --query --requisites "$1" 2>/dev/null
}

# Drop the hash from store paths, so the same thing rebuilt compares equal.
strip_hashes() {
  sed -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/#g'
}

# Print the lines of list $1 that are missing from list $2.
missing_from() {
  LC_ALL=C comm -23 \
    <(printf '%s\n' "$1" | sed '/^$/d' | LC_ALL=C sort -u) \
    <(printf '%s\n' "$2" | sed '/^$/d' | LC_ALL=C sort -u)
}

count_lines() { printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' '; }
first_lines() { printf '%s\n' "$1" | head -n "$2" | tr '\n' ' '; }

# guard_compare CURRENT NEW
#
# Prints one line per reason the NEW closure must not replace CURRENT and
# returns 1 if there is any. With no CURRENT system nothing can be lost.
#
# The rule is that a deploy may only add to the running system:
#
#   - never: change the primary user, stop managing an account, remove a
#     per-user package environment, a launchd service or a system command;
#   - unless V2CC_ALLOW_SYSTEM_CHANGES=1 (a deliberate upgrade of the whole
#     machine): change an account's Home Manager generation, or remove or
#     change anything else the running closure contains or its activation
#     script does.
guard_compare() {
  local cur="$1" new="$2" problems=0 allow="${V2CC_ALLOW_SYSTEM_CHANGES:-0}"
  local user cur_primary new_primary cur_gen new_gen cur_req new_req lost

  if [ -z "$cur" ]; then
    return 0
  fi
  if [ ! -r "$cur/activate" ] || [ ! -r "$new/activate" ]; then
    printf '无法读取系统配置的 activate 脚本，无法确认现有账户是否安全。\n'
    return 1
  fi

  cur_primary="$(sys_primary_user "$cur")"
  new_primary="$(sys_primary_user "$new")"
  if [ -n "$cur_primary" ] && [ "$cur_primary" != "$new_primary" ]; then
    printf '主用户 system.primaryUser 将从「%s」变为「%s」：Homebrew、用户级默认设置和 launchd 用户服务会改归另一个账户。\n' \
      "$cur_primary" "${new_primary:-未设置}"
    problems=1
  fi

  if sys_hm_unparsed "$cur" || sys_hm_unparsed "$new"; then
    printf '无法从系统配置中识别 Home Manager 账户（格式与预期不符），拒绝继续。\n'
    problems=1
  fi

  for user in $(sys_hm_users "$cur"); do
    cur_gen="$(sys_hm_generation "$cur" "$user")"
    new_gen="$(sys_hm_generation "$new" "$user")"
    if ! sys_hm_users "$new" | grep -Fxq -- "$user"; then
      printf '账户「%s」的 Home Manager 配置将被移除：新配置没有声明该账户。\n' "$user"
      problems=1
    elif [ -z "$cur_gen" ] || [ -z "$new_gen" ]; then
      printf '无法确定账户「%s」的 Home Manager 配置，拒绝继续。\n' "$user"
      problems=1
    elif [ "$cur_gen" != "$new_gen" ] && [ "$allow" != "1" ]; then
      printf '账户「%s」的 Home Manager 配置将被改变（当前 %s，新 %s）。\n' \
        "$user" "$cur_gen" "$new_gen"
      problems=1
    fi
  done

  lost="$(missing_from "$(sys_profile_users "$cur")" "$(sys_profile_users "$new")")"
  if [ -n "$lost" ]; then
    printf '以下账户的软件包环境 /etc/profiles/per-user 将被移除：%s\n' "$(first_lines "$lost" 20)"
    problems=1
  fi

  lost="$(missing_from "$(sys_launchd_units "$cur")" "$(sys_launchd_units "$new")")"
  if [ -n "$lost" ]; then
    printf '以下 launchd 服务将被移除：%s\n' "$(first_lines "$lost" 20)"
    problems=1
  fi

  lost="$(missing_from "$(sys_bin_names "$cur")" "$(sys_bin_names "$new")")"
  if [ -n "$lost" ]; then
    printf '系统级命令将减少 %s 个（例如：%s）。\n' "$(count_lines "$lost")" "$(first_lines "$lost" 8)"
    problems=1
  fi

  if [ "$allow" = "1" ]; then
    return "$problems"
  fi

  # Additive only: whatever the running closure contains must still be in
  # the new one. The system itself and the aggregates derived from its
  # own path are rebuilt on every change; their contents are covered by
  # the checks above and by the activation script comparison below.
  cur_req="$(sys_requisites "$cur")"
  new_req="$(sys_requisites "$new")"
  if [ -z "$cur_req" ] || [ -z "$new_req" ]; then
    printf '无法读取系统配置的依赖闭包（nix-store），无法确认现有内容是否保留。\n'
    return 1
  fi
  lost="$(missing_from "$cur_req" "$new_req" | grep -Fxv -- "$cur" | strip_hashes |
    grep -Ev '^/nix/store/(etc|launchd|org\.nixos\.activate-system\.plist|activate-system-start)$' |
    sed 's#^/nix/store/##')"
  if [ -n "$lost" ]; then
    printf '当前系统中有 %s 项内容将被移除或改变（例如：%s）。\n' \
      "$(count_lines "$lost")" "$(first_lines "$lost" 8)"
    problems=1
  fi

  lost="$(missing_from \
    "$(grep -v '^systemConfig=' "$cur/activate" | strip_hashes)" \
    "$(grep -v '^systemConfig=' "$new/activate" | strip_hashes)")"
  if [ -n "$lost" ]; then
    printf '当前系统的激活步骤中有 %s 行将被移除或改变（例如系统默认设置、Homebrew 或 /etc 配置）。\n' \
      "$(count_lines "$lost")"
    problems=1
  fi

  return "$problems"
}
