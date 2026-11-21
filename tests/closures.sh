#!/bin/bash
#
# Checks the guard against real nix-darwin closures. Run with: tests/closures.sh
#
# It builds the flake for several machines (owner only, owner + customer,
# customer only), and for the owner + customer machine also as it was before
# the always-on settings existed and with one of those settings changed, and
# inspects the results. `nix build` only fills the Nix store: nothing is
# activated and no account has to exist. Needs Nix and network access; the
# first run downloads the closure and takes a few minutes.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/system-guard.sh
. "$repo_root/lib/system-guard.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
failed=0

# build NAME MACHINE [EDIT]: EDIT is a command run in the copy of the flake
# before it is built, to build a variant of it.
build() {
  local machine="$2" dir="$work_dir/$1"
  mkdir -p "$dir"
  cp -R "$repo_root/flake.nix" "$repo_root/flake.lock" "$repo_root/modules" "$dir/"
  printf '%s\n' "$machine" >"$dir/machine.nix"
  if [ -n "${3:-}" ]; then
    (cd "$dir" && eval "$3")
  fi
  nix --extra-experimental-features 'nix-command flakes' build \
    "path:$dir#darwinConfigurations.v2cc-test.system" --no-link --print-out-paths
}

# The lines of the activation step that are code, as modules/always-on.nix
# selects them.
always_on_code() {
  grep -Ev '^[[:space:]]*(#.*)?$' "$repo_root/modules/always-on.sh"
}

activate_lines() { grep -v '^systemConfig=' "$1/activate" | strip_hashes; }

# True when every line of stdin is a whole line of file $1.
# Called through expect.
# shellcheck disable=SC2329
all_lines_in() {
  local line
  while IFS= read -r line; do
    grep -Fxq -- "$line" "$1" || return 1
  done
}

expect() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    failed=1
  fi
}

owner="$(build owner '{ primaryUser = "howard"; homebrewUser = "howard"; users = [ "howard" ]; }')"
coexist="$(build coexist '{ primaryUser = "howard"; homebrewUser = "howard"; users = [ "howard" "v2cc" ]; }')"
customer="$(build customer '{ primaryUser = "v2cc"; homebrewUser = "v2cc"; users = [ "v2cc" ]; }')"
printf 'owner only:       %s\nowner + customer: %s\ncustomer only:    %s\n\n' "$owner" "$coexist" "$customer"

expect "owner closure: primary user and Home Manager account are read back" \
  test "$(sys_primary_user "$owner")/$(sys_hm_users "$owner" | tr '\n' ' ')" = "howard/howard "
expect "owner + customer closure: one primary user, two managed accounts" \
  test "$(sys_primary_user "$coexist")/$(sys_hm_users "$coexist" | tr '\n' ' ')" = "howard/howard v2cc "
expect "the owner's Home Manager generation is a real store path" \
  test -x "$(sys_hm_generation "$owner" howard)/activate"
expect "adding the customer leaves the owner's Home Manager generation byte-identical" \
  test "$(sys_hm_generation "$owner" howard)" = "$(sys_hm_generation "$coexist" howard)"

expect "guard accepts owner -> owner + customer" \
  guard_compare "$owner" "$coexist"

refused="$(guard_compare "$owner" "$customer" || true)"
printf '%s\n' "$refused" | sed 's/^/     | /'
expect "guard refuses owner -> customer only: owner would be removed" \
  grep -Fq '账户「howard」的 Home Manager 配置将被移除' <<<"$refused"
expect "guard refuses owner -> customer only: primary user would change" \
  grep -Fq '主用户 system.primaryUser 将从「howard」变为「v2cc」' <<<"$refused"

refused="$(guard_compare "$coexist" "$owner" || true)"
expect "guard refuses owner + customer -> owner only: customer would be removed" \
  grep -Fq '账户「v2cc」的 Home Manager 配置将被移除' <<<"$refused"

# ----------------------------------------------------------------- always-on
#
# The first always-on rollout lands on machines that already run the system
# this repository built before the always-on module existed. That earlier
# system is rebuilt here by taking the module out of the flake.

machine='{ primaryUser = "howard"; homebrewUser = "howard"; users = [ "howard" "v2cc" ]; }'
before="$(build before "$machine" \
  "grep -v 'modules/always-on.nix' flake.nix >flake.nix.new && mv flake.nix.new flake.nix")"
changed="$(build changed "$machine" \
  "sed -i '' 's/^v2cc_pmset sleep 0\$/v2cc_pmset sleep 5/' modules/always-on.sh")"
printf '\nbefore always-on:  %s\nwith always-on:    %s\none value changed: %s\n\n' "$before" "$coexist" "$changed"

expect "the earlier system has no always-on step, the current one has" \
  test "$(grep -c 'v2cc always-on:' "$before/activate")/$(grep -c 'v2cc always-on: machine-wide settings' "$coexist/activate")" = "0/1"
expect "the activation script carries every code line of modules/always-on.sh, unchanged" \
  all_lines_in "$coexist/activate" < <(always_on_code)
expect "comments of modules/always-on.sh stay out of the activation script" \
  test "$(grep -c 'Do not move the values into' "$coexist/activate")" = "0"
expect "the activation script with the always-on step is valid for the shell that runs it" \
  "$(sed -n '1s/^#![^ ]* -i //p' "$coexist/activate")" -n "$coexist/activate"

expect "guard accepts earlier system -> always-on as purely additive" \
  guard_compare "$before" "$coexist"
expect "adding always-on removes or changes no line of the activation script" \
  test -z "$(missing_from "$(activate_lines "$before")" "$(activate_lines "$coexist")")"
always_on_code >"$work_dir/always-on.code"
expect "every line always-on adds to the activation script is a code line of modules/always-on.sh" \
  all_lines_in "$work_dir/always-on.code" \
  < <(missing_from "$(activate_lines "$coexist")" "$(activate_lines "$before")")
expect "adding always-on leaves the owner's Home Manager generation byte-identical" \
  test "$(sys_hm_generation "$before" howard)" = "$(sys_hm_generation "$coexist" howard)"
expect "adding always-on leaves the customer's Home Manager generation byte-identical" \
  test "$(sys_hm_generation "$before" v2cc)" = "$(sys_hm_generation "$coexist" v2cc)"
expect "adding always-on changes no launchd service and no system command" \
  test "$(sys_launchd_units "$before")/$(sys_bin_names "$before")" = "$(sys_launchd_units "$coexist")/$(sys_bin_names "$coexist")"
expect "adding always-on removes nothing from the closure but the rebuilt system itself" \
  test "$(missing_from "$(sys_requisites "$before")" "$(sys_requisites "$coexist")")" = "$before"

refused="$(guard_compare "$coexist" "$changed" || true)"
printf '%s\n' "$refused" | sed 's/^/     | /'
expect "guard refuses a changed always-on value: exactly one activation line differs" \
  grep -Fq '当前系统的激活步骤中有 1 行将被移除或改变' <<<"$refused"
expect "guard accepts the changed value only when changes are explicitly allowed" \
  env V2CC_ALLOW_SYSTEM_CHANGES=1 /bin/bash -c ". '$repo_root/lib/system-guard.sh'; guard_compare '$coexist' '$changed'"

refused="$(guard_compare "$coexist" "$before" || true)"
expect "guard refuses taking always-on out again by redeploying" \
  grep -Fq '当前系统的激活步骤中有' <<<"$refused"

exit "$failed"
