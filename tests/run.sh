#!/bin/bash
#
# Stub-based tests for the setup scripts. Run with: tests/run.sh
#
# They run under macOS's own /bin/bash 3.2, the only shell a blank Mac has,
# against a fake machine (see tests/lib.sh). No sudo, installer or system
# switch is ever really executed.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# --------------------------------------------------------------------- lint

# bash 3.2 reads the first byte of a CJK character as part of the variable
# name, so "$name（" fails with "unbound variable". shellcheck cannot see it.
begin_test "lint: every variable directly before non-ASCII text is braced"
out="$(LC_ALL=en_US.UTF-8 perl -CSD -ne \
  'print "$ARGV: $1\n" while /(\$[A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7F])/g' \
  "$REPO_ROOT"/*.sh "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/tools/*.sh)"
assert_eq "$out" ""
end_test

# ---------------------------------------------------------------- blank Mac

begin_test "blank Mac: one command installs everything, deploys and verifies"
run bootstrap.sh
assert_rc 0
assert_called '^softwareupdate -i Command Line Tools for Xcode-26.1$'
assert_called '^xcode-select --switch /Library/Developer/CommandLineTools$'
assert_called '^nix-installer install --no-confirm$'
assert_called '^brew-installer NONINTERACTIVE=1$'
assert_called "^nix-env -p $SB/root/nix/var/nix/profiles/system --set $(system_path fresh)$"
assert_called '^activate fresh$'
assert_called '^claude-installer$'
assert_order '^softwareupdate -i' '^nix-installer install'
assert_order '^nix-installer install' '^brew-installer'
assert_order '^brew-installer' '^nix .* build '
assert_order '^nix .* build ' '^activate fresh$'
assert_order '^activate fresh$' '^claude-installer$'
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path fresh)"
assert_eq "$(tr -d ' \n' <"$SB/repo/machine.nix" | sed 's/^#[^{]*//')" \
  '{primaryUser="v2cc";homebrewUser="v2cc";users=["v2cc"];}'
assert_out "这是首次部署"
assert_out "验证通过"
assert_out "V2CC 部署完成"
assert_missing "$SB/root/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
end_test

begin_test "blank Mac: rerun changes nothing"
run bootstrap.sh
: >"$SB/calls.log"
run bootstrap.sh
assert_rc 0
assert_not_called '^softwareupdate -i'
assert_not_called '^nix-installer'
assert_not_called '^brew-installer'
assert_not_called '^claude-installer'
assert_not_called '^nix-env'
assert_not_called '^activate'
assert_not_called '^sudo'
assert_out "新配置已经是当前系统，无需切换"
assert_out "验证通过"
end_test

begin_test "blank Mac: dry run reports the plan and changes nothing"
run bootstrap.sh --dry-run
assert_rc 0
assert_not_called '^sudo'
assert_not_called '^softwareupdate -i'
assert_not_called '^curl'
assert_not_called 'installer'
assert_not_called '^activate'
assert_out "[演练] 将执行：通过 softwareupdate 安装 Xcode Command Line Tools"
assert_out "[演练] 将执行：下载并校验 Determinate Nix 安装器"
assert_out "[演练] 将执行：下载并校验 Homebrew 官方安装脚本"
assert_out "演练结束，系统没有任何改动"
assert_missing "$SB/root/run/current-system"
assert_missing "$SB/root/opt/homebrew"
assert_missing "$SB/home/.zprofile"
end_test

begin_test "blank Mac: softwareupdate cannot install CLT, falls back to the system dialog"
: >"$SB/state/clt_softwareupdate_fails"
run bootstrap.sh
assert_rc 0
assert_called '^xcode-select --install$'
assert_out "验证通过"
end_test

# ------------------------------------------------------- partially installed

begin_test "partly installed: only the missing dependency is installed"
have_clt
have_nix
run bootstrap.sh
assert_rc 0
assert_not_called '^softwareupdate'
assert_not_called '^nix-installer'
assert_called '^brew-installer NONINTERACTIVE=1$'
assert_out "验证通过"
end_test

begin_test "partly installed: a broken Nix install stops with instructions"
have_clt
: >"$SB/root/nix/receipt.json"
run bootstrap.sh
assert_rc_nonzero
assert_out "检测到不完整的 Nix 安装"
assert_not_called '^curl'
assert_not_called '^activate'
end_test

# ------------------------------------------------------ rerun after failure

begin_test "failure: a tampered Nix installer is never executed"
echo tampered >"$SB/state/nix_payload"
run bootstrap.sh
assert_rc_nonzero
assert_out "完整性校验失败"
assert_not_called '^nix-installer'
assert_not_called '^activate'
end_test

begin_test "failure: Nix install fails, the rerun picks up where it stopped"
: >"$SB/state/nix_install_fails"
run bootstrap.sh
assert_rc_nonzero
assert_out "Determinate Nix 安装失败"
assert_not_called '^brew-installer'
rm "$SB/state/nix_install_fails"
: >"$SB/calls.log"
run bootstrap.sh
assert_rc 0
assert_not_called '^softwareupdate -i'
assert_called '^nix-installer install --no-confirm$'
assert_out "验证通过"
end_test

begin_test "failure: first activation fails on a blank Mac, the rerun succeeds"
: >"$SB/state/activate_fails_fresh"
run bootstrap.sh
assert_rc_nonzero
assert_out "本机此前没有系统配置可回退"
assert_not_called '^claude-installer'
assert_missing "$SB/root/run/current-system"
rm "$SB/state/activate_fails_fresh"
: >"$SB/calls.log"
run bootstrap.sh
assert_rc 0
assert_not_called 'installer install'
assert_called '^activate fresh$'
assert_out "验证通过"
end_test

begin_test "failure: activation fails with an owner present, the old system is restored"
have_clt
have_nix
have_brew
echo howard >"$SB/state/brew_owner"
make_system owner howard "howard=gen-howard"
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
set_running_system owner
system_path coexist >"$SB/state/new_system"
: >"$SB/state/activate_fails_coexist"
RUN_ENV="V2CC_ASSUME_YES=1"
run bootstrap.sh
assert_rc_nonzero
assert_out "激活失败，已回退到之前的系统配置"
assert_order '^activate coexist$' '^activate owner$'
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path owner)"
assert_eq "$(link_target "$SB/root/nix/var/nix/profiles/system")" "$(system_path owner)"
rm "$SB/state/activate_fails_coexist"
RUN_ENV="V2CC_ASSUME_YES=1"
run bootstrap.sh
assert_rc 0
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path coexist)"
assert_out "验证通过"
end_test

# ------------------------------------------------------------- owner present

owner_machine() {
  have_clt
  have_nix
  have_brew
  echo howard >"$SB/state/brew_owner"
  make_system owner howard "howard=gen-howard"
  set_running_system owner
}

begin_test "owner present: the customer deploy keeps the owner and adds the customer"
owner_machine
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
system_path coexist >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run bootstrap.sh
assert_rc 0
assert_eq "$(tr -d ' \n' <"$SB/repo/machine.nix" | sed 's/^#[^{]*//')" \
  '{primaryUser="howard";homebrewUser="howard";users=["howard""v2cc"];}'
assert_out "已保留当前系统中已有的账户配置：howard"
assert_out "当前系统管理的账户、服务和命令在新配置中全部保留"
assert_called '^activate coexist$'
assert_out "部署前已有的账户、服务和命令全部保留"
assert_out "验证通过"
assert_eq "$(sed -n 's/^previous=//p' "$SB/home/.local/state/v2cc/last-deploy")" "$(system_path owner)"
end_test

begin_test "owner present: a configuration that drops the owner is refused untouched"
owner_machine
# What main built before this change: only the deploying account.
system_path fresh >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run bootstrap.sh
assert_rc 3
assert_out "账户「howard」的 Home Manager 配置将被移除"
assert_out "主用户 system.primaryUser 将从「howard」变为「v2cc」"
assert_out "已停止，系统没有任何改动"
grep -Fq "Home Manager 账户：howard" "$SB/home/.local/state/v2cc/guard-report.txt" ||
  flunk_test "guard report lacks the current accounts"
grep -Fq "activation-v2cc: (no version) added" "$SB/home/.local/state/v2cc/guard-report.txt" ||
  flunk_test "guard report lacks the closure diff"
assert_not_called '^nix-env'
assert_not_called '^activate'
assert_not_called '^sudo'
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path owner)"
end_test

begin_test "owner present: a changed owner configuration is refused unless explicitly allowed"
owner_machine
make_system changed howard "howard=gen-howard-other v2cc=gen-v2cc"
system_path changed >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 3
assert_out "账户「howard」的 Home Manager 配置将被改变"
assert_not_called '^activate'
RUN_ENV="V2CC_ASSUME_YES=1 V2CC_ALLOW_SYSTEM_CHANGES=1"
run deploy.sh
assert_rc 0
assert_called '^activate changed$'
end_test

begin_test "owner present: allowing changes still never allows dropping an account"
owner_machine
system_path fresh >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1 V2CC_ALLOW_SYSTEM_CHANGES=1"
run deploy.sh
assert_rc 3
assert_out "账户「howard」的 Home Manager 配置将被移除"
assert_not_called '^activate'
end_test

begin_test "owner present: an owner with their own packages or settings is refused, not replaced"
owner_machine
# Same account and Home Manager generation, but the running system also
# carries a package and a setting that this repository does not declare.
make_system owner howard "howard=gen-howard" owner-own-tool
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
system_path coexist >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 3
assert_out "当前系统中有 1 项内容将被移除或改变"
assert_out "owner-own-tool"
assert_not_called '^activate'
make_system owner howard "howard=gen-howard"
echo "defaults write -g AppleShowAllExtensions -bool true" >>"$(system_path owner)/activate"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 3
assert_out "当前系统的激活步骤中有 1 行将被移除或改变"
assert_not_called '^activate'
end_test

begin_test "owner present: the system switch needs a person or an explicit yes"
owner_machine
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
system_path coexist >"$SB/state/new_system"
run deploy.sh
assert_rc_nonzero
assert_out "需要人工确认"
assert_not_called '^activate'
assert_not_called '^nix-env'
end_test

begin_test "owner present: the owner redeploying later keeps the customer"
owner_machine
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
set_running_system coexist
system_path coexist >"$SB/state/new_system"
echo howard >"$SB/state/user"
echo 501 >"$SB/state/uid"
run prepare.sh
assert_rc 0
assert_eq "$(tr -d ' \n' <"$SB/repo/machine.nix" | sed 's/^#[^{]*//')" \
  '{primaryUser="howard";homebrewUser="howard";users=["howard""v2cc"];}'
end_test

begin_test "owner present: a managed account that no longer exists stops the deploy"
owner_machine
echo v2cc >"$SB/state/known_users"
run prepare.sh
assert_rc_nonzero
assert_out "账户「howard」在本机已不存在"
assert_missing "$SB/repo/machine.nix"
end_test

begin_test "owner present: an unreadable Home Manager format fails closed"
owner_machine
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
system_path coexist >"$SB/state/new_system"
sed -i '' 's/^echo Activating home-manager configuration for/echo Now activating home-manager for/' \
  "$(system_path owner)/activate"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 3
assert_out "无法从系统配置中识别 Home Manager 账户"
assert_not_called '^activate'
end_test

begin_test "failure: a boot profile left behind is repaired without losing the rollback target"
owner_machine
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
system_path coexist >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
# The running system is the new one, but the boot profile points elsewhere.
ln -sfn "$SB/store/owner" "$SB/root/nix/var/nix/profiles/system"
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 0
assert_called '^activate coexist$'
assert_eq "$(link_target "$SB/root/nix/var/nix/profiles/system")" "$(system_path coexist)"
assert_eq "$(sed -n 's/^previous=//p' "$SB/home/.local/state/v2cc/last-deploy")" "$(system_path owner)"
end_test

# ------------------------------------------------------------------ rollback

begin_test "rollback: returns to the system recorded before the last deploy"
owner_machine
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
system_path coexist >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
: >"$SB/calls.log"
RUN_ENV="V2CC_DRY_RUN=1"
run rollback.sh
assert_rc 0
assert_not_called '^activate'
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh
assert_rc 0
assert_called '^activate owner$'
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path owner)"
assert_eq "$(link_target "$SB/root/nix/var/nix/profiles/system")" "$(system_path owner)"
end_test

begin_test "rollback: nothing to roll back to after a first deploy"
run bootstrap.sh
run rollback.sh
assert_rc_nonzero
assert_out "没有可回退的系统配置"
end_test

# ----------------------------------------------------------------- preflight

begin_test "preflight: refuses a non Apple Silicon machine"
echo x86_64 >"$SB/state/arch"
run bootstrap.sh
assert_rc_nonzero
assert_out "仅支持 Apple Silicon Mac"
assert_not_called '.'
end_test

begin_test "preflight: refuses root"
echo 0 >"$SB/state/uid"
run bootstrap.sh
assert_rc_nonzero
assert_out "不要使用 sudo 或 root"
assert_not_called '.'
end_test

begin_test "preflight: refuses an account that is not an administrator"
echo "staff" >"$SB/state/groups"
run bootstrap.sh
assert_rc_nonzero
assert_out "不是管理员"
assert_not_called '.'
end_test

begin_test "preflight: refuses an old macOS and a full disk"
echo 13.6 >"$SB/state/macos"
run bootstrap.sh
assert_rc_nonzero
assert_out "需要 macOS 14 或更新版本"
echo 27.2 >"$SB/state/macos"
echo 3 >"$SB/state/free_gb"
run bootstrap.sh
assert_rc_nonzero
assert_out "磁盘可用空间不足"
assert_not_called '.'
end_test

# --------------------------------------------------------------- credentials

begin_test "credentials: a clean account passes"
run bootstrap.sh
run verify.sh --credentials
assert_rc 0
assert_out "未发现遗留的 GitHub 凭据"
end_test

begin_test "credentials: leftovers are found and never printed"
run bootstrap.sh
token="$(fake_token)"
printf ': 1700000000:0;git clone https://%s@github.com/jasontopia/v2cc-mac-setup\n' "$token" \
  >"$SB/home/.zsh_history"
printf '[remote "origin"]\n\turl = https://x-access-token:%s@github.com/jasontopia/v2cc-mac-setup\n' "$token" \
  >"$SB/repo/leftover-git-config"
mkdir -p "$SB/home/.config/gh"
printf 'github.com:\n    oauth_token: %s\n' "$token" >"$SB/home/.config/gh/hosts.yml"
: >"$SB/state/keychain_github"
RUN_ENV="GH_TOKEN=$token"
run verify.sh
assert_rc 1
assert_out "发现疑似 GitHub 凭据：$SB/home/.zsh_history（第 1 行）"
assert_out "发现疑似 GitHub 凭据：$SB/repo/leftover-git-config（第 2 行）"
assert_out "GitHub CLI 的登录信息仍保存在"
assert_out "环境变量 GH_TOKEN 中有 GitHub 凭据"
assert_out "登录钥匙串中保存了 github.com 的密码或令牌"
assert_no_out "$token"
end_test

# ------------------------------------------------------------- entry command

entry_fixture() {
  local commit="0123456789abcdef0123456789abcdef01234567"
  mkdir -p "$SB/bundle/jasontopia-v2cc-mac-setup-$commit"
  # shellcheck disable=SC2016
  printf '#!/bin/bash\necho "bootstrap ran from $(cd "$(dirname "$0")" && pwd)"\n' \
    >"$SB/bundle/jasontopia-v2cc-mac-setup-$commit/bootstrap.sh"
  chmod +x "$SB/bundle/jasontopia-v2cc-mac-setup-$commit/bootstrap.sh"
  tar -czf "$SB/state/bundle.tgz" -C "$SB/bundle" "jasontopia-v2cc-mac-setup-$commit"
  write_stub "$SB/bin/gh" <<EOF
echo "gh \$*" >>"\$SB/calls.log"
case "\$1 \$2" in
  "api repos/jasontopia/v2cc-mac-setup/commits/main") echo $commit ;;
  "auth token") echo "$(fake_token)" ;;
  *) exit 1 ;;
esac
EOF
}

begin_test "entry command: carries no personal token, verifies the bundle, then runs bootstrap"
entry_fixture
run tools/make-entry-command.sh
assert_rc 0
entry="$(printf '%s\n' "$out" | grep '/bin/bash -c ')"
assert_eq "$(printf '%s\n' "$entry" | wc -l | tr -d ' ')" 1
assert_no_out "$(fake_token)"
assert_not_called "$(fake_token)"
grep -Fq "Authorization: Bearer $(fake_token)" "$SB/state/curl_stdin" ||
  flunk_test "token was not passed to curl on stdin"
assert_out "token=STUBSHORTLIVED"
assert_out "$(/usr/bin/shasum -a 256 "$SB/state/bundle.tgz" | cut -d' ' -f1)"
out="$(env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB/home" /bin/zsh -f -c "$entry" 2>&1)"
rc=$?
assert_rc 0
assert_out "bootstrap ran from $SB/home/v2cc-mac-setup"
assert_eq "$(cat "$SB/home/v2cc-mac-setup/.v2cc-commit")" "0123456789abcdef0123456789abcdef01234567"
end_test

begin_test "entry command: the dry-run variant passes dry-run mode to bootstrap"
entry_fixture
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "bootstrap dry-run=${V2CC_DRY_RUN:-0}"\n' \
  >"$SB/bundle/jasontopia-v2cc-mac-setup-0123456789abcdef0123456789abcdef01234567/bootstrap.sh"
tar -czf "$SB/state/bundle.tgz" -C "$SB/bundle" jasontopia-v2cc-mac-setup-0123456789abcdef0123456789abcdef01234567
run tools/make-entry-command.sh --dry-run
assert_rc 0
entry="$(printf '%s\n' "$out" | grep '/bin/bash -c ')"
out="$(env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB/home" /bin/zsh -f -c "$entry" 2>&1)"
rc=$?
assert_rc 0
assert_out "bootstrap dry-run=1"
end_test

begin_test "entry command: a bundle that does not match the hash is never unpacked or run"
entry_fixture
run tools/make-entry-command.sh
entry="$(printf '%s\n' "$out" | grep '/bin/bash -c ')"
printf 'tampered' >>"$SB/state/bundle.tgz"
out="$(env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB/home" /bin/zsh -f -c "$entry" 2>&1)"
rc=$?
assert_rc_nonzero
assert_out "部署包完整性校验失败"
assert_no_out "bootstrap ran"
assert_missing "$SB/home/v2cc-mac-setup"
end_test

begin_test "entry command: an expired link fails clearly and leaves an earlier install alone"
entry_fixture
run tools/make-entry-command.sh
entry="$(printf '%s\n' "$out" | grep '/bin/bash -c ')"
mkdir -p "$SB/home/v2cc-mac-setup"
: >"$SB/home/v2cc-mac-setup/keep"
: >"$SB/state/network_down"
out="$(env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB/home" /bin/zsh -f -c "$entry" 2>&1)"
rc=$?
assert_rc_nonzero
assert_out "链接约 5 分钟后失效"
assert_exists "$SB/home/v2cc-mac-setup/keep"
end_test

printf '\n%s tests, %s failed\n' "$tests_run" "$tests_failed"
[ "$tests_failed" -eq 0 ]
