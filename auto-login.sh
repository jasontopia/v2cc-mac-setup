#!/bin/bash
#
# Automatic login for the customer account, so that a Mac that restarts
# comes back to a logged-in session without anyone at the keyboard. A
# remote-desktop tool such as UU远程 runs inside that session.
#
#   ./auto-login.sh status                     what is set on this Mac (read-only)
#   ./auto-login.sh enable                     turn it on for the account running this
#   ./auto-login.sh enable --lock-after-login  ... and lock the screen right after each login
#   ./auto-login.sh disable                    remove the stored password and turn it off
#
# What this script will not do:
#
#   - It never turns FileVault off. Automatic login needs FileVault off,
#     and that lowers the protection of every account on the Mac, so it
#     stays an act of the machine owner in System Settings.
#   - It never sees the password. macOS's own tool (sysadminctl) asks for
#     it on the terminal and stores it. The password is never an argument,
#     an environment variable, a file of ours, or a line of shell history.
#   - It does not set up UU远程. Signing in, allowing control and granting
#     its permissions are done by a person, and whether UU远程 can connect
#     to a locked screen or a login window has not been verified on a real
#     machine. See docs/test-plan.md, section C, 阶段 2.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh
# shellcheck source=lib/always-on.sh
. ./lib/always-on.sh

usage="用法：./auto-login.sh status | enable [--lock-after-login] | disable（可加 --dry-run）"

action=""
lock_after_login=0
for arg in "$@"; do
  case "$arg" in
    status | enable | disable)
      [ -z "$action" ] || die "$usage"
      action="$arg"
      ;;
    --lock-after-login) lock_after_login=1 ;;
    --dry-run) V2CC_DRY_RUN=1 ;;
    *) die "未知参数：${arg}。$usage" ;;
  esac
done
[ -n "$action" ] || die "$usage"
[ "$lock_after_login" = "0" ] || [ "$action" = "enable" ] ||
  die "--lock-after-login 只能和 enable 一起使用。"

me="$(id -un)"
[ "$(id -u)" -ne 0 ] || die "请用要自动登录的账户直接运行，不要使用 sudo 或 root。"
valid_username "$me" || die "账户名「${me}」含有不支持的字符。"

current_system="$(resolve_link "$CURRENT_SYSTEM_LINK")"
lock_agent="$HOME/Library/LaunchAgents/$LOCK_AGENT_LABEL.plist"

show_status() {
  local login_user marker_user marker_agent
  login_user="$(auto_login_user)"
  marker_user="$(auto_login_marker user)"
  marker_agent="$(auto_login_marker lock_agent)"

  info "本机的自动登录状态"
  note "FileVault：$(filevault_status)"
  note "系统工具的回答：$(sysadminctl_message -autologin status)"
  note "系统设置的自动登录账户：${login_user:-无}"
  if [ -e "$KCPASSWORD" ]; then
    note "保存的登录凭据 ${KCPASSWORD}：存在（$(stat -f '%Su:%Lp' "$KCPASSWORD" 2>/dev/null)）"
  else
    note "保存的登录凭据 ${KCPASSWORD}：不存在"
  fi
  if [ -n "$marker_user" ]; then
    note "由本脚本设置：账户 ${marker_user}，时间 $(auto_login_marker enabled)"
  else
    note "由本脚本设置：否"
  fi
  if [ -n "$marker_agent" ] && [ "$marker_user" != "$me" ]; then
    # Another account's ~/Library cannot be looked into from here.
    note "登录后立即锁屏：已登记（${marker_agent}），在账户 ${marker_user} 的目录里，从当前账户无法检查"
  elif [ -e "$lock_agent" ]; then
    note "登录后立即锁屏：登录项已安装（${lock_agent}）"
  elif [ -n "$marker_agent" ]; then
    note "登录后立即锁屏：已登记，但登录项文件不存在（${marker_agent}）"
  else
    note "登录后立即锁屏：未安装"
  fi
  note "屏幕锁定的密码要求：$(sysadminctl_message -screenLock status)"
}

# The checks that decide whether enabling is allowed. All read-only.
check_preconditions() {
  local primary managed login_user

  info "检查开启条件（只读）..."

  [ -n "$current_system" ] ||
    die "本机还没有部署 V2CC 系统配置。请先运行 ./bootstrap.sh。"
  managed="$(sys_hm_users "$current_system")"
  printf '%s\n' "$managed" | grep -Fxq -- "$me" ||
    die "账户 ${me} 不在本机系统配置管理的账户中。请在客户账户里运行本脚本。"

  # The owner's account must never be the one that logs in by itself. On a
  # machine where the owner deployed first, the owner is the primary user.
  # On a machine deployed from scratch in the customer account, that
  # account is the only managed one and is the primary user itself.
  primary="$(sys_primary_user "$current_system")"
  if [ "$primary" = "$me" ] && [ "$managed" != "$me" ]; then
    die "账户 ${me} 是本机的主用户（机主账户）。自动登录只用于客户账户，不用于机主账户。"
  fi
  ok "目标账户 ${me} 是受管理的客户账户，不是机主账户"

  filevault_is_off ||
    die "FileVault 没有关闭（$(filevault_status)）。FileVault 开启时 macOS 不允许自动登录。本脚本不会关闭 FileVault：需要机主在知情同意后，自己在「系统设置 > 隐私与安全性 > FileVault」里关闭，完成后再运行本脚本。"
  ok "FileVault 已关闭"

  always_on_in_effect "$current_system" ||
    die "7×24 在线设置没有生效（系统空闲不睡眠、断电恢复后自动开机）。没有它们，断电后机器不会自己开机，自动登录也就没有意义。请先运行 ./bootstrap.sh 并让 ./verify.sh 通过。"
  ok "7×24 在线设置已生效"

  login_user="$(auto_login_user)"
  if [ -n "$login_user" ] && [ "$login_user" != "$me" ]; then
    die "本机已经为账户「${login_user}」开启了自动登录。一台机器只能有一个自动登录账户，本脚本不会替换它。"
  fi

  if [ "$lock_after_login" = "1" ]; then
    case "$(sysadminctl_message -screenLock status)" in
      *immediate*) ok "屏幕锁定后立即要求密码" ;;
      *) die "「登录后立即锁屏」依赖系统在显示器关闭后立即要求密码，但本机当前不是这样设置的。请先在「系统设置 > 锁定屏幕」里把「屏幕保护程序启动或显示器关闭后需要密码」设为「立即」。" ;;
    esac
  fi
}

show_tradeoff() {
  cat <<EOF

开启之前，请逐条确认你清楚这些后果：

  1. 本机的 FileVault 已关闭。开机时磁盘自动解锁，不需要任何密码。这对本机
     所有账户都一样，包括机主的账户。
  2. 开启后，本机每次开机都会直接进入账户「${me}」的桌面。任何能接触到这台
     机器的人（家人、访客、维修人员、窃贼）打开它，就能使用这个账户：里面的
     文件、钥匙串里保存的密码、已登录的网站、Claude Code 和 Git 的登录信息。
  3. 「${me}」的登录密码会以可以还原的形式保存在本机磁盘上
     （/etc/kcpassword，只有 root 能读，但只是混淆，不是加密）。能在本机取得
     root 权限的人可以读出这个密码。这个密码不要在任何别的地方使用。
  4. 以后修改「${me}」的密码后，要重新运行 ./auto-login.sh enable。否则下次
     重启可能停在登录窗口（macOS 是否会自己更新已保存的密码，尚未在真机验证）。
  5. 开启前必须已经取得机主对这台机器的明确同意。脚本无法替你确认这一点。

尚未在真机验证：自动登录之后，以及锁屏或登录窗口状态下，UU远程 能否无人值守
连接。开启自动登录不等于远程连接已经可用，要按 docs/test-plan.md C 节阶段 2 逐项验证。
EOF
  if [ "$lock_after_login" = "1" ]; then
    cat <<EOF

你选择了「登录后立即锁屏」：账户「${me}」每次登录（包括手动登录）后，显示器会
立即关闭并锁定，会话保持登录。尚未在真机验证：这个登录项在 macOS 27 上能否
生效，以及锁屏后 UU远程 能否输入密码解锁。验证不通过时，重新运行
./auto-login.sh enable（不带 --lock-after-login）可以去掉它。
EOF
  fi
  printf '\n'
}

# Deliberately not confirm(): V2CC_ASSUME_YES must not answer this one, and
# a yes typed by reflex must not either.
confirm_by_typing_account() {
  local answer
  [ -t 0 ] ||
    die "开启自动登录必须由人在终端里确认，当前不是交互终端。V2CC_ASSUME_YES 不能跳过这一步。"
  read -r -p "确认开启，请输入账户名 ${me} 后回车；输入其他任何内容都会取消 > " answer
  [ "$answer" = "$me" ] || die "输入的不是「${me}」，已取消，系统没有任何改动。"
}

# Automatic login as it works for this account right now: the identity of
# the stored credential (inode, size, modification time), or nothing when
# automatic login is not fully set up. Only the file's metadata is read,
# never its contents. Comparing two answers tells whether anything touched
# the working setup in between.
working_auto_login() {
  [ "$(auto_login_user)" = "$me" ] || return 0
  [ "$(stat -f '%Su:%Lp' "$KCPASSWORD" 2>/dev/null || true)" = "root:600" ] || return 0
  stat -f '%i:%z:%Fm' "$KCPASSWORD" 2>/dev/null || true
}

# Take the stored password away again. Used by disable and when enabling
# did not end in the state it should have. False when anything is left.
revoke_credential() {
  sudo sysadminctl -autologin off >/dev/null 2>&1 ||
    warn "sysadminctl -autologin off 没有成功，改为直接清除。"
  if [ -e "$KCPASSWORD" ]; then
    if sudo rm -f "$KCPASSWORD"; then
      warn "系统工具关闭自动登录后，保存的登录凭据 ${KCPASSWORD} 仍然存在，已直接删除。"
    else
      warn "系统工具关闭自动登录后，保存的登录凭据 ${KCPASSWORD} 仍然存在，直接删除也没有成功。"
    fi
  fi
  if [ -n "$(auto_login_user)" ]; then
    if sudo defaults delete "$LOGINWINDOW_PREFS" autoLoginUser >/dev/null 2>&1; then
      warn "系统工具关闭自动登录后，自动登录账户的设置仍然存在，已直接删除。"
    else
      warn "系统工具关闭自动登录后，自动登录账户的设置仍然存在，直接删除也没有成功。"
    fi
  fi
  [ ! -e "$KCPASSWORD" ] && [ -z "$(auto_login_user)" ]
}

# Enabling did not end in the state it should have, and what is on the Mac
# now cannot be trusted: take the stored password away and end by saying
# which state that leaves the Mac in. $1 is not empty when automatic login
# was working before this run, so that turning it off is never silent.
revoke_failed_enable() {
  if ! revoke_credential; then
    die "撤销没有成功：自动登录的设置或保存的登录凭据可能还留在本机上，当前状态不确定。请运行 ./auto-login.sh status 查看，再运行 ./auto-login.sh disable 关闭。请保留以上输出并联系 V2CC 运营方。"
  fi
  if [ -n "$1" ]; then
    die "已撤销。本机此前已经开启的自动登录也因此关闭了：现在自动登录是关闭的，下次重启会停在登录窗口，要有人在机器旁登录。需要恢复时重新运行 ./auto-login.sh enable。请保留以上输出。"
  fi
  die "已撤销，自动登录保持关闭。请保留以上输出。"
}

install_lock_agent() {
  mkdir -p "$(dirname "$lock_agent")"
  cat >"$lock_agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LOCK_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/pmset</string>
    <string>displaysleepnow</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
EOF
}

write_marker() {
  sudo mkdir -p "$V2CC_DB_DIR"
  {
    printf 'user=%s\n' "$me"
    printf 'enabled=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [ "$lock_after_login" = "1" ]; then
      printf 'lock_agent=%s\n' "$lock_agent"
    fi
  } | sudo tee "$AUTO_LOGIN_MARKER" >/dev/null
  # verify.sh and `status` read the marker without root, from any account,
  # whatever the umask of the account that ran this.
  sudo chmod 755 "$V2CC_DB_DIR"
  sudo chmod 644 "$AUTO_LOGIN_MARKER"
}

enable() {
  local kc_mode was_working

  check_preconditions
  show_tradeoff

  if is_dry_run; then
    run_mut sudo sysadminctl -autologin set -userName "$me" -password -
    if [ "$lock_after_login" = "1" ]; then
      printf '  [演练] 将安装登录项：%s\n' "$lock_agent"
    fi
    printf '  [演练] 将写入标记：%s\n' "$AUTO_LOGIN_MARKER"
    info "演练结束，系统没有任何改动。"
    return 0
  fi

  confirm_by_typing_account
  ensure_sudo "设置自动登录"

  # This may be a rerun on a Mac where automatic login already works: after
  # a password change, or to add or drop the lock after login. A failed
  # attempt must not quietly take the working setup away, least of all on a
  # Mac that is only reachable remotely.
  was_working="$(working_auto_login)"

  info "接下来由 macOS 自带的 sysadminctl 询问账户 ${me} 的登录密码。密码只交给这个系统工具，本脚本不读取、不保存。"
  if ! sudo sysadminctl -autologin set -userName "$me" -password -; then
    fail "系统工具没有完成自动登录的设置。"
    if [ -n "$was_working" ] && [ "$(working_auto_login)" = "$was_working" ]; then
      die "这次的设置没有生效。本机此前已经开启的自动登录原样保留，没有被改动：自动登录账户仍是 ${me}，系统保存的仍是此前那份登录凭据。如果这次是因为改了密码才重新运行，保存的还是旧密码，下次重启可能停在登录窗口，请再次运行 ./auto-login.sh enable。不再需要自动登录时运行 ./auto-login.sh disable。请保留以上输出。"
    fi
    revoke_failed_enable "$was_working"
  fi

  # Believe the machine, not the tool's exit status.
  kc_mode="$(stat -f '%Su:%Lp' "$KCPASSWORD" 2>/dev/null || true)"
  if [ "$(auto_login_user)" != "$me" ] || [ "$kc_mode" != "root:600" ]; then
    fail "读回检查未通过：自动登录账户是「$(auto_login_user)」（应为 ${me}），登录凭据 ${KCPASSWORD} 的属主和权限是「${kc_mode:-不存在}」（应为 root:600）。请联系 V2CC 运营方。"
    revoke_failed_enable "$was_working"
  fi
  ok "自动登录账户：$me"
  ok "登录凭据由系统保存在 ${KCPASSWORD}（root:600）"
  note "系统工具的回答：$(sysadminctl_message -autologin status)"

  if [ "$lock_after_login" = "1" ]; then
    install_lock_agent
    ok "已安装登录后立即锁屏的登录项（下次登录起生效）：$lock_agent"
  elif [ -e "$lock_agent" ]; then
    rm -f "$lock_agent"
    ok "已去掉登录后立即锁屏的登录项。"
  fi
  write_marker

  info "自动登录已开启：下次开机起，本机会直接进入账户 ${me}。"
  cat <<EOF
还需要人工完成、脚本做不了的事（在账户 ${me} 的桌面里）：
  - UU远程：登录账号，打开「允许本设备被控」「开机自动启动」「防止电脑休眠」，
    在系统设置里授予「辅助功能」和「录屏与系统录音」，然后重启 UU远程 客户端；
    确认「系统设置 > 通用 > 登录项与扩展」里 UU远程 是开启的。
  - 按 docs/test-plan.md C 节阶段 2 重启验证。在验证通过之前，不要认为这台机器
    重启后能自己恢复远程连接。
关闭自动登录：./auto-login.sh disable
EOF
}

disable() {
  local marker_agent

  # The login item is where the marker says: possibly in the home of
  # another account than the one turning this off.
  marker_agent="$(auto_login_marker lock_agent)"
  [ -n "$marker_agent" ] || marker_agent="$lock_agent"

  if [ -z "$(auto_login_user)" ] && [ ! -e "$KCPASSWORD" ] &&
    [ ! -e "$AUTO_LOGIN_MARKER" ] && [ ! -e "$lock_agent" ]; then
    ok "本机没有开启自动登录，无需处理。"
    return 0
  fi

  if is_dry_run; then
    run_mut sudo sysadminctl -autologin off
    printf '  [演练] 将确认登录凭据 %s 已删除，并删除登录项 %s 和标记 %s\n' \
      "$KCPASSWORD" "$marker_agent" "$AUTO_LOGIN_MARKER"
    info "演练结束，系统没有任何改动。"
    return 0
  fi

  confirm "将关闭本机的自动登录并删除保存的登录凭据。此后每次重启都会停在登录窗口，要有人在机器旁登录。继续？" ||
    die "已取消，系统没有任何改动。"
  ensure_sudo "关闭自动登录"

  revoke_credential ||
    die "未能清除自动登录的设置或保存的登录凭据。请保留以上输出并联系 V2CC 运营方。"
  ok "自动登录已关闭，保存的登录凭据已删除"

  # With root: another account's ~/Library cannot even be looked into.
  if sudo test -e "$marker_agent"; then
    sudo rm -f "$marker_agent"
    ok "已删除登录后立即锁屏的登录项：$marker_agent"
  fi
  sudo rm -f "$AUTO_LOGIN_MARKER"

  cat <<EOF
接下来请人工完成：
  - 修改这个账户的登录密码。它曾以可还原的形式保存在磁盘上，应视为已经泄露。
  - 由机主在「系统设置 > 隐私与安全性 > FileVault」里重新开启 FileVault，并保存
    新的恢复密钥。开启后每次重启都需要有人在机器旁输入密码。
EOF
}

case "$action" in
  status) show_status ;;
  enable) enable ;;
  disable) disable ;;
esac
