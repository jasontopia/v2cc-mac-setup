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
  "$REPO_ROOT"/*.sh "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/tools/*.sh "$REPO_ROOT"/modules/*.sh)"
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

# --------------------------------------------------------------- Claude Code

begin_test "claude: a window opened before the install is told it cannot see claude yet"
run bootstrap.sh
assert_rc 0
assert_out "新开的终端窗口能找到 claude 命令（$SB/home/.local/bin/claude）"
assert_out "这个终端窗口是在安装之前打开的，在它里面还找不到 claude 命令"
assert_out "请新开一个终端窗口（⌘N），或者在本窗口运行：exec zsh -l"
assert_no_out "现在可以运行 claude 开始使用"
end_test

begin_test "claude: a window that already has claude on PATH is told to just run it"
run bootstrap.sh
RUN_PATH="$SB/home/.local/bin:"
run bootstrap.sh
assert_rc 0
assert_out "V2CC 部署完成。现在可以运行 claude 开始使用。"
assert_no_out "在它里面还找不到 claude 命令"
end_test

begin_test "claude: installed but not on a new terminal's PATH fails verification honestly"
run bootstrap.sh
: >"$SB/home/.zprofile"
run verify.sh
assert_rc 1
assert_out "✓ Claude Code 已安装"
assert_out "✗ 新开的终端窗口找不到 claude 命令"
assert_out "验证未通过：1 项失败"
end_test

begin_test "claude: a ~/.zshrc that resets PATH after ~/.zprofile fails verification honestly"
run bootstrap.sh
echo 'export PATH=/usr/bin:/bin' >"$SB/home/.zshrc"
run verify.sh
assert_rc 1
assert_out "✗ 新开的终端窗口找不到 claude 命令"
end_test

begin_test "claude: the PATH of the shell running verify does not hide a missing ~/.zprofile line"
run bootstrap.sh
: >"$SB/home/.zprofile"
RUN_PATH="$SB/home/.local/bin:"
run verify.sh
assert_rc 1
assert_out "✗ 新开的终端窗口找不到 claude 命令"
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

# ----------------------------------------------------------------- always-on

GLOBAL_PREFS=/Library/Preferences/.GlobalPreferences
UPDATE_PREFS=/Library/Preferences/com.apple.SoftwareUpdate
AUTOLOGOUT=com.apple.autologout.AutoLogOutDelay
UPDATE_INSTALL=AutomaticallyInstallMacOSUpdates
before_file() { printf '%s' "$SB/root/var/db/v2cc/always-on-before.txt"; }

# Put a value into the fake machine's preferences, as if it had been set
# in System Settings.
set_default() {
  local dir
  dir="$SB/state/defaults/$(printf '%s' "$1" | tr '/' '_')"
  mkdir -p "$dir"
  echo "$3" >"$dir/$2"
}

# The first machine: the owner's system from before always-on, already
# extended with the customer (the PR 1 system), and the same system as this
# repository builds it now.
existing_machine() {
  owner_machine
  make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
  set_running_system coexist
  make_system coexist-on howard "howard=gen-howard v2cc=gen-v2cc"
  add_always_on coexist-on
  system_path coexist-on >"$SB/state/new_system"
  # Only the activation script differs, and the closure difference of the
  # real build is empty (see tests/closures.sh).
  : >"$SB/state/diff_closures"
}

begin_test "always-on: a blank Mac records what it had, then gets the settings and verifies them"
run bootstrap.sh
assert_rc 0
assert_out "本次切换会启用 7×24 在线设置"
assert_order '^pmset -g custom$' '^pmset -a sleep 0$'
assert_called '^pmset -a autorestart 1$'
assert_called '^pmset -a womp 1$'
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)/$(pmset_state womp)" "0/1/1"
assert_eq "$(pmset_state displaysleep)" "10"
assert_eq "$(default_state $GLOBAL_PREFS $AUTOLOGOUT)" "0"
assert_eq "$(default_state $UPDATE_PREFS $UPDATE_INSTALL)" "0"
assert_eq "$(grep -v -e '^#' -e '^recorded=' "$(before_file)" | sort | tr '\n' ' ')" \
  "autologout=absent macos-update-install=absent pmset.c.autorestart=0 pmset.c.sleep=1 pmset.c.womp=1 "
# Only the five settings are written: update checks, security data and the
# display sleep timer are never touched.
assert_eq "$(grep -Ec '^(pmset -[abcu]|defaults (write|delete)) ' "$SB/calls.log")" "5"
assert_out "✓ 系统空闲时不会自动睡眠"
assert_out "✓ 断电后恢复供电时自动开机"
assert_out "✓ 唤醒以供网络访问已开启"
assert_out "✓ 闲置后不会自动退出登录"
assert_out "✓ macOS 更新不会在无人确认时自动安装和重启"
assert_out "✓ 启用前的原值已记录"
assert_out "验证通过"
end_test

begin_test "always-on: a rerun neither records again nor writes any setting"
run bootstrap.sh
recorded="$(cat "$(before_file)")"
: >"$SB/calls.log"
run bootstrap.sh
assert_rc 0
assert_out "新配置已经是当前系统，无需切换"
assert_no_out "本次切换会启用 7×24 在线设置"
assert_not_called '^pmset -[abcu]'
assert_not_called '^defaults (write|delete)'
assert_not_called '^sudo'
assert_eq "$(cat "$(before_file)")" "$recorded"
end_test

begin_test "always-on: the first rollout on an existing machine is additive, and a dry run says what it will do"
existing_machine
RUN_ENV="V2CC_DRY_RUN=1"
run deploy.sh
assert_rc 0
assert_out "当前系统管理的账户、服务和命令在新配置中全部保留"
assert_out "软件包没有增加、减少或版本变化"
assert_out "本次切换会启用 7×24 在线设置。它们对整机生效，机主的账户同样受影响"
assert_out "macOS 更新不再自动安装和重启"
assert_out "[演练] 将把系统切换到 $(system_path coexist-on)（未执行）"
assert_not_called '^sudo'
assert_not_called '^activate'
assert_not_called '^pmset -[abcu]'
assert_missing "$(before_file)"
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)" "1/0"
RUN_ENV="V2CC_ASSUME_YES=1"
run bootstrap.sh
assert_rc 0
assert_called '^activate coexist-on$'
assert_out "部署前已有的账户、服务和命令全部保留"
assert_out "✓ 系统空闲时不会自动睡眠"
assert_out "验证通过"
assert_eq "$(sed -n 's/^previous=//p' "$SB/home/.local/state/v2cc/last-deploy")" "$(system_path coexist)"
end_test

begin_test "always-on: a system deployed before always-on is told so, not failed"
owner_machine
make_system coexist howard "howard=gen-howard v2cc=gen-v2cc"
system_path coexist >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run bootstrap.sh
assert_rc 0
assert_no_out "本次切换会启用 7×24 在线设置"
assert_out "! 当前系统配置不包含 7×24 在线设置"
assert_no_out "系统空闲时"
assert_not_called '^pmset -[abcu]'
assert_out "验证通过"
end_test

begin_test "always-on: rollback puts back exactly what the owner had, per power source"
existing_machine
printf '%s\n' 'c displaysleep 10' 'c womp 0' 'c sleep 30' 'c autorestart 0' \
  'u displaysleep 2' 'u womp 0' 'u sleep 5' 'u autorestart 1' >"$SB/state/pmset"
set_default $GLOBAL_PREFS $AUTOLOGOUT 600
set_default $UPDATE_PREFS $UPDATE_INSTALL 1
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 0
assert_eq "$(pmset_state sleep c)/$(pmset_state sleep u)/$(pmset_state womp c)/$(pmset_state autorestart c)" "0/0/1/1"
assert_eq "$(default_state $GLOBAL_PREFS $AUTOLOGOUT)/$(default_state $UPDATE_PREFS $UPDATE_INSTALL)" "0/0"
: >"$SB/calls.log"
RUN_ENV="V2CC_DRY_RUN=1"
run rollback.sh
assert_rc 0
assert_out "该配置不包含 7×24 在线设置"
assert_out "[演练] 将执行：sudo pmset -c sleep 30"
assert_out "[演练] 将执行：sudo pmset -u sleep 5"
assert_out "[演练] 将执行：sudo defaults write $UPDATE_PREFS $UPDATE_INSTALL -bool true"
assert_not_called '^sudo'
assert_not_called '^activate'
assert_eq "$(pmset_state sleep c)" "0"
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh
assert_rc 0
assert_order '^activate coexist$' '^sudo pmset -c sleep 30$'
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path coexist)"
assert_eq "$(sort "$SB/state/pmset" | tr '\n' ',')" \
  "c autorestart 0,c displaysleep 10,c sleep 30,c womp 0,u autorestart 1,u displaysleep 2,u sleep 5,u womp 0,"
assert_eq "$(default_state $GLOBAL_PREFS $AUTOLOGOUT)/$(default_state $UPDATE_PREFS $UPDATE_INSTALL)" "600/1"
assert_missing "$(before_file)"
assert_exists "$(before_file).restored"
assert_out "已恢复为启用前的值"
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh
assert_rc 0
assert_out "当前系统已经是该配置，无需回退"
assert_not_called '^sudo'
end_test

begin_test "always-on: settings that did not exist before are deleted again on rollback"
existing_machine
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh
assert_rc 0
assert_called "^sudo defaults delete $GLOBAL_PREFS $AUTOLOGOUT$"
assert_called "^sudo defaults delete $UPDATE_PREFS $UPDATE_INSTALL$"
assert_eq "$(default_state $GLOBAL_PREFS $AUTOLOGOUT)/$(default_state $UPDATE_PREFS $UPDATE_INSTALL)" "absent/absent"
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)/$(pmset_state womp)" "1/0/1"
end_test

begin_test "always-on: a first activation that fails halfway leaves no setting behind"
existing_machine
: >"$SB/state/pmset_fails_womp"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc_nonzero
assert_out "激活失败，已回退到之前的系统配置"
assert_called '^pmset -a autorestart 1$'
assert_order '^activate coexist-on$' '^activate coexist$'
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path coexist)"
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)/$(pmset_state womp)" "1/0/1"
assert_eq "$(default_state $GLOBAL_PREFS $AUTOLOGOUT)" "absent"
assert_missing "$(before_file)"
mv "$SB/state/pmset_fails_womp" "$SB/state/pmset_fails_womp.off"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 0
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)/$(pmset_state womp)" "0/1/1"
assert_eq "$(grep -c '^pmset\.c\.sleep=1$' "$(before_file)")" "1"
end_test

begin_test "always-on: a first activation that fails halfway on a blank Mac leaves no setting behind either"
: >"$SB/state/pmset_fails_womp"
run bootstrap.sh
assert_rc_nonzero
assert_out "本机此前没有系统配置可回退"
assert_called '^pmset -a sleep 0$'
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)/$(pmset_state womp)" "1/0/1"
assert_missing "$(before_file)"
assert_missing "$SB/root/run/current-system"
mv "$SB/state/pmset_fails_womp" "$SB/state/pmset_fails_womp.off"
run bootstrap.sh
assert_rc 0
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)/$(pmset_state womp)" "0/1/1"
assert_out "验证通过"
end_test

begin_test "always-on: the same system activated again and failing puts the settings back too"
run bootstrap.sh
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh --settings
: >"$SB/state/pmset_fails_womp"
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc_nonzero
assert_out "激活失败，系统配置没有变化"
assert_called '^pmset -a sleep 0$'
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)/$(pmset_state womp)" "1/0/1"
assert_missing "$(before_file)"
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path fresh)"
end_test

begin_test "always-on: a setting that cannot be put back keeps the record and says so"
existing_machine
printf 'c %s\n' 'displaysleep 10' 'womp 1' 'sleep 30' 'autorestart 0' >"$SB/state/pmset"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
: >"$SB/state/pmset_fails_sleep"
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh
assert_rc_nonzero
assert_out "已回退到：$(system_path coexist)"
assert_out "✗ 未能恢复 pmset sleep（记录值「30」）"
assert_out "记录仍保留在"
assert_exists "$(before_file)"
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)" "0/0"
mv "$SB/state/pmset_fails_sleep" "$SB/state/pmset_fails_sleep.off"
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh
assert_rc 0
assert_not_called '^activate'
assert_called '^sudo pmset -c sleep 30$'
assert_not_called '^sudo pmset -c (autorestart|womp)'
assert_eq "$(pmset_state sleep)" "30"
assert_missing "$(before_file)"
end_test

begin_test "always-on: power settings that cannot be read stop the activation before any change"
existing_machine
: >"$SB/state/pmset_unreadable"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc_nonzero
assert_out "could not read the current power settings"
assert_not_called '^pmset -[abcu]'
assert_not_called '^defaults write'
assert_missing "$(before_file)"
assert_eq "$(link_target "$SB/root/run/current-system")" "$(system_path coexist)"
end_test

begin_test "always-on: a Mac without wake for network access is not failed for it"
printf 'c %s\n' 'displaysleep 10' 'sleep 1' 'autorestart 0' >"$SB/state/pmset"
printf '%s\n' displaysleep sleep autorestart >"$SB/state/pmset_caps"
run bootstrap.sh
assert_rc 0
assert_out "this Mac has no 'womp' power setting, skipped"
assert_not_called '^pmset -a womp'
assert_out "! 本机没有「唤醒以供网络访问」这项设置，已跳过"
assert_out "验证通过"
end_test

begin_test "always-on: verify reports a setting changed afterwards, and only warns about security data"
run bootstrap.sh
printf 'c %s\n' 'displaysleep 10' 'womp 1' 'sleep 15' 'autorestart 1' >"$SB/state/pmset"
set_default $UPDATE_PREFS $UPDATE_INSTALL 1
set_default $GLOBAL_PREFS $AUTOLOGOUT 900
set_default $UPDATE_PREFS CriticalUpdateInstall 0
run verify.sh
assert_rc 1
assert_out "✗ 系统空闲时仍会自动睡眠：pmset sleep 应为 0，当前 c=15"
assert_out "✗ 闲置 900 秒后会自动退出登录"
assert_out "✗ macOS 更新仍会自动安装并重启"
assert_out "! 软件更新的 CriticalUpdateInstall 已被关闭"
assert_out "验证未通过：3 项失败"
end_test

begin_test "always-on: on a machine with no earlier system, the settings alone can be restored and enabled again"
run bootstrap.sh
run rollback.sh
assert_rc_nonzero
assert_out "./rollback.sh --settings"
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh --settings
assert_rc 0
assert_not_called '^activate'
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)/$(pmset_state womp)" "1/0/1"
assert_eq "$(default_state $GLOBAL_PREFS $AUTOLOGOUT)/$(default_state $UPDATE_PREFS $UPDATE_INSTALL)" "absent/absent"
assert_missing "$(before_file)"
assert_out "当前系统配置仍然包含 7×24 在线设置"
run verify.sh
assert_rc 1
assert_out "✗ 系统空闲时仍会自动睡眠"
assert_out "✗ 没有找到启用前的原值记录"
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh --settings
assert_rc_nonzero
assert_out "没有找到 7×24 在线设置启用前的原值记录"
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run bootstrap.sh
assert_rc 0
assert_out "本次切换会启用 7×24 在线设置"
assert_called '^activate fresh$'
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)" "0/1"
assert_exists "$(before_file)"
assert_out "验证通过"
end_test

begin_test "always-on: restoring the settings needs a person or an explicit yes"
run bootstrap.sh
: >"$SB/calls.log"
run rollback.sh --settings
assert_rc_nonzero
assert_out "需要人工确认"
assert_not_called '^sudo'
assert_eq "$(pmset_state sleep)" "0"
end_test

begin_test "always-on: rolling back to a system that also has the settings leaves them alone"
existing_machine
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
make_system coexist-next howard "howard=gen-howard v2cc=gen-v2cc" extra-tool
add_always_on coexist-next
system_path coexist-next >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 0
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh
assert_rc 0
assert_called '^activate coexist-on$'
assert_no_out "该配置不包含 7×24 在线设置"
assert_not_called '^sudo pmset'
assert_not_called '^sudo defaults'
assert_exists "$(before_file)"
assert_eq "$(pmset_state sleep)/$(pmset_state autorestart)" "0/1"
end_test

begin_test "always-on: changing a value later is refused unless explicitly allowed"
existing_machine
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
make_system coexist-changed howard "howard=gen-howard v2cc=gen-v2cc"
add_always_on coexist-changed
sed -i '' 's/^v2cc_pmset sleep 0$/v2cc_pmset sleep 5/' "$(system_path coexist-changed)/activate"
system_path coexist-changed >"$SB/state/new_system"
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 3
assert_out "当前系统的激活步骤中有 1 行将被移除或改变"
assert_not_called '^activate'
# Taking the settings out again by redeploying is refused the same way.
system_path coexist >"$SB/state/new_system"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
assert_rc 3
assert_not_called '^activate'
end_test

# ---------------------------------------------------------------- auto-login

LOGIN_PREFS=/Library/Preferences/com.apple.loginwindow
marker_file() { printf '%s' "$SB/root/var/db/v2cc/auto-login"; }
kcpassword_file() { printf '%s' "$SB/root/etc/kcpassword"; }
lock_agent_file() { printf '%s' "$SB/home/Library/LaunchAgents/com.v2cc.lock-after-login.plist"; }
# Assembled at run time, like fake_token, and unlike anything else in here.
fake_password() { printf 'Pw%s-%s' "$(printf 'x%.0s' 1 2 3 4 5 6)" "only-for-this-test"; }

# A deployed machine in the customer account whose owner has turned
# FileVault off.
auto_login_machine() {
  run bootstrap.sh
  echo "FileVault is Off." >"$SB/state/filevault"
  : >"$SB/calls.log"
}

# Answer the typed confirmation and the system tool's password prompt.
enable_auto_login() {
  TTY_DIALOG=" > =v2cc|Enter password=$(fake_password)"
  run_tty auto-login.sh enable "$@"
}

begin_test "auto-login: refuses while FileVault is on, and never turns it off"
run bootstrap.sh
: >"$SB/calls.log"
run auto-login.sh enable
assert_rc_nonzero
assert_out "FileVault 没有关闭"
assert_out "本脚本不会关闭 FileVault"
assert_not_called '^fdesetup [^s]'
assert_not_called '^sudo'
assert_not_called 'sysadminctl -autologin (set|off)'
echo "Decryption in progress: Percent completed = 40" >"$SB/state/filevault"
run auto-login.sh enable
assert_rc_nonzero
assert_out "FileVault 没有关闭（Decryption in progress"
assert_not_called 'sysadminctl -autologin (set|off)'
end_test

begin_test "auto-login: refuses the owner's account"
existing_machine
set_running_system coexist-on
echo "FileVault is Off." >"$SB/state/filevault"
echo howard >"$SB/state/user"
echo 501 >"$SB/state/uid"
run auto-login.sh enable
assert_rc_nonzero
assert_out "账户 howard 是本机的主用户（机主账户）"
assert_not_called '^sudo'
assert_not_called 'sysadminctl -autologin (set|off)'
end_test

begin_test "auto-login: refuses an account the system does not manage"
owner_machine
echo "FileVault is Off." >"$SB/state/filevault"
run auto-login.sh enable
assert_rc_nonzero
assert_out "账户 v2cc 不在本机系统配置管理的账户中"
assert_not_called '^sudo'
end_test

begin_test "auto-login: refuses when the always-on settings are not in effect"
existing_machine
echo "FileVault is Off." >"$SB/state/filevault"
run auto-login.sh enable
assert_rc_nonzero
assert_out "7×24 在线设置没有生效"
RUN_ENV="V2CC_ASSUME_YES=1"
run deploy.sh
printf 'c %s\n' 'displaysleep 10' 'womp 1' 'sleep 0' 'autorestart 0' >"$SB/state/pmset"
: >"$SB/calls.log"
run auto-login.sh enable
assert_rc_nonzero
assert_out "7×24 在线设置没有生效"
assert_not_called '^sudo'
end_test

begin_test "auto-login: does not replace another account's automatic login"
auto_login_machine
set_default $LOGIN_PREFS autoLoginUser howard
run auto-login.sh enable
assert_rc_nonzero
assert_out "本机已经为账户「howard」开启了自动登录"
assert_not_called '^sudo'
end_test

begin_test "auto-login: V2CC_ASSUME_YES cannot stand in for the typed confirmation"
auto_login_machine
RUN_ENV="V2CC_ASSUME_YES=1"
run auto-login.sh enable
assert_rc_nonzero
assert_out "逐条确认你清楚这些后果"
assert_out "V2CC_ASSUME_YES 不能跳过这一步"
assert_not_called '^sudo'
assert_not_called 'sysadminctl -autologin (set|off)'
assert_missing "$(marker_file)"
end_test

begin_test "auto-login: anything but the account name at the confirmation cancels"
auto_login_machine
RUN_ENV="V2CC_ASSUME_YES=1"
TTY_DIALOG=" > =y"
run_tty auto-login.sh enable
assert_rc_nonzero
assert_out "已取消，系统没有任何改动"
assert_not_called '^sudo'
assert_missing "$(kcpassword_file)"
end_test

begin_test "auto-login: the password goes only to the system tool's own prompt and is found nowhere afterwards"
auto_login_machine
enable_auto_login
assert_rc 0
assert_called '^sudo sysadminctl -autologin set -userName v2cc -password -$'
assert_order '^sudo -v$' '^sudo sysadminctl -autologin set'
assert_out "只有 root 能读，但只是混淆，不是加密"
assert_out "尚未在真机验证"
assert_out "自动登录账户：v2cc"
assert_no_out "$(fake_password)"
if grep -rqF -- "$(fake_password)" "$SB"; then
  flunk_test "the password was left in: $(grep -rlF -- "$(fake_password)" "$SB" | tr '\n' ' ')"
fi
assert_exists "$(kcpassword_file)"
assert_eq "$(sed -n 's/^user=//p' "$(marker_file)")" "v2cc"
assert_missing "$(lock_agent_file)"
run verify.sh
assert_rc 0
assert_out "✓ 重启后自动登录账户 v2cc"
assert_out "登录后不会自动锁屏"
assert_out "尚未在真机验证"
end_test

begin_test "auto-login: status is read-only"
auto_login_machine
enable_auto_login
: >"$SB/calls.log"
run auto-login.sh status
assert_rc 0
assert_out "系统设置的自动登录账户：v2cc"
assert_out "由本脚本设置：账户 v2cc"
assert_not_called '^sudo'
assert_not_called 'sysadminctl -autologin (set|off)'
end_test

begin_test "auto-login: a dry run asks nothing and changes nothing"
auto_login_machine
run auto-login.sh enable --lock-after-login --dry-run
assert_rc 0
assert_out "[演练] 将执行：sudo sysadminctl -autologin set -userName v2cc -password -"
assert_out "演练结束，系统没有任何改动"
assert_not_called '^sudo'
assert_missing "$(kcpassword_file)"
assert_missing "$(marker_file)"
assert_missing "$(lock_agent_file)"
end_test

begin_test "auto-login: a result that does not read back is undone, not trusted"
auto_login_machine
: >"$SB/state/autologin_set_incomplete"
enable_auto_login
assert_rc_nonzero
assert_out "读回检查未通过"
assert_out "已撤销，自动登录保持关闭"
assert_called '^sudo sysadminctl -autologin off$'
assert_missing "$(kcpassword_file)"
assert_missing "$(marker_file)"
mv "$SB/state/autologin_set_incomplete" "$SB/state/autologin_set_incomplete.off"
echo "root:644" >"$SB/state/kcpassword_mode"
enable_auto_login
assert_rc_nonzero
assert_out "root:644"
assert_out "应为 root:600"
assert_missing "$(kcpassword_file)"
assert_eq "$(default_state $LOGIN_PREFS autoLoginUser)" "absent"
assert_missing "$(marker_file)"
end_test

begin_test "auto-login: the system tool refusing leaves automatic login off"
auto_login_machine
: >"$SB/state/autologin_set_fails"
enable_auto_login
assert_rc_nonzero
assert_out "系统工具没有完成自动登录的设置，已撤销"
assert_missing "$(kcpassword_file)"
assert_missing "$(marker_file)"
end_test

begin_test "auto-login: lock after login is a login item, added and removed by enable"
auto_login_machine
echo "5 seconds" >"$SB/state/screenlock"
run auto-login.sh enable --lock-after-login
assert_rc_nonzero
assert_out "「登录后立即锁屏」依赖系统在显示器关闭后立即要求密码"
assert_not_called '^sudo'
echo immediate >"$SB/state/screenlock"
enable_auto_login --lock-after-login
assert_rc 0
assert_out "你选择了「登录后立即锁屏」"
grep -q '<string>displaysleepnow</string>' "$(lock_agent_file)" 2>/dev/null ||
  flunk_test "the login item does not turn the display off"
/usr/bin/plutil -lint "$(lock_agent_file)" >/dev/null 2>&1 ||
  flunk_test "the login item is not a valid property list"
assert_eq "$(sed -n 's/^lock_agent=//p' "$(marker_file)")" "$(lock_agent_file)"
# Installed for the next login only: nothing is loaded or run now.
assert_not_called '^launchctl (bootstrap|load|kickstart)'
assert_not_called '^pmset displaysleepnow'
run verify.sh
assert_rc 0
assert_out "登录后立即关闭显示器并锁屏的登录项已安装（是否生效、锁屏后 UU远程 能否连接，尚未在真机验证）"
enable_auto_login
assert_rc 0
assert_out "已去掉登录后立即锁屏的登录项"
assert_missing "$(lock_agent_file)"
assert_eq "$(grep -c '^lock_agent=' "$(marker_file)")" "0"
end_test

begin_test "auto-login: verify fails when the lock login item has gone missing"
auto_login_machine
enable_auto_login --lock-after-login
mv "$(lock_agent_file)" "$(lock_agent_file).moved-away"
run verify.sh
assert_rc 1
assert_out "✗ 本机登记为登录后立即锁屏，但登录项文件不存在"
end_test

begin_test "auto-login: disable removes the stored password, the login item and the marker"
auto_login_machine
enable_auto_login --lock-after-login
: >"$SB/calls.log"
run auto-login.sh disable
assert_rc_nonzero
assert_out "需要人工确认"
assert_exists "$(kcpassword_file)"
RUN_ENV="V2CC_ASSUME_YES=1"
run auto-login.sh disable
assert_rc 0
assert_called '^sudo sysadminctl -autologin off$'
assert_missing "$(kcpassword_file)"
assert_missing "$(marker_file)"
assert_missing "$(lock_agent_file)"
assert_eq "$(default_state $LOGIN_PREFS autoLoginUser)" "absent"
assert_out "修改这个账户的登录密码"
assert_out "重新开启 FileVault"
run auto-login.sh disable
assert_rc 0
assert_out "本机没有开启自动登录，无需处理"
end_test

begin_test "auto-login: the owner can check it and turn it off from their own account"
auto_login_machine
enable_auto_login --lock-after-login
echo howard >"$SB/state/user"
echo 501 >"$SB/state/uid"
run verify.sh
assert_out "✓ 重启后自动登录账户 v2cc"
assert_out "登录后立即锁屏的登录项在账户 v2cc 的目录里，从当前账户无法检查"
assert_no_out "登录项文件不存在"
: >"$SB/calls.log"
RUN_ENV="V2CC_ASSUME_YES=1"
run auto-login.sh disable
assert_rc 0
assert_called '^sudo sysadminctl -autologin off$'
assert_called "^sudo rm -f $(lock_agent_file)$"
assert_missing "$(kcpassword_file)"
assert_missing "$(lock_agent_file)"
assert_missing "$(marker_file)"
end_test

begin_test "auto-login: disable deletes a credential file the system tool left behind"
auto_login_machine
enable_auto_login
: >"$SB/state/kcpassword_sticks"
RUN_ENV="V2CC_ASSUME_YES=1"
run auto-login.sh disable
assert_rc 0
assert_out "仍然存在，已直接删除"
assert_missing "$(kcpassword_file)"
assert_missing "$(marker_file)"
end_test

begin_test "auto-login: verify fails when the machine no longer matches what was set up"
auto_login_machine
enable_auto_login
echo "FileVault is On." >"$SB/state/filevault"
run verify.sh
assert_rc 1
assert_out "✗ 本机登记为自动登录账户 v2cc，但 FileVault 没有关闭"
echo "FileVault is Off." >"$SB/state/filevault"
set_default $LOGIN_PREFS autoLoginUser howard
run verify.sh
assert_rc 1
assert_out "✗ 本机登记为自动登录账户 v2cc，但系统当前的自动登录账户是「howard」"
set_default $LOGIN_PREFS autoLoginUser v2cc
mv "$(kcpassword_file)" "$(kcpassword_file).moved-away"
run verify.sh
assert_rc 1
assert_out "✗ 本机登记为自动登录账户 v2cc，但保存的登录凭据"
end_test

begin_test "auto-login: verify warns about automatic login that this script did not set up"
auto_login_machine
set_default $LOGIN_PREFS autoLoginUser v2cc
run verify.sh
assert_rc 0
assert_out "! 系统已开启自动登录（账户 v2cc），但不是通过 ./auto-login.sh 设置的"
end_test

begin_test "auto-login: restoring the power settings warns that automatic login is still on"
auto_login_machine
enable_auto_login
RUN_ENV="V2CC_ASSUME_YES=1"
run rollback.sh --settings
assert_rc 0
assert_out "本机开启了自动登录，但断电后自动开机等设置已恢复原值"
end_test

printf '\n%s tests, %s failed\n' "$tests_run" "$tests_failed"
[ "$tests_failed" -eq 0 ]
