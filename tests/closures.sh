#!/bin/bash
#
# Checks the guard against real nix-darwin closures. Run with: tests/closures.sh
#
# It builds the flake three times (owner only, owner + customer, customer
# only) and inspects the results. `nix build` only fills the Nix store:
# nothing is activated and no account has to exist. Needs Nix and network
# access; the first run downloads the closure and takes a few minutes.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/system-guard.sh
. "$repo_root/lib/system-guard.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
failed=0

build() {
  local machine="$2" dir="$work_dir/$1"
  mkdir -p "$dir"
  cp "$repo_root/flake.nix" "$repo_root/flake.lock" "$dir/"
  printf '%s\n' "$machine" >"$dir/machine.nix"
  nix --extra-experimental-features 'nix-command flakes' build \
    "path:$dir#darwinConfigurations.v2cc-test.system" --no-link --print-out-paths
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

exit "$failed"
