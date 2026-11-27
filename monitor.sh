#!/bin/bash
#
# The V2CC machine monitor: install it, look at it, configure where its
# records go, remove it. bootstrap.sh runs `install` as one of its steps, so
# a new machine has it after the one setup run.
#
#   ./monitor.sh status                        what is installed and when it last ran (read-only, any account)
#   ./monitor.sh install [--machine-id <id>]   install or update it, and start it
#   ./monitor.sh configure <options>           where records and fingerprints go, see below
#   ./monitor.sh uninstall [--delete-records]  stop and remove it; records stay unless asked
#
#   configure options (a value of "none" removes the setting):
#     --upload-endpoint https://<host>   S3-compatible store, e.g. https://<account>.r2.cloudflarestorage.com
#     --upload-bucket <name>             bucket for the records
#     --upload-region <name>             region name for the signature (default auto)
#     --upload-credential                ask for the access key ID and secret on the terminal
#     --ots-url https://...              OpenTimestamps calendar
#     --tsa-url https://...              RFC 3161 timestamp service
#     --check-apps /Applications/A.app:/Applications/B.app
#                                        apps whose signature is checked every round
#     --detail-addresses on|off          beyond the website's sentence: needs the owner's decision
#     --detail-fingerprint on|off        beyond the website's sentence: needs the owner's decision
#
# install, configure and uninstall need administrator rights: run them in the
# platform maintenance administrator account. They refuse the customer
# account. What the monitor records: docs/monitoring.md.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib/common.sh
. ./lib/common.sh
# shellcheck source=lib/system-guard.sh
. ./lib/system-guard.sh
# shellcheck source=lib/monitor.sh
. ./lib/monitor.sh

usage="用法：./monitor.sh status | install [--machine-id <编号>] | configure <选项> | uninstall [--delete-records]（可加 --dry-run）"

action="${1:-}"
[ $# -eq 0 ] || shift
machine_id=""
delete_records=0
settings=()
ask_credential=0

add_setting() { settings[${#settings[@]}]="$1=$2"; }
on_off() {
  case "$1" in
    on) printf 1 ;;
    off) printf 0 ;;
    *) die "$2 只能是 on 或 off。" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) V2CC_DRY_RUN=1 ;;
    --machine-id)
      [ $# -ge 2 ] || die "--machine-id 需要一个编号。$usage"
      machine_id="$2"
      shift
      ;;
    --delete-records) delete_records=1 ;;
    --upload-endpoint | --upload-bucket | --upload-region | --ots-url | --tsa-url | --check-apps)
      [ $# -ge 2 ] || die "$1 需要一个值。"
      case "$1" in
        --upload-endpoint) add_setting UPLOAD_ENDPOINT "$2" ;;
        --upload-bucket) add_setting UPLOAD_BUCKET "$2" ;;
        --upload-region) add_setting UPLOAD_REGION "$2" ;;
        --ots-url) add_setting OTS_URL "$2" ;;
        --tsa-url) add_setting TSA_URL "$2" ;;
        --check-apps) add_setting CHECK_APPS "$2" ;;
      esac
      shift
      ;;
    --detail-addresses | --detail-fingerprint)
      [ $# -ge 2 ] || die "$1 需要 on 或 off。"
      if [ "$1" = --detail-addresses ]; then
        add_setting DETAIL_ADDRESSES "$(on_off "$2" "$1")"
      else
        add_setting DETAIL_FINGERPRINT "$(on_off "$2" "$1")"
      fi
      shift
      ;;
    --upload-credential) ask_credential=1 ;;
    *) die "未知参数：${1}。$usage" ;;
  esac
  shift
done

me="$(id -un)"
current_system="$(resolve_link "$CURRENT_SYSTEM_LINK")"
customer="$(sys_customer_user "$current_system")"

# Only the platform maintenance administrator changes the monitor: never
# root directly, never the customer's standard account.
require_operator() {
  [ "$(id -u)" -ne 0 ] || die "请直接运行，不要使用 sudo 或 root。"
  if [ -n "$customer" ] && [ "$me" = "$customer" ]; then
    die "监测程序不能在客户账户 ${customer} 里${1}。请在平台维护管理员账户里运行。"
  fi
  require_admin "$1监测程序"
}

show_status() {
  local last age upload ok_at err
  info "监测程序"
  if ! mon_installed; then
    note "未安装（$MON_PLIST 不存在）。安装：./monitor.sh install，或重新运行 ./bootstrap.sh。"
    return 0
  fi
  note "已安装：$MON_PROG"
  if mon_loaded; then note "launchd 服务 ${MON_LABEL}：已加载（每 5 分钟运行一次，以 root 运行）"; else note "launchd 服务 ${MON_LABEL}：未加载"; fi
  note "机器编号：$(mon_status machine)"
  last="$(mon_status last_run_epoch)"
  if [ -n "$last" ]; then
    age=$(($(date -u +%s) - last))
    note "最近一次运行：$(date -u -r "$last" '+%Y-%m-%d %H:%M:%S UTC')（$((age / 60)) 分钟前），记录序号 $(mon_status last_seq)"
  else
    note "最近一次运行：还没有"
  fi
  upload="$(mon_status upload)"
  ok_at="$(mon_status last_upload_ok_epoch)"
  err="$(mon_status last_upload_error)"
  case "$upload" in
    configured) note "上传：已配置；最近一次成功 ${ok_at:+$(date -u -r "$ok_at" '+%Y-%m-%d %H:%M UTC')}${ok_at:-还没有}${err:+；最近一次失败 $err}" ;;
    credential-missing) note "上传：已配置目标，但上传凭证不存在或权限不对（应为 root:600）" ;;
    *) note "上传：没有配置上传目标，记录只保存在本机（${MON_RECORDS}）" ;;
  esac
  if [ "$(mon_status timestamps)" = configured ]; then note "每日时间戳：已配置"; else note "每日时间戳：没有配置"; fi
  if [ -n "$(mon_status detail_options)" ]; then
    note "已开启的选项（超出网站那句话）：$(mon_status detail_options)"
  else
    note "可选的加记（可疑程序的连接地址、文件指纹）：关闭"
  fi
}

# Installed, current, configured for this machine and loaded: nothing to do.
up_to_date() {
  mon_installed && mon_loaded &&
    cmp -s monitor/v2cc-monitor.sh "$MON_PROG" &&
    cmp -s monitor/schema.txt "$MON_SCHEMA" &&
    [ "$(mon_plist_text)" = "$(cat "$MON_PLIST" 2>/dev/null)" ] &&
    [ "$(mon_config MACHINE_ID)" = "$machine_id" ] &&
    [ "$(mon_config CUSTOMER)" = "$customer" ]
}

# sudo_install SOURCE DEST MODE: put a root-owned copy in place in one step.
sudo_install() {
  sudo cp "$1" "$2.new"
  sudo chown root:wheel "$2.new"
  sudo chmod "$3" "$2.new"
  sudo mv "$2.new" "$2"
}

install_monitor() {
  local started waited=0 last plist_tmp
  require_operator "安装"
  [ -n "$current_system" ] || die "本机还没有部署 V2CC 系统配置。请先运行 ./bootstrap.sh。"
  [ -n "$customer" ] ||
    die "本机的系统配置没有登记客户账户（部署的是更早的版本）。请先按 docs/ONBOARDING.md 第 15 节「迁移」部署新版本。"
  [ -n "$machine_id" ] || machine_id="$(mon_config MACHINE_ID)"
  [ -n "$machine_id" ] || machine_id="$(mon_new_machine_id)"
  case "$machine_id" in
    '' | *[!A-Za-z0-9._-]*) die "机器编号「${machine_id}」只能用字母、数字、点、下划线和连字符。" ;;
  esac

  if up_to_date; then
    ok "监测程序已安装、是这一版，并且在运行（机器编号 ${machine_id}），跳过。"
    return 0
  fi
  if is_dry_run; then
    printf '  [演练] 将安装监测程序：%s（root 所有），launchd 服务 %s，每 5 分钟运行一次\n' "$MON_PROG" "$MON_LABEL"
    printf '  [演练] 机器编号 %s，客户账户 %s\n' "$machine_id" "$customer"
    return 0
  fi

  ensure_sudo "安装监测程序"
  sudo mkdir -p "$MON_DIR"
  sudo chown root:wheel "$MON_DIR"
  sudo chmod 755 "$MON_DIR"
  sudo_install monitor/v2cc-monitor.sh "$MON_PROG" 755
  sudo_install monitor/schema.txt "$MON_SCHEMA" 644
  sudo /bin/bash "$MON_PROG" configure "MACHINE_ID=$machine_id" "CUSTOMER=$customer" >/dev/null
  plist_tmp="$(mktemp)"
  mon_plist_text >"$plist_tmp"
  sudo_install "$plist_tmp" "$MON_PLIST" 644
  rm -f "$plist_tmp"
  /usr/bin/plutil -lint "$MON_PLIST" >/dev/null 2>&1 || die "生成的 $MON_PLIST 不是有效的属性列表。"

  started="$(date -u +%s)"
  if mon_loaded; then
    sudo launchctl bootout "system/$MON_LABEL" >/dev/null 2>&1 || true
  fi
  sudo launchctl bootstrap system "$MON_PLIST" ||
    die "launchd 没有加载 ${MON_LABEL}。请保留以上输出并联系 V2CC 运营方。"
  sudo launchctl kickstart -k "system/$MON_LABEL" >/dev/null 2>&1 || true
  mon_loaded || die "launchd 服务 $MON_LABEL 没有加载。"
  ok "监测程序已安装并启动：每 5 分钟记录一次（launchd 服务 ${MON_LABEL}，以 root 运行，客户账户停不掉、改不了）"
  ok "机器编号：${machine_id}；客户账户：$customer"

  # The first round runs at once; wait for it, up to a minute.
  last="$(mon_status last_run_epoch)"
  while [ "${last:-0}" -lt "$started" ] && [ "$waited" -lt 60 ]; do
    sleep 2
    waited=$((waited + 2))
    last="$(mon_status last_run_epoch)"
  done
  if [ "${last:-0}" -ge "$started" ]; then
    ok "第一轮已完成，记录序号 $(mon_status last_seq)"
  else
    warn "1 分钟内没有看到第一轮的结果。稍后运行 ./monitor.sh status 或 ./verify.sh 查看。"
  fi
  if [ "$(mon_status upload)" != configured ]; then
    warn "没有配置上传目标：记录只保存在本机（${MON_RECORDS}），不上传。机主要提供的东西和配置方法见 docs/monitoring.md「要机主提供或决定的事」。"
  fi
}

configure_monitor() {
  local id="" sec="" pair
  require_operator "配置"
  mon_installed || die "监测程序没有安装。请先运行 ./monitor.sh install。"
  [ "${#settings[@]}" -gt 0 ] || [ "$ask_credential" = 1 ] || die "没有要改的设置。$usage"
  if is_dry_run; then
    [ "${#settings[@]}" -eq 0 ] || for pair in "${settings[@]}"; do printf '  [演练] 将设置：%s\n' "$pair"; done
    [ "$ask_credential" = 0 ] || printf '  [演练] 将询问并保存上传凭证\n'
    return 0
  fi
  if [ "$ask_credential" = 1 ]; then
    [ -t 0 ] || die "上传凭证只能在终端里输入，当前不是交互终端。"
    read -r -s -p "Access Key ID（输入时不显示）：" id
    printf '\n'
    read -r -s -p "Secret Access Key（输入时不显示）：" sec
    printf '\n'
  fi
  ensure_sudo "配置监测程序"
  if [ "${#settings[@]}" -gt 0 ]; then
    sudo /bin/bash "$MON_PROG" configure "${settings[@]}"
  fi
  if [ "$ask_credential" = 1 ]; then
    printf '%s\n%s\n' "$id" "$sec" | sudo /bin/bash "$MON_PROG" set-credential
    id=""
    sec=""
  fi
  sudo launchctl kickstart -k "system/$MON_LABEL" >/dev/null 2>&1 || true
  ok "已保存。新设置从这一轮开始生效：./monitor.sh status 查看结果。"
}

uninstall_monitor() {
  require_operator "卸载"
  if ! mon_installed && [ ! -e "$MON_DIR" ]; then
    ok "本机没有安装监测程序，无需处理。"
    return 0
  fi
  if is_dry_run; then
    printf '  [演练] 将停止 launchd 服务 %s，删除 %s、%s 和上传凭证\n' "$MON_LABEL" "$MON_PLIST" "$MON_PROG"
    if [ "$delete_records" = 1 ]; then
      printf '  [演练] 将删除本机的全部监测记录：%s\n' "$MON_DIR"
    else
      printf '  [演练] 本机的记录保留在 %s\n' "$MON_RECORDS"
    fi
    return 0
  fi
  if [ "$delete_records" = 1 ]; then
    confirm "将停止并删除监测程序，并删除本机上的全部监测记录（已经上传到机器外的不受影响）。继续？" ||
      die "已取消，没有任何改动。"
  else
    confirm "将停止并删除监测程序。本机已有的记录保留在 ${MON_RECORDS}。继续？" ||
      die "已取消，没有任何改动。"
  fi
  ensure_sudo "卸载监测程序"
  if mon_loaded; then
    sudo launchctl bootout "system/$MON_LABEL" || die "launchd 没有停止 ${MON_LABEL}，没有删除任何文件。"
  fi
  sudo rm -f "$MON_PLIST" "$MON_PROG" "$MON_SCHEMA" "$MON_CRED" "$MON_STATUS"
  ok "监测程序已停止并删除，上传凭证已删除。"
  if [ "$delete_records" = 1 ]; then
    sudo rm -rf "$MON_DIR"
    ok "本机的监测记录已删除。"
  else
    note "本机的记录保留在 ${MON_RECORDS}（只有管理员能读）。不再需要时运行 ./monitor.sh uninstall --delete-records。"
  fi
  note "重新安装：./monitor.sh install"
}

case "$action" in
  status) show_status ;;
  install) install_monitor ;;
  configure) configure_monitor ;;
  uninstall) uninstall_monitor ;;
  *) die "$usage" ;;
esac
