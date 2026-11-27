#!/bin/bash
#
# V2CC machine monitor, minimum version. ./monitor.sh install copies this
# file to /Library/Application Support/V2CC/monitor/v2cc-monitor, next to
# schema.txt, and launchd runs it as root every 5 minutes (com.v2cc.monitor).
#
#   v2cc-monitor run                     one round (root): the routine record,
#                                        alerts, and the hourly and daily parts
#                                        when they are due
#   v2cc-monitor check [--options A,B] FILE...
#                                        check record files against schema.txt
#                                        and the hash chain (any account, also
#                                        on copies taken off the machine)
#   v2cc-monitor configure KEY=VALUE...  change the configuration (root)
#   v2cc-monitor set-credential          store the upload credential, two lines
#                                        on stdin (root)
#
# What it records and what it never records: docs/monitoring.md. Every record
# is checked against schema.txt before it is written; a record with a field
# that is not listed there is not written. Alerts only notify a person.
#
# Only tools that ship with macOS; bash 3.2.
set -uo pipefail
umask 077

V2CC_SYSROOT="${V2CC_SYSROOT:-}"
# Root must only ever run system tools, never something another account
# could have put on a PATH. (Tests point V2CC_SYSROOT at a sandbox and keep
# their stub commands on PATH.)
[ -n "$V2CC_SYSROOT" ] || PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

HERE="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$HERE/schema.txt"
MON_DIR="$V2CC_SYSROOT/Library/Application Support/V2CC/monitor"
CONFIG="$MON_DIR/config"
CRED="$MON_DIR/upload-credential"
RECORDS="$MON_DIR/records"
RECEIPTS="$MON_DIR/receipts"
STATE="$MON_DIR/state"
LOG="$STATE/monitor.log"
STATUS="$V2CC_SYSROOT/var/db/v2cc/monitor-status"
CURRENT_SYSTEM="$V2CC_SYSROOT/run/current-system"
VERSION=1
ZERO_HASH="0000000000000000000000000000000000000000000000000000000000000000"
CLAUDE_TEAM="Q6L2SF6YDW"
DAY_SECONDS=86400

CONFIG_KEYS="MACHINE_ID CUSTOMER UPLOAD_ENDPOINT UPLOAD_BUCKET UPLOAD_REGION OTS_URL TSA_URL CHECK_APPS RETENTION_DAYS ALLOW_SIGNERS API_RANGES NAME_LIST CPU_EXEMPT DETAIL_ADDRESSES DETAIL_FINGERPRINT"

# Defaults. Nothing here sends anything anywhere: without UPLOAD_ENDPOINT and
# UPLOAD_BUCKET the records stay on this machine, and without OTS_URL or
# TSA_URL no fingerprint leaves it.
C_MACHINE_ID=""
C_CUSTOMER=""
C_UPLOAD_ENDPOINT=""
C_UPLOAD_BUCKET=""
C_UPLOAD_REGION="auto"
C_OTS_URL=""
C_TSA_URL=""
C_CHECK_APPS=""
C_RETENTION_DAYS=90
# Programs allowed to talk to the AI provider's API directly, by code
# signature: Apple's own, Anthropic (Claude Code, Claude), Google Chrome, Brave.
C_ALLOW_SIGNERS="apple Q6L2SF6YDW EQHXZ8M8AV KL8N8XSYF4"
# The provider's published API address ranges (docs/monitoring.md).
C_API_RANGES="160.79.104.0/23 153.61.224.0/22 2607:6bc0::/48"
# Program names that raise an alert: <list>:<name>,<name>... Exact names,
# not case sensitive. A starting list, to be kept up to date.
C_NAME_LIST="miner:xmrig,xmr-stak,cpuminer,minerd,t-rex,lolminer,nbminer,gminer,ethminer,nanominer,phoenixminer,teamredminer,srbminer-multi tunnel:frpc,frps,ngrok,cloudflared,bore,chisel,rathole,npc,zrok,tailscale,tailscaled,zerotier-one proxy:sing-box,xray,v2ray,clash,clash-meta,mihomo,gost,ss-local,ss-server,sslocal,ssserver,trojan,trojan-go,hysteria,brook,naive,3proxy,squid,privoxy,tinyproxy bandwidth:honeygain,packetstream,peer2profit,pawns-cli,earnapp,repocket,traffmonetizer,bitping"
# Busy programs that are normal on a developer's machine.
C_CPU_EXEMPT="clang clang++ cc1 cc1plus cc ld ld64 swift swift-frontend swiftc rustc cargo go gcc g++ make ninja cmake xcodebuild ibtool actool node bun deno python3 ffmpeg mds_stores mdworker mdworker_shared kernel_task WindowServer"
# Beyond the website's sentence; each needs the owner's decision before it
# is turned on (docs/monitoring.md).
C_DETAIL_ADDRESSES=0
C_DETAIL_FINGERPRINT=0

CPU_LIMIT=80
CPU_SECONDS=7200
GPU_LIMIT=80
API_SECONDS=3600
BURST_REMOTES=500
GAP_SECONDS=900
DETAIL_SECONDS=86400

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

# ------------------------------------------------------------------ helpers

now_epoch() {
  if [ -n "$V2CC_SYSROOT" ] && [ -n "${V2CC_MONITOR_NOW:-}" ]; then
    printf '%s\n' "$V2CC_MONITOR_NOW"
  else
    date -u +%s
  fi
}
iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'; }
day_of() { date -u -r "$1" '+%Y-%m-%d'; }

log_line() {
  [ -d "$STATE" ] || return 0
  printf '%s %s\n' "$(iso "${NOW:-$(now_epoch)}")" "$*" >>"$LOG"
}

sha256_stdin() { openssl dgst -sha256 | awk '{ print $NF }'; }
hex_of() { od -An -v -tx1 | tr -d ' \n'; }

# hmac_hex KEYHEX: HMAC-SHA256 of stdin. Built from plain SHA-256 so that no
# key ever appears on a command line, where other accounts could read it.
hmac_hex() {
  local key="$1" ipad="" opad="" i b inner
  if [ "${#key}" -gt 128 ]; then
    key="$(printf '%s' "$key" | xxd -r -p | openssl dgst -sha256 -binary | hex_of)"
  fi
  while [ "${#key}" -lt 128 ]; do key="${key}00"; done
  for ((i = 0; i < 128; i += 2)); do
    b=$((16#${key:i:2}))
    ipad="$ipad$(printf '%02x' $((b ^ 0x36)))"
    opad="$opad$(printf '%02x' $((b ^ 0x5c)))"
  done
  inner="$({ printf '%s' "$ipad" | xxd -r -p; cat; } | openssl dgst -sha256 -binary | hex_of)"
  printf '%s%s' "$opad" "$inner" | xxd -r -p | openssl dgst -sha256 -binary | hex_of
}

# Shared awk functions: JSON strings and numbers, addresses.
AWK_LIB='
function jstr(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[[:cntrl:]]/, " ", s); return "\"" s "\"" }
function jint(n) { return sprintf("%.0f", n + 0) }
function jdec(n) { return sprintf("%.1f", n + 0) }
function base(p,   n, a) { n = split(p, a, "/"); return a[n] }
function lastcolon(a,   i) { for (i = length(a); i > 0; i--) if (substr(a, i, 1) == ":") return i; return 0 }
function hostof(a,   k) { k = lastcolon(a); return k ? substr(a, 1, k - 1) : a }
function portof(a,   k) { k = lastcolon(a); return k ? substr(a, k + 1) : "" }
function unbr(h) { sub(/^\[/, "", h); sub(/\]$/, "", h); sub(/%.*$/, "", h); return h }
function is_loop(h) { h = unbr(h); return (h ~ /^127\./ || h == "::1" || h == "localhost" || h ~ /^::ffff:127\./) }
function ip4(h,   a, n) { n = split(h, a, "."); if (n != 4) return -1; return ((a[1] * 256 + a[2]) * 256 + a[3]) * 256 + a[4] }
function pad4(x) { while (length(x) < 4) x = "0" x; return tolower(x) }
function v6hex(h,   k, left, right, ln, rn, L, R, i, out, fill) {
  h = unbr(h); k = index(h, "::")
  if (k) { left = substr(h, 1, k - 1); right = substr(h, k + 2) } else { left = h; right = "" }
  ln = (left == "") ? 0 : split(left, L, ":"); rn = (right == "") ? 0 : split(right, R, ":")
  if (!k && ln != 8) return ""
  out = ""
  for (i = 1; i <= ln; i++) out = out pad4(L[i])
  for (fill = 8 - ln - rn; fill > 0; fill--) out = out "0000"
  for (i = 1; i <= rn; i++) out = out pad4(R[i])
  return (length(out) == 32) ? out : ""
}
function in_ranges(h,   i, net, bits, d, a, x) {
  h = unbr(h)
  if (h ~ /^::ffff:[0-9.]+$/) sub(/^::ffff:/, "", h)
  for (i = 1; i <= nranges; i++) {
    net = rnet[i]; bits = rbits[i]
    if (net ~ /:/) {
      if (h !~ /:/) continue
      x = v6hex(h); a = v6hex(net); d = int(bits / 4)
      if (x != "" && substr(x, 1, d) == substr(a, 1, d)) return 1
    } else {
      if (h !~ /^[0-9.]+$/) continue
      d = 2 ^ (32 - bits)
      if (int(ip4(h) / d) == int(ip4(net) / d)) return 1
    }
  }
  return 0
}
function load_ranges(s,   n, a, i, p) {
  n = split(s, a, " "); nranges = 0
  for (i = 1; i <= n; i++) { p = index(a[i], "/"); if (!p) continue; nranges++; rnet[nranges] = substr(a[i], 1, p - 1); rbits[nranges] = substr(a[i], p + 1) + 0 }
}
function days(y, m, d,   era, yoe, doy, doe) {
  y -= (m <= 2); era = int((y >= 0 ? y : y - 399) / 400); yoe = y - era * 400
  doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
  doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
  return era * 146097 + doe - 719468
}
function offsecs(z,   s) { s = (substr(z, 1, 1) == "-") ? -1 : 1; return s * (substr(z, 2, 2) * 3600 + substr(z, 4, 2) * 60) }
function epoch_of(y, m, d, H, M, S, z) { return days(y, m, d) * 86400 + H * 3600 + M * 60 + S - offsecs(z) }
function month(name) { return int((index("JanFebMarAprMayJunJulAugSepOctNovDec", name) + 2) / 3) }
function iso(e,   d, s, z, era, doe, yoe, y, doy, mp, dd, mm) {
  d = int(e / 86400); s = e - d * 86400; z = d + 719468
  era = int((z >= 0 ? z : z - 146096) / 146097); doe = z - era * 146097
  yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
  y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
  mp = int((5 * doy + 2) / 153); dd = doy - int((153 * mp + 2) / 5) + 1
  mm = mp + (mp < 10 ? 3 : -9); y += (mm <= 2)
  return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, mm, dd, int(s / 3600), int(s % 3600 / 60), s % 60)
}
function safe(v) { return (v ~ /^[A-Za-z0-9._@+-]+$/ && length(v) <= 64) ? v : "(other)" }
'

# A JSON string from bash.
jstr() { JV="$1" awk "$AWK_LIB"'BEGIN { printf "%s", jstr(ENVIRON["JV"]) }'; }
jbool() { if [ "$1" = 1 ]; then printf true; else printf false; fi; }

# ------------------------------------------------------------ configuration

config_valid() {
  local re
  case "$1" in
    MACHINE_ID) re='^[A-Za-z0-9._-]{1,64}$' ;;
    CUSTOMER) re='^[a-z0-9_][a-z0-9_.-]{0,31}$' ;;
    UPLOAD_ENDPOINT) re='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$' ;;
    UPLOAD_BUCKET) re='^[a-z0-9][a-z0-9.-]{1,62}$' ;;
    UPLOAD_REGION) re='^[a-z0-9-]{1,32}$' ;;
    OTS_URL | TSA_URL) re='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$' ;;
    CHECK_APPS) re='^(/[^:"\\[:cntrl:]]+)(:/[^:"\\[:cntrl:]]+)*$' ;;
    RETENTION_DAYS) re='^[1-9][0-9]{0,3}$' ;;
    ALLOW_SIGNERS) re='^[A-Za-z0-9 ]*$' ;;
    API_RANGES) re='^[0-9A-Fa-f:./ ]*$' ;;
    NAME_LIST) re='^[A-Za-z0-9 :,._+-]*$' ;;
    CPU_EXEMPT) re='^[A-Za-z0-9 ._+-]*$' ;;
    DETAIL_ADDRESSES | DETAIL_FINGERPRINT) re='^[01]$' ;;
    *) return 1 ;;
  esac
  [[ $2 =~ $re ]]
}

is_config_key() {
  case " $CONFIG_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Read the configuration as data, never as code: only known keys, only
# values that pass config_valid.
load_config() {
  local line key value
  [ -r "$CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    is_config_key "$key" || continue
    if [ -z "$value" ]; then
      continue
    elif config_valid "$key" "$value"; then
      printf -v "C_$key" '%s' "$value"
    else
      log_line "配置项 ${key} 的值不合规定，已忽略。"
    fi
  done <"$CONFIG"
}

detail_options() {
  local o=""
  [ "$C_DETAIL_ADDRESSES" != 1 ] || o="$o DETAIL_ADDRESSES"
  [ "$C_DETAIL_FINGERPRINT" != 1 ] || o="$o DETAIL_FINGERPRINT"
  printf '%s' "${o# }"
}

upload_configured() { [ -n "$C_UPLOAD_ENDPOINT" ] && [ -n "$C_UPLOAD_BUCKET" ]; }

require_root() {
  [ "$(id -u)" = 0 ] || die "v2cc-monitor $1 要以 root 运行（由 launchd，或 ./monitor.sh 用 sudo 调用）。"
}

cmd_configure() {
  local arg key value tmp line
  require_root configure
  mkdir -p "$MON_DIR"
  tmp="$CONFIG.new.$$"
  [ -e "$CONFIG" ] && cp "$CONFIG" "$tmp" || printf '# v2cc-monitor configuration. Change it with ./monitor.sh configure.\n' >"$tmp"
  for arg; do
    key="${arg%%=*}"
    value="${arg#*=}"
    [ "$key" != "$arg" ] || { rm -f "$tmp"; die "参数应为 KEY=VALUE：$arg"; }
    is_config_key "$key" || { rm -f "$tmp"; die "未知的配置项：$key"; }
    [ "$value" != none ] || value=""
    if [ -n "$value" ] && ! config_valid "$key" "$value"; then
      rm -f "$tmp"
      die "配置项 ${key} 的值不合规定：${value}"
    fi
    grep -v "^${key}=" "$tmp" >"$tmp.2" || true
    [ -z "$value" ] || printf '%s=%s\n' "$key" "$value" >>"$tmp.2"
    mv "$tmp.2" "$tmp"
  done
  # Nothing in it is secret; verify.sh and check read it from any account.
  chmod 644 "$tmp"
  chown root:wheel "$tmp" 2>/dev/null || true
  mv "$tmp" "$CONFIG"
  # The next round does its hourly part (events, upload) at once.
  rm -f "$STATE/hourly"
  while IFS= read -r line; do
    case "$line" in '#'* | '') ;; *) printf '  %s\n' "$line" ;; esac
  done <"$CONFIG"
}

# Two lines on stdin: the access key ID and the secret of an S3-compatible
# credential that may only write objects. Stored root-only; never printed,
# never logged, never on a command line.
cmd_set_credential() {
  local id="" sec="" tmp
  require_root set-credential
  IFS= read -r id || true
  IFS= read -r sec || true
  if [ -z "$id" ] && [ -z "$sec" ]; then
    rm -f "$CRED"
    printf '  上传凭证已删除。\n'
    return 0
  fi
  [[ $id =~ ^[A-Za-z0-9]{8,128}$ ]] || die "凭证的第一行（Access Key ID）格式不对，没有保存。"
  [[ $sec =~ ^[A-Za-z0-9/+=._-]{16,255}$ ]] || die "凭证的第二行格式不对，没有保存。"
  mkdir -p "$MON_DIR"
  tmp="$CRED.new.$$"
  (umask 077 && printf 'id=%s\nsecret=%s\n' "$id" "$sec" >"$tmp")
  chmod 600 "$tmp"
  chown root:wheel "$tmp" 2>/dev/null || true
  mv "$tmp" "$CRED"
  rm -f "$STATE/hourly"
  printf '  上传凭证已保存在 %s（只有 root 能读，不显示内容）。\n' "$CRED"
}

# ------------------------------------------------------------------- schema

# awk code, not shell: nothing in it is meant to expand.
# shellcheck disable=SC2016
VALIDATOR='
function opt_ok(o,   a, n, k) { n = split(o, a, ","); for (k = 1; k <= n; k++) if (index(" " options " ", " " a[k] " ")) return 1; return 0 }
function err(m) { if (!nerr) printf "%s:%d: %s\n", src, NR, m > "/dev/stderr"; nerr++ }
function ws() { while (substr(s, i, 1) ~ /[ \t\r]/) i++ }
function pstr(   c, out) {
  if (substr(s, i, 1) != "\"") { err("expected a string"); return "" }
  i++; out = ""
  while (i <= len) {
    c = substr(s, i, 1)
    if (c == "\\") { out = out substr(s, i, 2); i += 2; continue }
    if (c == "\"") { i++; return out }
    out = out c; i++
  }
  err("unterminated string"); return out
}
function leaf(path, type, v) { nl++; lp[nl] = path; lt[nl] = type; if (path == "kind") kind = v }
function pval(path,   c, key, start) {
  if (nerr) return
  ws(); c = substr(s, i, 1)
  if (c == "{") {
    i++; ws(); if (substr(s, i, 1) == "}") { i++; return }
    while (!nerr) {
      ws(); key = pstr(); ws()
      if (substr(s, i, 1) != ":") { err("expected :"); return }
      i++
      if (path == "") top[key]++
      pval(path == "" ? key : path "." key)
      ws(); c = substr(s, i, 1); i++
      if (c == "}") return
      if (c != ",") { err("expected , or }"); return }
    }
    return
  }
  if (c == "[") {
    i++; ws(); if (substr(s, i, 1) == "]") { i++; return }
    while (!nerr) {
      pval(path "[]"); ws(); c = substr(s, i, 1); i++
      if (c == "]") return
      if (c != ",") { err("expected , or ]"); return }
    }
    return
  }
  if (c == "\"") { leaf(path, "string", pstr()); return }
  if (c ~ /[-0-9]/) { start = i; i++; while (substr(s, i, 1) ~ /[0-9.eE+-]/) i++; leaf(path, "number", substr(s, start, i - start)); return }
  if (substr(s, i, 4) == "true") { i += 4; leaf(path, "bool", "true"); return }
  if (substr(s, i, 5) == "false") { i += 5; leaf(path, "bool", "false"); return }
  err("unexpected value at " path)
}
BEGIN {
  while ((getline l < schema) > 0) {
    if (l ~ /^[ \t]*(#|$)/) continue
    n = split(l, f, /[ \t]+/)
    if (n >= 4 && !opt_ok(f[4])) continue
    allow[f[1] SUBSEP f[2]] = f[3]; known[f[1]] = 1
  }
  bad = 0
}
{
  s = $0; len = length(s); i = 1; nerr = 0; nl = 0; kind = ""
  split("", top); split("", lp); split("", lt)
  pval("")
  ws(); if (!nerr && i <= len) err("trailing text")
  if (!nerr) {
    nreq = split("v seq machine ts prev kind data", req, " ")
    for (k = 1; k <= nreq; k++) if (top[req[k]] != 1) err("missing or repeated " req[k])
    for (key in top) if (key != "data" && !(("*" SUBSEP key) in allow)) err("field not in the schema: " key)
    if (kind == "*" || !(kind in known)) err("unknown kind " kind)
  }
  for (k = 1; !nerr && k <= nl; k++) {
    p = lp[k]
    if (p !~ /^data(\.|\[|$)/) t = allow["*" SUBSEP p]; else t = allow[kind SUBSEP p]
    if (t == "") err("field not in the schema for " kind ": " p)
    else if (t != lt[k]) err("field " p " is " lt[k] ", the schema says " t)
  }
  if (nerr) bad++
}
END { exit bad ? 1 : 0 }
'

# validate_records SRC OPTIONS < lines
validate_records() {
  awk -v schema="$SCHEMA" -v src="$1" -v options="$2" "$VALIDATOR"
}

# ------------------------------------------------------------------ records

LAST_SEQ=0
LAST_HASH="$ZERO_HASH"
LAST_TS=0
REJECTED=0

load_chain() {
  [ -r "$STATE/chain" ] || return 1
  LAST_SEQ="$(sed -n 's/^seq=//p' "$STATE/chain")"
  LAST_HASH="$(sed -n 's/^hash=//p' "$STATE/chain")"
  LAST_TS="$(sed -n 's/^ts=//p' "$STATE/chain")"
  [[ $LAST_SEQ =~ ^[0-9]+$ ]] && [[ $LAST_HASH =~ ^[0-9a-f]{64}$ ]] && [[ $LAST_TS =~ ^[0-9]+$ ]] || {
    log_line "链的状态文件损坏，从序号 0 重新开始。"
    LAST_SEQ=0
    LAST_HASH="$ZERO_HASH"
    LAST_TS=0
    return 1
  }
}

save_chain() {
  printf 'seq=%s\nhash=%s\nts=%s\n' "$LAST_SEQ" "$LAST_HASH" "$NOW" >"$STATE/chain.new"
  mv "$STATE/chain.new" "$STATE/chain"
}

# emit KIND DATA_JSON: one record, appended to today's file, chained to the
# record before it. A record the schema does not allow is not written; a
# notice saying so is written in its place.
emit() {
  local kind="$1" data="$2" seq line file
  seq=$((LAST_SEQ + 1))
  line="{\"v\":$VERSION,\"seq\":$seq,\"machine\":$(jstr "$C_MACHINE_ID"),\"ts\":\"$(iso "$NOW")\",\"prev\":\"$LAST_HASH\",\"kind\":\"$kind\",\"data\":$data}"
  if ! printf '%s\n' "$line" | validate_records "$kind" "$(detail_options)" 2>>"$LOG"; then
    REJECTED=$((REJECTED + 1))
    log_line "一条 ${kind} 记录含有字段清单以外的内容，没有写入。"
    [ "$kind" = notice ] || emit notice "{\"event\":\"record_rejected\",\"about\":$(jstr "$kind")}"
    return 1
  fi
  file="$RECORDS/$(day_of "$NOW").jsonl"
  if [ ! -e "$file" ]; then
    : >"$file"
    chmod 640 "$file"
    chown root:admin "$file" 2>/dev/null || true
  fi
  printf '%s\n' "$line" >>"$file"
  LAST_SEQ=$seq
  LAST_HASH="$(printf '%s' "$line" | sha256_stdin)"
  save_chain
}

# ---------------------------------------------------------------- collection

customer_home() {
  local h
  [ -n "$C_CUSTOMER" ] || return 0
  h="$(dscl . -read "/Users/$C_CUSTOMER" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -n 1)"
  printf '%s' "${h:-$V2CC_SYSROOT/Users/$C_CUSTOMER}"
}

collect_raw() {
  ps -axo pid=,user=,%cpu=,rss=,comm= >"$W/ps.raw" 2>/dev/null || true
  # Only the executable's path, which becomes its name below. Never the
  # arguments or the environment.
  awk 'BEGIN { OFS = "\t" }
    { line = $0; sub(/^ *[0-9]+ +[^ ]+ +[0-9.]+ +[0-9]+ +/, "", line)
      n = split(line, a, "/"); name = a[n]; gsub(/\t/, " ", name)
      if ($1 ~ /^[0-9]+$/ && name != "") print $1, $2, $3 + 0, $4 + 0, name }' "$W/ps.raw" >"$W/ps"
  nettop -P -L 1 -n -x -J bytes_in,bytes_out >"$W/nettop" 2>/dev/null || true
  lsof +c 0 -nP -i -F pcLPnT >"$W/lsof" 2>/dev/null || true
  # Network rows: what listens, and every connection with a remote end.
  awk -v ranges="$C_API_RANGES" -v W="$W" "$AWK_LIB"'
    BEGIN { FS = OFS = "\t"; load_ranges(ranges)
      while ((getline l < (W "/ps")) > 0) { split(l, f, "\t"); pname[f[1]] = f[5]; puser[f[1]] = f[2] } }
    function flush(   name, user, rh, rp, lh, lp) {
      if (fd == "") return
      name = (pid in pname) ? pname[pid] : cmd; user = (pid in puser) ? puser[pid] : usr
      if (rem == "") {
        lh = hostof(loc); lp = portof(loc)
        if (lp ~ /^[0-9]+$/ && ((proto == "TCP" && st == "LISTEN") || proto == "UDP"))
          print name, user, proto, lp, (is_loop(lh) ? "loopback" : "external") > (W "/listen")
      } else {
        rh = unbr(hostof(rem)); rp = portof(rem)
        if (!is_loop(rh)) print pid, name, user, rh, rp, st, in_ranges(rh) > (W "/conn")
      }
      fd = ""; proto = ""; loc = ""; rem = ""; st = ""
    }
    /^p/ { flush(); pid = substr($0, 2); cmd = ""; usr = ""; next }
    /^c/ { cmd = substr($0, 2); next }
    /^L/ { usr = substr($0, 2); next }
    /^f/ { flush(); fd = substr($0, 2); next }
    /^P/ { proto = substr($0, 2); next }
    /^n/ { n = substr($0, 2); k = index(n, "->"); if (k) { loc = substr(n, 1, k - 1); rem = substr(n, k + 2) } else { loc = n; rem = "" }; next }
    /^TST=/ { st = substr($0, 5); next }
    END { flush() }' "$W/lsof"
  touch "$W/listen" "$W/conn"
}

json_s1() {
  local boot console
  boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')"
  console="$(stat -f %Su "$V2CC_SYSROOT/dev/console" 2>/dev/null || true)"
  [[ $console =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || console="(other)"
  CONSOLE_USER="$console"
  printf '{"boot_time":%s,"console_user":%s}' "${boot:-0}" "$(jstr "$console")"
}

json_s2() {
  local data_vol="$V2CC_SYSROOT/System/Volumes/Data"
  [ -d "$data_vol" ] || data_vol="$V2CC_SYSROOT/"
  top -l 1 -n 0 >"$W/top" 2>/dev/null || true
  vm_stat >"$W/vm" 2>/dev/null || true
  df -k "$data_vol" >"$W/df" 2>/dev/null || true
  ioreg -r -d 1 -c IOAccelerator >"$W/ioreg" 2>/dev/null || true
  netstat -ibn >"$W/netstat" 2>/dev/null || true
  awk -v memsize="$(sysctl -n hw.memsize 2>/dev/null)" -v W="$W" "$AWK_LIB"'
    BEGIN {
      while ((getline l < (W "/top")) > 0) {
        if (l ~ /^CPU usage:/) { split(l, a, " "); cu = a[3]; cs = a[5]; ci = a[7]; gsub(/%/, "", cu); gsub(/%/, "", cs); gsub(/%/, "", ci) }
        if (l ~ /^Load Avg:/) { split(l, a, " "); la = a[3]; gsub(/,/, "", la) }
      }
      pgsz = 16384
      while ((getline l < (W "/vm")) > 0) {
        if (l ~ /page size of/) { p = l; sub(/^.*page size of /, "", p); pgsz = p + 0 }
        k = l; sub(/:.*/, "", k); v = l; sub(/^.*: */, "", v); sub(/\.$/, "", v)
        if (k == "Pages active" || k == "Pages wired down" || k == "Pages occupied by compressor") used += v
      }
      n = 0
      while ((getline l < (W "/df")) > 0) { n++; if (n == 2) { split(l, a, " "); dt = a[2]; du = a[3]; da = a[4] } }
      gpu = 0
      while ((getline l < (W "/ioreg")) > 0) {
        if (match(l, /"Device Utilization %"=[0-9]+/)) { g = substr(l, RSTART, RLENGTH); sub(/.*=/, "", g); if (g + 0 > gpu) gpu = g + 0 }
      }
      while ((getline l < (W "/netstat")) > 0) {
        m = split(l, a, " ")
        if (a[3] ~ /^<Link#/ && a[1] !~ /^lo/ && m >= 8) { ni += a[m - 4]; no += a[m - 1] }
      }
      printf "{\"cpu_user\":%s,\"cpu_sys\":%s,\"cpu_idle\":%s,\"load1\":%s,\"mem_total\":%s,\"mem_used\":%s,", jdec(cu), jdec(cs), jdec(ci), sprintf("%.2f", la + 0), jint(memsize), jint(used * pgsz)
      printf "\"disk_total_kb\":%s,\"disk_used_kb\":%s,\"disk_avail_kb\":%s,\"gpu_util\":%s,\"net_in_bytes\":%s,\"net_out_bytes\":%s}", jint(dt), jint(du), jint(da), jint(gpu), jint(ni), jint(no)
      print jint(gpu) > (W "/gpu")
    }'
}

json_s3() {
  sort -t "$(printf '\t')" -k3,3nr "$W/ps" | head -n 10 >"$W/top10"
  awk -v W="$W" "$AWK_LIB"'
    BEGIN { FS = "\t"
      while ((getline l < (W "/nettop")) > 0) {
        n = split(l, a, ","); if (n < 3) continue
        p = a[1]; k = 0; for (j = length(p); j > 0; j--) if (substr(p, j, 1) == ".") { k = j; break }
        pid = substr(p, k + 1); if (pid !~ /^[0-9]+$/) continue
        bin[pid] = a[2] + 0; bout[pid] = a[3] + 0
      }
      printf "["; sep = ""
      while ((getline l < (W "/top10")) > 0) {
        split(l, f, "\t")
        printf "%s{\"name\":%s,\"user\":%s,\"cpu\":%s,\"rss_kb\":%s,\"bytes_in\":%s,\"bytes_out\":%s}", sep, jstr(f[5]), jstr(f[2]), jdec(f[3]), jint(f[4]), jint(bin[f[1]]), jint(bout[f[1]])
        sep = ","
      }
      printf "]"
    }'
}

json_s4() {
  sort -u "$W/listen" | head -n 200 | awk "$AWK_LIB"'
    BEGIN { FS = "\t"; printf "["; sep = "" }
    { printf "%s{\"name\":%s,\"user\":%s,\"proto\":%s,\"port\":%s,\"scope\":%s}", sep, jstr($1), jstr($2), jstr($3), jint($4), jstr($5); sep = "," }
    END { printf "]" }'
}

# Who signed the program a process runs: "apple", a 10-character developer
# team, "unsigned", or "invalid". Only reads the signature.
signer_of() {
  local exe="$1" team
  [ -n "$exe" ] && [ -e "$exe" ] || { printf 'unsigned'; return; }
  if codesign -v -R='anchor apple' "$exe" >/dev/null 2>&1; then
    printf 'apple'
    return
  fi
  team="$(codesign -dv "$exe" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  if ! [[ $team =~ ^[A-Z0-9]{10}$ ]]; then
    printf 'unsigned'
  elif codesign -v -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$exe" >/dev/null 2>&1; then
    printf '%s' "$team"
  else
    printf 'invalid'
  fi
}

exe_of() { lsof -p "$1" -a -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1; }

json_s5() {
  local key pid signer allowed
  # One process per program that talks to the API ranges, for its signature.
  awk 'BEGIN { FS = OFS = "\t" } $7 == 1 && !seen[$2 SUBSEP $3]++ { print $2 "|" $3, $1 }' "$W/conn" >"$W/api_pids"
  : >"$W/signers"
  while IFS="$(printf '\t')" read -r key pid; do
    signer="$(signer_of "$(exe_of "$pid")")"
    allowed=0
    case " $C_ALLOW_SIGNERS " in *" $signer "*) allowed=1 ;; esac
    printf '%s\t%s\t%s\n' "$key" "$signer" "$allowed" >>"$W/signers"
  done <"$W/api_pids"
  awk -v W="$W" -v burst="$BURST_REMOTES" "$AWK_LIB"'
    BEGIN { FS = "\t"
      while ((getline l < (W "/signers")) > 0) { split(l, f, "\t"); sig[f[1]] = f[2]; ok[f[1]] = f[3] }
      while ((getline l < (W "/conn")) > 0) {
        split(l, f, "\t"); k = f[2] "|" f[3]
        if (!(k in conns)) { order[++nk] = k; nm[k] = f[2]; us[k] = f[3] }
        conns[k]++
        if (!((k SUBSEP f[4]) in rseen)) { rseen[k SUBSEP f[4]] = 1; remotes[k]++ }
        if (f[6] == "SYN_SENT") syn[k]++
        if (f[5] ~ /^[0-9]+$/) { if (!((k SUBSEP f[5]) in pc)) { pl[k] = pl[k] " " f[5] } pc[k SUBSEP f[5]]++ }
        if (f[7] == 1) api[k]++
      }
      printf "["; sep = ""
      for (j = 1; j <= nk && j <= 200; j++) {
        k = order[j]
        printf "%s{\"name\":%s,\"user\":%s,\"conns\":%s,\"remotes\":%s,\"syn_sent\":%s,\"ports\":[", sep, jstr(nm[k]), jstr(us[k]), jint(conns[k]), jint(remotes[k]), jint(syn[k])
        np = split(pl[k], ports, " "); other = 0; psep = ""
        for (q = 1; q <= np; q++) {
          if (q <= 20) { printf "%s{\"port\":%s,\"n\":%s}", psep, jint(ports[q]), jint(pc[k SUBSEP ports[q]]); psep = "," }
          else other += pc[k SUBSEP ports[q]]
        }
        printf "],\"ports_other\":%s,\"api\":%s", jint(other), jint(api[k])
        if (api[k] > 0) printf ",\"api_signer\":%s,\"api_allowed\":%s", jstr(sig[k] == "" ? "unsigned" : sig[k]), (ok[k] == 1 ? "true" : "false")
        printf "}"; sep = ","
        if (api[k] > 0 && ok[k] != 1) print k "\t" api[k] > (W "/api_unlisted")
        if (remotes[k] > burst) print k "\t" remotes[k] > (W "/burst")
      }
      printf "]"
    }'
  touch "$W/api_unlisted" "$W/burst"
}

# Names in one directory, as a JSON array of strings. Names only, never
# what the files contain.
json_names() {
  local dir="$1"
  local f
  for f in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$f" ] && printf '%s\n' "${f##*/}"
  done | head -n 200 | awk "$AWK_LIB"'
    BEGIN { printf "["; sep = "" } { printf "%s%s", sep, jstr($0); sep = "," } END { printf "]" }'
}

# Login and background items as macOS lists them: name, developer team,
# type and whether enabled. Never their paths.
btm_json() {
  awk "$AWK_LIB"'
      function val(l) { sub(/^[^:]*: */, "", l); return l }
      function flush() {
        if (!item || n >= 300) return
        printf "%s{\"uid\":%s,\"name\":%s,\"team\":%s,\"type\":%s,\"enabled\":%s}", sep, jint(uid), jstr(name), jstr(team), jstr(type), (en ? "true" : "false")
        sep = ","; n++; item = 0
      }
      BEGIN { printf "["; sep = ""; uid = -1 }
      /Records for UID/ { flush(); u = $0; sub(/^.*Records for UID /, "", u); sub(/[^-0-9].*$/, "", u); uid = u + 0; next }
      /^ *#[0-9]+:/ { flush(); item = 1; name = ""; team = ""; type = ""; en = 0; next }
      item && /^ *Name: / { name = val($0); next }
      item && /^ *Team Identifier: / { team = val($0); next }
      item && /^ *Type: / { type = val($0); sub(/ *\(.*$/, "", type); next }
      item && /^ *Disposition: / { d = val($0); sub(/^\[/, "", d); split(d, parts, ","); en = (parts[1] == "enabled"); next }
      END { flush(); printf "]" }' "$W/btm"
}

json_s6() {
  local home
  home="$(customer_home)"
  sfltool dumpbtm >"$W/btm" 2>/dev/null || true
  printf '{"customer_agents":%s,"system_agents":%s,"system_daemons":%s,"btm":%s}' \
    "$(if [ -n "$home" ]; then json_names "$home/Library/LaunchAgents"; else printf '[]'; fi)" \
    "$(json_names "$V2CC_SYSROOT/Library/LaunchAgents")" \
    "$(json_names "$V2CC_SYSROOT/Library/LaunchDaemons")" \
    "$(btm_json)"
}

# The components we installed and the system settings. Sets COMP_FAILED
# (check names) and writes the facts compared from run to run to $W/s7sig.
json_s7() {
  local home uu_daemon=0 uu_agent="" claude="" present=0 signed=0 apps="" sep="" app name ap as \
    system sysext mdm dep proxy failed="" uid old_ifs
  home="$(customer_home)"
  launchctl print system/com.netease.uuremote.daemon >/dev/null 2>&1 && uu_daemon=1
  [ "$uu_daemon" = 1 ] || failed="$failed uu_daemon"
  if [ -n "$C_CUSTOMER" ] && [ "$CONSOLE_USER" = "$C_CUSTOMER" ]; then
    uid="$(id -u "$C_CUSTOMER" 2>/dev/null)"
    uu_agent=0
    launchctl print "gui/$uid/com.netease.uuremote.agent" >/dev/null 2>&1 && uu_agent=1
    [ "$uu_agent" = 1 ] || failed="$failed uu_agent"
  fi
  if [ -n "$home" ]; then
    claude="$home/.local/bin/claude"
    # Present and signed by Anthropic. It is never run as root.
    if [ -e "$claude" ]; then
      present=1
      codesign -v -R="anchor apple generic and certificate leaf[subject.OU] = \"$CLAUDE_TEAM\"" "$claude" >/dev/null 2>&1 && signed=1
    fi
    [ "$present" = 1 ] && [ "$signed" = 1 ] || failed="$failed claude"
  fi
  old_ifs="$IFS"
  IFS=:
  for app in $C_CHECK_APPS; do
    IFS="$old_ifs"
    name="${app##*/}"
    ap=0
    as=0
    if [ -e "$V2CC_SYSROOT$app" ]; then
      ap=1
      codesign -v "$V2CC_SYSROOT$app" >/dev/null 2>&1 && as=1
    fi
    [ "$ap" = 1 ] && [ "$as" = 1 ] || failed="$failed app:$name"
    apps="$apps$sep{\"name\":$(jstr "$name"),\"present\":$(jbool "$ap"),\"signed\":$(jbool "$as")}"
    sep=","
  done
  IFS="$old_ifs"
  system="$(cd -P "$CURRENT_SYSTEM" 2>/dev/null && basename "$(pwd -P)")"
  systemextensionsctl list >"$W/sysext" 2>/dev/null || true
  sysext="$(awk -F '\t' "$AWK_LIB"'
    BEGIN { printf "["; sep = "" }
    NF >= 6 && $3 ~ /^[A-Z0-9]+$/ {
      b = $4; sub(/ .*$/, "", b); s = $NF; gsub(/^\[|\]$/, "", s)
      printf "%s{\"team\":%s,\"bundle\":%s,\"state\":%s}", sep, jstr($3), jstr(b), jstr(s); sep = ","; print $3 " " b " " s > sig
    }
    END { printf "]" }' sig="$W/sysext.sig" "$W/sysext")"
  profiles status -type enrollment >"$W/profiles" 2>/dev/null || true
  mdm=0
  dep=0
  grep -q '^MDM enrollment: Yes' "$W/profiles" && mdm=1
  grep -q '^Enrolled via DEP: Yes' "$W/profiles" && dep=1
  scutil --proxy >"$W/proxy" 2>/dev/null || true
  proxy="$(awk '
    $1 == "HTTPEnable" { h = ($3 == 1) } $1 == "HTTPSEnable" { s = ($3 == 1) } $1 == "SOCKSEnable" { k = ($3 == 1) }
    $1 == "ProxyAutoConfigEnable" { p = ($3 == 1) } $1 == "ProxyAutoDiscoveryEnable" { a = ($3 == 1) }
    function b(x) { return x ? "true" : "false" }
    END { printf "{\"http\":%s,\"https\":%s,\"socks\":%s,\"pac\":%s,\"auto\":%s}", b(h), b(s), b(k), b(p), b(a) }' "$W/proxy")"
  COMP_FAILED="${failed# }"
  {
    printf 'system=%s\n' "$system"
    printf 'sysext=%s\n' "$(sort "$W/sysext.sig" 2>/dev/null | tr '\n' ';')"
    printf 'mdm=%s%s\n' "$mdm" "$dep"
    printf 'proxy=%s\n' "$proxy"
  } >"$W/s7sig"
  printf '{"uu_daemon":%s,' "$(jbool "$uu_daemon")"
  [ -z "$uu_agent" ] || printf '"uu_agent":%s,' "$(jbool "$uu_agent")"
  [ -z "$claude" ] || printf '"claude_present":%s,"claude_signed":%s,' "$(jbool "$present")" "$(jbool "$signed")"
  printf '"apps":[%s],"system":%s,"sysext":%s,"mdm_enrolled":%s,"dep_enrolled":%s,"proxy":%s,"failed":%s}' \
    "$apps" "$(jstr "$system")" "$sysext" "$(jbool "$mdm")" "$(jbool "$dep")" "$proxy" \
    "$(printf '%s' "$COMP_FAILED" | tr ' ' '\n' | awk "$AWK_LIB"'BEGIN { printf "["; sep = "" } NF { printf "%s%s", sep, jstr($0); sep = "," } END { printf "]" }')"
}

routine() {
  local s1 s2 s3 s4 s5 s6 s7
  collect_raw
  s1="$(json_s1)"
  CONSOLE_USER="$(printf '%s' "$s1" | sed -n 's/.*"console_user":"\([^"]*\)".*/\1/p')"
  s2="$(json_s2)"
  s3="$(json_s3)"
  s4="$(json_s4)"
  s5="$(json_s5)"
  s6="$(json_s6)"
  s7="$(json_s7)"
  # json_s7 ran in a subshell; what it found is in its signature file.
  COMP_FAILED="$(sed -n 's/.*"failed":\[\(.*\)\]}$/\1/p' <<<"$s7" | tr -d '"' | tr ',' ' ')"
  emit routine "{\"s1\":$s1,\"s2\":$s2,\"s3\":$s3,\"s4\":$s4,\"s5\":$s5,\"s6\":$s6,\"s7\":$s7,\"upload_configured\":$(upload_configured && printf true || printf false)}"
}

# -------------------------------------------------------------------- alerts

# Conditions true right now, one per line:
# key, seconds it must last, alert, category, name, user, value, list, check
conditions() {
  local gpu c
  {
    awk -v limit="$CPU_LIMIT" -v need="$CPU_SECONDS" -v exempt=" $C_CPU_EXEMPT " -v lists="$C_NAME_LIST" '
      BEGIN { FS = OFS = "\t"; n = split(lists, L, " ")
        for (i = 1; i <= n; i++) { p = index(L[i], ":"); cat = substr(L[i], 1, p - 1); m = split(substr(L[i], p + 1), N, ",")
          for (j = 1; j <= m; j++) if (N[j] != "") listed[tolower(N[j])] = cat } }
      { k = $5 "|" $2
        if ($3 > limit && index(exempt, " " $5 " ") == 0 && $3 > hot[k]) { hot[k] = $3; hn[k] = $5; hu[k] = $2 }
        if ((tolower($5) in listed) && !seen[k]++) {
          cat = listed[tolower($5)]
          print "list|" cat "|" k, 0, "name_list", (cat == "miner" ? "F" : "H"), $5, $2, "", cat, ""
        } }
      END { for (k in hot) print "cpu|" k, need, "cpu_sustained", "F", hn[k], hu[k], int(hot[k]), "", "" }' "$W/ps"
    awk -v customer="$C_CUSTOMER" 'BEGIN { FS = OFS = "\t" }
      $2 == customer && $5 == "external" { k = $1 "|" $2; n[k]++; nm[k] = $1; us[k] = $2 }
      END { for (k in n) print "listen|" k, 0, "external_listen", "H", nm[k], us[k], n[k], "", "" }' "$W/listen"
    awk -v need="$API_SECONDS" 'BEGIN { FS = OFS = "\t" }
      { split($1, a, "|"); print "api|" $1, need, "api_direct", "C", a[1], a[2], $2, "", "" }' "$W/api_unlisted"
    awk 'BEGIN { FS = OFS = "\t" }
      { split($1, a, "|"); print "burst|" $1, 0, "connection_burst", "A2", a[1], a[2], $2, "", "" }' "$W/burst"
    gpu="$(cat "$W/gpu" 2>/dev/null)"
    [ "${gpu:-0}" -le "$GPU_LIMIT" ] || printf 'gpu\t%s\tgpu_sustained\tF\t\t\t%s\t\t\n' "$CPU_SECONDS" "$gpu"
    for c in $COMP_FAILED; do
      printf 'comp|%s\t0\tcomponent_failed\tG\t\t\t\t\t%s\n' "$c" "$c"
    done
  } >"$W/cond"
}

# merge STATEFILE CONDFILE: raise what has lasted long enough, clear what is
# over. Writes the alerts to emit to $W/events.
merge() {
  local st="$1" cond="$2"
  touch "$st"
  awk -v now="$NOW" -v prevf="$st" -v newf="$st.new" -v evf="$W/events" '
    BEGIN { FS = OFS = "\t"; while ((getline l < prevf) > 0) { split(l, a, "\t"); prev[a[1]] = l; pf[a[1]] = a[2]; pr[a[1]] = a[3] } }
    { k = $1; first = (k in pf) ? pf[k] : now; raised = (k in pr) ? pr[k] : 0
      if (raised == 0 && now - first >= $2) { raised = now; print "raised", $3, $4, $5, $6, $7, $8, $9 >> evf }
      print k, first, raised, $3, $4, $5, $6, $7, $8, $9 > newf; seen[k] = 1 }
    END { for (k in prev) if (!(k in seen)) { split(prev[k], a, "\t"); if (a[3] > 0) print "cleared", a[4], a[5], a[6], a[7], a[8], a[9], a[10] >> evf }
      printf "" > newf }' "$cond"
  mv "$st.new" "$st"
}

alerts() {
  local recent_api=0 recent_exp=0 line
  : >"$W/events"
  if [ "$LAST_TS" -gt 0 ] && [ $((NOW - LAST_TS)) -gt "$GAP_SECONDS" ]; then
    printf 'raised\theartbeat_gap\t\t\t\t%s\t\t\n' "$((NOW - LAST_TS))" >>"$W/events"
  fi
  conditions
  merge "$STATE/alerts" "$W/cond"
  # A program calling the API directly and the machine being opened up to
  # others, within the same 24 hours.
  recent_api="$(sed -n 's/^recent_api=\([0-9]*\)$/\1/p' "$STATE/recent" 2>/dev/null)"
  recent_exp="$(sed -n 's/^recent_exp=\([0-9]*\)$/\1/p' "$STATE/recent" 2>/dev/null)"
  recent_api="${recent_api:-0}"
  recent_exp="${recent_exp:-0}"
  grep -q $'^api|[^\t]*\t[0-9]*\t[1-9]' "$STATE/alerts" && recent_api="$NOW"
  grep -Eq $'^(listen\\||list\\|(tunnel|proxy)\\|)[^\t]*\t[0-9]*\t[1-9]' "$STATE/alerts" && recent_exp="$NOW"
  printf 'recent_api=%s\nrecent_exp=%s\n' "$recent_api" "$recent_exp" >"$STATE/recent"
  if [ $((NOW - recent_api)) -lt "$DAY_SECONDS" ] && [ $((NOW - recent_exp)) -lt "$DAY_SECONDS" ]; then
    printf 'combo\t0\tapi_direct_exposure\tC\t\t\t\t\t\n' >"$W/cond2"
  else
    : >"$W/cond2"
  fi
  merge "$STATE/alerts-combo" "$W/cond2"
  # Changed since the last run: the system configuration, the system
  # extensions, device management, the system proxy.
  if [ -r "$STATE/s7sig" ]; then
    while IFS= read -r line; do
      grep -Fxq -- "$line" "$STATE/s7sig" ||
        printf 'raised\tcomponent_changed\tG\t\t\t\t\t%s\n' "${line%%=*}" >>"$W/events"
    done <"$W/s7sig"
  fi
  cp "$W/s7sig" "$STATE/s7sig"

  awk "$AWK_LIB"'BEGIN { FS = "\t" }
    { printf "{\"alert\":%s,\"state\":%s", jstr($2), jstr($1)
      if ($3 != "") printf ",\"category\":%s", jstr($3)
      if ($4 != "") printf ",\"name\":%s", jstr($4)
      if ($5 != "") printf ",\"user\":%s", jstr($5)
      if ($6 != "") printf ",\"value\":%s", jint($6)
      if ($7 != "") printf ",\"list\":%s", jstr($7)
      if ($8 != "") printf ",\"check\":%s", jstr($8)
      printf "}\n" }' "$W/events" >"$W/alerts.json"
  RAISED=0
  while IFS= read -r line; do
    emit alert "$line"
    case "$line" in *'"state":"raised"'*) RAISED=$((RAISED + 1)) ;; esac
  done <"$W/alerts.json"
  # Open a detail window for each program an alert was raised about.
  if [ -n "$(detail_options)" ]; then
    awk -v now="$NOW" -v span="$DETAIL_SECONDS" 'BEGIN { FS = OFS = "\t" } $1 == "raised" && $4 != "" { print $4, $5, $2, now + span }' \
      "$W/events" >>"$STATE/details"
  fi
}

# Only with DETAIL_ADDRESSES or DETAIL_FINGERPRINT on (off by default): for
# up to 24 hours after an alert, the addresses the program connects to and
# the SHA-256 of its executable. Nothing for any other program.
details() {
  local name user alert until remotes sha pid exe ident data
  [ -n "$(detail_options)" ] || { rm -f "$STATE/details" "$STATE/exe"; return 0; }
  [ -r "$STATE/details" ] || return 0
  awk -v now="$NOW" 'BEGIN { FS = "\t" } $4 > now && !seen[$1 SUBSEP $2]++' "$STATE/details" >"$W/details"
  mv "$W/details" "$STATE/details"
  touch "$STATE/exe"
  while IFS="$(printf '\t')" read -r name user alert until; do
    data="{\"alert\":$(jstr "$alert"),\"name\":$(jstr "$name"),\"user\":$(jstr "$user")"
    if [ "$C_DETAIL_ADDRESSES" = 1 ]; then
      remotes="$(awk -v nm="$name" -v us="$user" "$AWK_LIB"'BEGIN { FS = "\t" }
        $2 == nm && $3 == us { k = $4 "\t" $5; if (!(k in c)) o[++n] = k; c[k]++ }
        END { printf "["; for (i = 1; i <= n && i <= 100; i++) { split(o[i], a, "\t"); printf "%s{\"addr\":%s,\"port\":%s,\"n\":%s}", (i > 1 ? "," : ""), jstr(a[1]), jint(a[2]), jint(c[o[i]]) } printf "]" }' "$W/conn")"
      data="$data,\"remotes\":$remotes"
    fi
    if [ "$C_DETAIL_FINGERPRINT" = 1 ]; then
      pid="$(awk -v nm="$name" -v us="$user" 'BEGIN { FS = "\t" } $5 == nm && $2 == us { print $1; exit }' "$W/ps")"
      exe="$([ -z "$pid" ] || exe_of "$pid")"
      if [ -n "$exe" ] && [ -f "$exe" ]; then
        ident="$(stat -f '%i:%z:%m' "$exe" 2>/dev/null)"
        # Hashed again only when the file changed. Its bytes are hashed;
        # its contents are never stored or shown.
        sha="$(awk -v k="$name|$user|$ident" 'BEGIN { FS = "\t" } $1 == k { print $2 }' "$STATE/exe")"
        if [ -z "$sha" ]; then
          sha="$(openssl dgst -sha256 <"$exe" | awk '{ print $NF }')"
          printf '%s\t%s\n' "$name|$user|$ident" "$sha" >>"$STATE/exe"
        fi
        data="$data,\"sha256\":$(jstr "$sha")"
      fi
    fi
    emit detail "$data}"
  done <"$STATE/details"
}

# ----------------------------------------------------------------- S9 events

hourly_events() {
  local since until offset
  since="$(cat "$STATE/s9_since" 2>/dev/null)"
  [[ $since =~ ^[0-9]+$ ]] || since=$((NOW - 3600))
  # The clock went back: start again from the last hour.
  [ "$since" -lt "$NOW" ] || since=$((NOW - 3600))
  until="$NOW"
  offset="$(date -r "$NOW" +%z)"
  touch "$STATE/s9_seen"
  # Console sessions, restarts and shutdowns. Terminal windows (ttys) are
  # left out.
  last 2>/dev/null | head -n 200 >"$W/last" || true
  pmset -g log 2>/dev/null | awk '$4 ~ /^(Sleep|Wake|DarkWake|Start|Shutdown|Restart)$/' | tail -n 500 >"$W/pmset" || true
  log show --start "$(date -r "$since" '+%Y-%m-%d %H:%M:%S')" --end "$(date -r "$until" '+%Y-%m-%d %H:%M:%S')" \
    --style ndjson --predicate 'process == "sshd" OR process == "sshd-session" OR process == "screensharingd" OR (process == "authd" AND eventMessage CONTAINS "authoriz")' \
    >"$W/logshow" 2>/dev/null || true
  awk -v since="$since" -v until="$until" -v off="$offset" -v year="$(date -r "$NOW" +%Y)" -v W="$W" -v seenf="$STATE/s9_seen" "$AWK_LIB"'
    function add(e, type, acct, right,   k) {
      if (e < since - 3600 || e > until) return
      k = type "|" acct "|" e
      if (k in seen) return
      seen[k] = 1; print k >> seenf
      if (e <= since - 3600) return
      ev[++n] = e; et[n] = type; ea[n] = acct; er[n] = right
    }
    function lastepoch(mon, d, hm,   e, hh, mm) {
      split(hm, t, ":"); e = epoch_of(year, month(mon), d, t[1], t[2], 0, off)
      if (e > until + 86400) e = epoch_of(year - 1, month(mon), d, t[1], t[2], 0, off)
      return e
    }
    # The first single-quoted part of a message.
    function quoted(m, q,   k) { k = index(m, q); m = substr(m, k + 1); k = index(m, q); return k ? substr(m, 1, k - 1) : "" }
    function dur(s,   d, hm) { gsub(/[()]/, "", s); d = 0; if (index(s, "+")) { d = substr(s, 1, index(s, "+") - 1); s = substr(s, index(s, "+") + 1) } split(s, hm, ":"); return d * 86400 + hm[1] * 3600 + hm[2] * 60 }
    BEGIN {
      while ((getline l < seenf) > 0) seen[l] = 1
      close(seenf)
      while ((getline l < (W "/last")) > 0) {
        m = split(l, f, " ")
        if ((f[1] == "reboot" || f[1] == "shutdown") && m >= 6) { add(lastepoch(f[4], f[5], f[6]), f[1], "", ""); continue }
        if (f[2] != "console" || m < 6) continue
        e = lastepoch(f[4], f[5], f[6]); add(e, "login", safe(f[1]), "")
        if (f[7] == "-" && f[8] ~ /^[0-9]+:[0-9]+$/ && f[9] ~ /^\(/) add(e + dur(f[9]), "logout", safe(f[1]), "")
      }
      while ((getline l < (W "/pmset")) > 0) {
        split(l, f, " "); split(f[1], d, "-"); split(f[2], t, ":")
        add(epoch_of(d[1], d[2], d[3], t[1], t[2], t[3], f[3]), tolower(f[4]), "", "")
      }
      while ((getline l < (W "/logshow")) > 0) {
        if (!match(l, /"eventMessage":"([^"\\]|\\.)*"/)) continue
        msg = substr(l, RSTART + 16, RLENGTH - 17); gsub(/\\\//, "/", msg); gsub(/\\"/, "\"", msg)
        if (!match(l, /"timestamp":"[0-9-]+ [0-9:.]+[-+][0-9]+"/)) continue
        ts = substr(l, RSTART + 13, RLENGTH - 14); split(ts, p, /[- :.+]/)
        z = substr(ts, length(ts) - 4)
        e = epoch_of(p[1], p[2], p[3], p[4], p[5], p[6], z)
        proc = ""; if (match(l, /"processImagePath":"[^"]*"/)) { proc = substr(l, RSTART + 20, RLENGTH - 21); sub(/^.*\//, "", proc) }
        type = ""; acct = ""; right = ""
        q = sprintf("%c", 39)
        if (index(msg, "Succeeded authorizing right " q) == 1) { type = "auth_succeeded"; right = quoted(msg, q) }
        else if (index(msg, "Failed to authorize right " q) == 1 || index(msg, "Failed authorizing right " q) == 1) { type = "auth_failed"; right = quoted(msg, q) }
        else if (proc ~ /^sshd(-session)?$/ && msg ~ /^Accepted [^ ]+ for [^ ]+ from /) { type = "ssh_accepted"; split(msg, w, " "); acct = w[4] }
        else if (proc ~ /^sshd(-session)?$/ && msg ~ /^Failed [^ ]+ for (invalid user )?[^ ]+ from /) { type = "ssh_failed"; split(msg, w, " "); acct = (w[4] == "invalid") ? w[6] : w[4] }
        else if (proc == "screensharingd" && msg ~ /Authentication: (SUCCEEDED|FAILED) :: User Name: /) {
          type = (msg ~ /SUCCEEDED/) ? "screensharing_succeeded" : "screensharing_failed"; acct = msg; sub(/^.*User Name: /, "", acct); sub(/ .*$/, "", acct) }
        if (type == "") { dropped++; continue }
        add(e, type, (acct == "" ? "" : safe(acct)), (right == "" ? "" : safe(right)))
      }
      printf "{\"since\":%s,\"until\":%s,\"events\":[", jstr(iso(since)), jstr(iso(until))
      for (i = 1; i <= n && i <= 500; i++) {
        printf "%s{\"t\":%s,\"type\":%s", (i > 1 ? "," : ""), jstr(iso(ev[i])), jstr(et[i])
        if (ea[i] != "") printf ",\"account\":%s", jstr(ea[i])
        if (er[i] != "") printf ",\"right\":%s", jstr(er[i])
        printf "}"
      }
      printf "],\"dropped\":%s}", jint(dropped)
    }' >"$W/events.json"
  emit events "$(cat "$W/events.json")"
  printf '%s\n' "$until" >"$STATE/s9_since"
  tail -n 2000 "$STATE/s9_seen" >"$STATE/s9_seen.new" && mv "$STATE/s9_seen.new" "$STATE/s9_seen"
}

# -------------------------------------------------------------------- upload

UPLOAD_STATE="unset"

# s3_put FILE KEY: an HTTPS PUT signed with AWS Signature Version 4, to any
# S3-compatible store. Prints the HTTP status. The credential only reaches
# curl through its standard input.
s3_put() {
  local file="$1" key="$2" id sec host path payload amz day scope canonical sts k sig nl
  nl=$'\n'
  id="$(sed -n 's/^id=//p' "$CRED")"
  sec="$(sed -n 's/^secret=//p' "$CRED")"
  host="${C_UPLOAD_ENDPOINT#https://}"
  path="/$C_UPLOAD_BUCKET/$key"
  payload="$(openssl dgst -sha256 <"$file" | awk '{ print $NF }')"
  amz="$(date -u -r "$NOW" '+%Y%m%dT%H%M%SZ')"
  day="${amz%%T*}"
  scope="$day/$C_UPLOAD_REGION/s3/aws4_request"
  canonical="PUT${nl}${path}${nl}${nl}host:${host}${nl}x-amz-content-sha256:${payload}${nl}x-amz-date:${amz}${nl}${nl}host;x-amz-content-sha256;x-amz-date${nl}${payload}"
  sts="AWS4-HMAC-SHA256${nl}${amz}${nl}${scope}${nl}$(printf '%s' "$canonical" | sha256_stdin)"
  k="$(printf '%s' "$day" | hmac_hex "$(printf 'AWS4%s' "$sec" | hex_of)")"
  k="$(printf '%s' "$C_UPLOAD_REGION" | hmac_hex "$k")"
  k="$(printf 's3' | hmac_hex "$k")"
  k="$(printf 'aws4_request' | hmac_hex "$k")"
  sig="$(printf '%s' "$sts" | hmac_hex "$k")"
  printf 'header = "Authorization: AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=%s"\nheader = "x-amz-content-sha256: %s"\nheader = "x-amz-date: %s"\nheader = "Content-Type: application/octet-stream"\nheader = "If-None-Match: *"\n' \
    "$id" "$scope" "$sig" "$payload" "$amz" |
    curl --proto '=https' --tlsv1.2 -sS --max-time 60 -o /dev/null -w '%{http_code}' -X PUT \
      --data-binary "@$file" -K - "https://$host$path" 2>>"$LOG"
}

upload_ok_code() {
  case "$1" in
    200 | 201 | 204) return 0 ;;
    # Already there: this exact segment was stored by an earlier attempt
    # whose answer was lost. The store refuses to overwrite anything.
    412) return 0 ;;
    *) return 1 ;;
  esac
}

record_upload_result() {
  if [ "$1" = ok ]; then
    printf 'ok=%s\nerror=\n' "$NOW" >"$STATE/upload.new"
  else
    printf 'ok=%s\nerror=%s %s\n' "$(sed -n 's/^ok=//p' "$STATE/upload" 2>/dev/null)" "$(iso "$NOW")" "$2" >"$STATE/upload.new"
  fi
  mv "$STATE/upload.new" "$STATE/upload"
}

# Everything not yet sent: one new object per day file per attempt, named by
# its first and last sequence number, so nothing is ever overwritten.
upload_pending() {
  local cursor file day first last code name sent
  if ! upload_configured; then
    UPLOAD_STATE="unset"
    log_line "没有配置上传目标：记录只保存在本机，不上传。"
    return 0
  fi
  if [ "$(stat -f '%Su:%Lp' "$CRED" 2>/dev/null)" != "root:600" ]; then
    UPLOAD_STATE="credential-missing"
    log_line "上传凭证不存在，或不是只有 root 能读（${CRED}）：没有上传。"
    record_upload_result failed "credential"
    return 0
  fi
  UPLOAD_STATE="configured"
  cursor="$(cat "$STATE/uploaded_seq" 2>/dev/null)"
  [[ $cursor =~ ^[0-9]+$ ]] || cursor=0
  for file in "$RECORDS"/*.jsonl; do
    [ -e "$file" ] || continue
    day="$(basename "$file" .jsonl)"
    awk -v c="$cursor" 'match($0, /^\{"v":[0-9]+,"seq":[0-9]+,/) { s = substr($0, 1, RLENGTH); sub(/^.*"seq":/, "", s); sub(/,$/, "", s); if (s + 0 > c) print }' \
      "$file" >"$W/segment"
    [ -s "$W/segment" ] || continue
    first="$(head -n 1 "$W/segment" | sed -n 's/^{"v":[0-9]*,"seq":\([0-9]*\),.*/\1/p')"
    last="$(tail -n 1 "$W/segment" | sed -n 's/^{"v":[0-9]*,"seq":\([0-9]*\),.*/\1/p')"
    name="$(printf '%s/records/%s/%010d-%010d.jsonl' "$C_MACHINE_ID" "$day" "$first" "$last")"
    code="$(s3_put "$W/segment" "$name")"
    if ! upload_ok_code "$code"; then
      log_line "上传失败（HTTP ${code:-无应答}）：${name}。下一次运行时重试。"
      record_upload_result failed "HTTP ${code:-none}"
      return 0
    fi
    cursor="$last"
    printf '%s\n' "$cursor" >"$STATE/uploaded_seq"
  done
  touch "$STATE/uploaded_receipts"
  for file in "$RECEIPTS"/*; do
    [ -e "$file" ] || continue
    name="$(basename "$file")"
    grep -Fxq -- "$name" "$STATE/uploaded_receipts" && continue
    code="$(s3_put "$file" "$C_MACHINE_ID/receipts/$name")"
    if ! upload_ok_code "$code"; then
      log_line "上传失败（HTTP ${code:-无应答}）：${name}。下一次运行时重试。"
      record_upload_result failed "HTTP ${code:-none}"
      return 0
    fi
    printf '%s\n' "$name" >>"$STATE/uploaded_receipts"
  done
  sent="$(cat "$STATE/uploaded_seq" 2>/dev/null)"
  record_upload_result ok
  log_line "已上传到序号 ${sent:-0}。"
}

# --------------------------------------------------------------------- daily

# The SHA-256 of a finished day file, sent to the timestamp services that
# are configured (none by default). Only the 32-byte fingerprint leaves the
# machine, never a record.
stamp_file() {
  local file="$1" day hash ots="unset" tsa="unset" code lines
  day="$(basename "$file" .jsonl)"
  hash="$(openssl dgst -sha256 <"$file" | awk '{ print $NF }')"
  lines="$(wc -l <"$file" | tr -d ' ')"
  printf '%s' "$hash" | xxd -r -p >"$W/digest"
  if [ -n "$C_OTS_URL" ]; then
    code="$(curl --proto '=https' --tlsv1.2 -sS --max-time 60 -o "$W/ots" -w '%{http_code}' -X POST \
      -H 'Accept: application/vnd.opentimestamps.v1' --data-binary "@$W/digest" "${C_OTS_URL%/}/digest" 2>>"$LOG")"
    if [ "$code" = 200 ] && [ -s "$W/ots" ]; then
      # A detached .ots file: header, version 1, SHA-256, the digest, then
      # the calendar's answer. It is completed later with the ots client.
      {
        printf '004f70656e54696d657374616d7073000050726f6f6600bf89e2e884e892940108%s' "$hash" | xxd -r -p
        cat "$W/ots"
      } >"$RECEIPTS/$day.jsonl.ots"
      ots=ok
    else
      ots=failed
      log_line "OpenTimestamps 没有成功（HTTP ${code:-无应答}）：$day"
    fi
  fi
  if [ -n "$C_TSA_URL" ]; then
    # An RFC 3161 request for a SHA-256 digest, with the certificate.
    printf '30390201013031300d060960864801650304020105000420%s0101ff' "$hash" | xxd -r -p >"$W/tsq"
    code="$(curl --proto '=https' --tlsv1.2 -sS --max-time 60 -o "$W/tsr" -w '%{http_code}' -X POST \
      -H 'Content-Type: application/timestamp-query' --data-binary "@$W/tsq" "$C_TSA_URL" 2>>"$LOG")"
    if [ "$code" = 200 ] && [ "$(head -c 1 "$W/tsr" 2>/dev/null | hex_of)" = 30 ]; then
      cp "$W/tsr" "$RECEIPTS/$day.jsonl.tsr"
      tsa=ok
    else
      tsa=failed
      log_line "RFC 3161 时间戳没有成功（HTTP ${code:-无应答}）：$day"
    fi
  fi
  chmod 640 "$RECEIPTS/$day".jsonl.* 2>/dev/null || true
  chown root:admin "$RECEIPTS/$day".jsonl.* 2>/dev/null || true
  emit daily "{\"date\":$(jstr "$day"),\"file_sha256\":$(jstr "$hash"),\"lines\":${lines:-0},\"ots\":\"$ots\",\"tsa\":\"$tsa\"}"
  printf '%s\n' "$day" >>"$STATE/stamped"
}

daily() {
  local today file day cutoff
  today="$(day_of "$NOW")"
  [ "$(cat "$STATE/daily" 2>/dev/null)" != "$today" ] || return 0
  touch "$STATE/stamped"
  for file in "$RECORDS"/*.jsonl; do
    [ -e "$file" ] || continue
    day="$(basename "$file" .jsonl)"
    [ "$day" \< "$today" ] || continue
    grep -Fxq -- "$day" "$STATE/stamped" || stamp_file "$file"
  done
  # Kept for RETENTION_DAYS (90 by default), then deleted.
  cutoff="$(day_of $((NOW - C_RETENTION_DAYS * DAY_SECONDS)))"
  for file in "$RECORDS"/*.jsonl "$RECEIPTS"/*; do
    [ -e "$file" ] || continue
    day="$(basename "$file")"
    day="${day%%.*}"
    if [ "$day" \< "$cutoff" ]; then
      rm -f "$file"
      log_line "已删除超过 ${C_RETENTION_DAYS} 天的本机记录：$(basename "$file")"
    fi
  done
  tail -n 200 "$STATE/stamped" >"$STATE/stamped.new" && mv "$STATE/stamped.new" "$STATE/stamped"
  tail -n 5000 "$LOG" >"$LOG.new" 2>/dev/null && mv "$LOG.new" "$LOG"
  printf '%s\n' "$today" >"$STATE/daily"
}

# ------------------------------------------------------------------- status

# Read by verify.sh and ./monitor.sh status from any account. Times only;
# nothing that was recorded.
write_status() {
  local dir chain_ok=1 file lastline
  dir="$(dirname "$STATUS")"
  mkdir -p "$dir"
  file="$RECORDS/$(day_of "$NOW").jsonl"
  if [ -s "$file" ]; then
    lastline="$(tail -n 1 "$file")"
    [ "$(printf '%s' "$lastline" | sha256_stdin)" = "$LAST_HASH" ] || chain_ok=0
  fi
  {
    printf 'version=%s\n' "$VERSION"
    printf 'machine=%s\n' "$C_MACHINE_ID"
    printf 'last_run_epoch=%s\n' "$NOW"
    printf 'last_seq=%s\n' "$LAST_SEQ"
    printf 'chain_tail_ok=%s\n' "$chain_ok"
    printf 'rejected=%s\n' "$REJECTED"
    printf 'upload=%s\n' "$UPLOAD_STATE"
    printf 'last_upload_ok_epoch=%s\n' "$(sed -n 's/^ok=//p' "$STATE/upload" 2>/dev/null)"
    printf 'last_upload_error=%s\n' "$(sed -n 's/^error=//p' "$STATE/upload" 2>/dev/null)"
    if [ -n "$C_OTS_URL" ] || [ -n "$C_TSA_URL" ]; then printf 'timestamps=configured\n'; else printf 'timestamps=unset\n'; fi
    printf 'detail_options=%s\n' "$(detail_options | tr ' ' ',')"
  } >"$STATUS.new.$$"
  chmod 644 "$STATUS.new.$$"
  mv "$STATUS.new.$$" "$STATUS"
}

# ---------------------------------------------------------------------- run

cmd_run() {
  local hourly_last first_run=0
  require_root run
  load_config
  [ -n "$C_MACHINE_ID" ] || die "配置里没有 MACHINE_ID（${CONFIG}）。"
  mkdir -p "$STATE" "$RECORDS" "$RECEIPTS"
  chmod 700 "$STATE"
  chmod 750 "$RECORDS" "$RECEIPTS"
  chown root:admin "$RECORDS" "$RECEIPTS" 2>/dev/null || true
  NOW="$(now_epoch)"
  # One round at a time; a lock left by a round that died is cleared after
  # 30 minutes.
  if ! mkdir "$STATE/lock" 2>/dev/null; then
    if [ $((NOW - $(stat -f %m "$STATE/lock" 2>/dev/null || echo "$NOW"))) -lt 1800 ]; then
      log_line "上一轮还没有结束，这一轮跳过。"
      exit 0
    fi
    rmdir "$STATE/lock" 2>/dev/null
    mkdir "$STATE/lock" 2>/dev/null || exit 0
  fi
  W="$(mktemp -d "$STATE/work.XXXXXX")"
  trap 'rm -rf "$W"; rmdir "$STATE/lock" 2>/dev/null' EXIT
  load_chain || first_run=1
  [ "$first_run" = 0 ] || [ -e "$STATE/started" ] || {
    emit notice "{\"event\":\"started\",\"version\":$VERSION}"
    touch "$STATE/started"
  }
  RAISED=0
  routine
  alerts
  details
  hourly_last="$(cat "$STATE/hourly" 2>/dev/null)"
  [[ $hourly_last =~ ^[0-9]+$ ]] || hourly_last=0
  daily
  if [ $((NOW - hourly_last)) -ge 3600 ]; then
    hourly_events
    printf '%s\n' "$NOW" >"$STATE/hourly"
    upload_pending
  elif [ "$RAISED" -gt 0 ]; then
    # An alert does not wait for the hour.
    upload_pending
  else
    upload_configured && UPLOAD_STATE=configured
  fi
  write_status
}

# -------------------------------------------------------------------- check

# Schema and hash chain of record files, in order. Exit 1 on any problem.
cmd_check() {
  local options="" quiet=0 file prev_hash="" prev_seq="" n bad=0 line seq prev h first_prev
  while [ $# -gt 0 ]; do
    case "$1" in
      --options) options="$(printf '%s' "${2:-}" | tr ',' ' ')"; shift ;;
      --quiet) quiet=1 ;;
      *) break ;;
    esac
    shift
  done
  [ $# -gt 0 ] || die "用法：v2cc-monitor check [--options A,B] 文件..."
  for file; do
    [ -r "$file" ] || { printf '%s：读不到\n' "$file" >&2; bad=1; continue; }
    # The first "$file" is only the name used in messages.
    # shellcheck disable=SC2094
    if ! validate_records "$file" "$options" <"$file"; then
      bad=1
    fi
    n=0
    first_prev=""
    while IFS= read -r line; do
      n=$((n + 1))
      seq="$(printf '%s' "$line" | sed -n 's/^{"v":[0-9]*,"seq":\([0-9]*\),.*/\1/p')"
      prev="$(printf '%s' "$line" | sed -n 's/.*,"prev":"\([0-9a-f]\{64\}\)","kind":.*/\1/p')"
      [ -n "$first_prev" ] || first_prev="$prev"
      if [ -n "$prev_hash" ] && [ "$prev" != "$prev_hash" ]; then
        printf '%s:%s: 哈希链断开：prev 与上一条记录的 SHA-256 不一致\n' "$file" "$n" >&2
        bad=1
      fi
      if [ -n "$prev_seq" ] && [ "$seq" != "$((prev_seq + 1))" ]; then
        printf '%s:%s: 序号不连续：%s 之后是 %s\n' "$file" "$n" "$prev_seq" "$seq" >&2
        bad=1
      fi
      prev_seq="$seq"
      prev_hash="$(printf '%s' "$line" | sha256_stdin)"
    done <"$file"
    [ "$quiet" = 1 ] || printf '%s：%s 条，第一条的 prev %s，最后一条的 SHA-256 %s\n' "$file" "$n" "${first_prev:-无}" "${prev_hash:-无}"
  done
  return "$bad"
}

case "${1:-}" in
  run) cmd_run ;;
  check) shift; cmd_check "$@" ;;
  configure) shift; cmd_configure "$@" ;;
  set-credential) cmd_set_credential ;;
  *) die "用法：v2cc-monitor run | check [--options A,B] 文件... | configure KEY=VALUE... | set-credential" ;;
esac
