#!/bin/bash
#
# Stub-based tests for the machine monitor (monitor.sh, monitor/). Run with:
# tests/monitor.sh
#
# Same sandbox as tests/run.sh (see tests/lib.sh): a fake Mac whose system
# tools are stubs. The monitor runs as it would under launchd, one round at
# a time, at times the test chooses. Nothing here reads or changes the real
# machine, and nothing is sent anywhere: the upload and timestamp services
# are stubs too.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

# A second, independent check of the records: Perl's own JSON parser and
# the schema file. A field the schema does not list fails it.
SCHEMA_CHECK="$TMP_ROOT/schema-check.pl"
cat >"$SCHEMA_CHECK" <<'EOF'
use strict;
use warnings;
use JSON::PP;
my ($schema, $opts, @files) = @ARGV;
my %on = map { $_ => 1 } split /[ ,]+/, $opts;
my (%allow, %kinds);
open my $s, '<', $schema or die "$schema: $!";
while (<$s>) {
  next if /^\s*(#|$)/;
  my @f = split ' ';
  next if @f >= 4 && !grep { $on{$_} } split /,/, $f[3];
  $allow{"$f[0] $f[1]"} = $f[2];
  $kinds{$f[0]} = 1;
}
my $bad = 0;
sub walk {
  my ($v, $p, $out) = @_;
  if (ref $v eq 'HASH') { walk($v->{$_}, $p eq '' ? $_ : "$p.$_", $out) for keys %$v }
  elsif (ref $v eq 'ARRAY') { walk($_, "$p\[]", $out) for @$v }
  elsif (JSON::PP::is_bool($v)) { push @$out, [$p, 'bool'] }
  elsif (!defined $v) { push @$out, [$p, 'null'] }
  else { push @$out, [$p, JSON::PP->new->allow_nonref->encode($v) =~ /^"/ ? 'string' : 'number'] }
}
for my $file (@files) {
  open my $in, '<', $file or die "$file: $!";
  while (my $line = <$in>) {
    chomp $line;
    my $r = eval { JSON::PP->new->decode($line) };
    if (!$r || ref $r ne 'HASH') { print "$file:$.: not a JSON object\n"; $bad++; next }
    my $kind = $r->{kind} // '';
    if ($kind eq '*' || !$kinds{$kind}) { print "$file:$.: unknown kind $kind\n"; $bad++; next }
    my @leaves;
    walk($r, '', \@leaves);
    for my $l (@leaves) {
      my ($p, $t) = @$l;
      my $want = $p =~ /^data(\.|\[|$)/ ? $allow{"$kind $p"} : $allow{"* $p"};
      if (!defined $want) { print "$file:$.: field not in the schema: $p\n"; $bad++ }
      elsif ($want ne $t) { print "$file:$.: $p is $t, the schema says $want\n"; $bad++ }
    }
  }
}
exit($bad ? 1 : 0);
EOF

schema_check() { /usr/bin/perl "$SCHEMA_CHECK" "$REPO_ROOT/monitor/schema.txt" "$@"; }

# A machine after its one setup run: the monitor installed, first round done.
# T is a time after that round; later rounds are T plus some minutes.
monitor_machine() {
  run bootstrap.sh --customer v2cc --machine-id m-test-01
  [ "$rc" -eq 0 ] || flunk_test "the setup failed"
  : >"$SB/calls.log"
  T=$(($(date -u +%s) + 600))
}
# rounds N STEP: N rounds STEP seconds apart, from T on; T moves past them.
rounds() {
  local i
  for ((i = 0; i < $1; i++)); do
    monitor_round "$T"
    T=$((T + $2))
  done
}
records_of() { monitor_all_records | grep -F "\"kind\":\"$1\""; }
status_of() { sed -n "s/^$1=//p" "$SB/root/var/db/v2cc/monitor-status"; }
config_file() { printf '%s' "$SB/root/Library/Application Support/V2CC/monitor/config"; }
credential_file() { printf '%s' "$SB/root/Library/Application Support/V2CC/monitor/upload-credential"; }
local_time() { date -r "$1" '+%a %b %d %H:%M'; }
log_time() { date -r "$1" '+%Y-%m-%d %H:%M:%S.000000%z'; }
as_root() {
  env -i PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME=/var/root V2CC_SYSROOT="$SB/root" STUB_AS_ROOT=1 \
    LC_ALL=en_US.UTF-8 /bin/bash "$(monitor_prog)" "$@"
}

# --------------------------------------------------------------------- lint

begin_test "lint: the monitor never asks for arguments, environments, contents, screens or keystrokes"
src="$REPO_ROOT/monitor/v2cc-monitor.sh"
# Patterns, not expansions.
# shellcheck disable=SC2016
out="$(grep -nE 'screencapture|pbpaste|HIDIdleTime|IOHIDSystem|log collect|keychain|security find|Library/Safari|\.claude|_history|-o (args|command)|comm,args|[ ,=]args[ ,=]|ps .*(-E|eww)|cat "\$exe"|launchctl (bootout|remove|kill)|kill |pfctl' "$src" | grep -v '^[0-9]*: *#')"
assert_eq "$out" ""
# The only ps call reads the executable's path, never its arguments.
assert_eq "$(grep -c 'ps -axo pid=,user=,%cpu=,rss=,comm=' "$src")" "1"
assert_eq "$(grep -cE '(^|[^a-z])ps ' "$src")" "1"
end_test

begin_test "lint: the schema lists only fields with a known type"
out="$(grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/monitor/schema.txt" | awk '$3 !~ /^(string|number|bool)$/ || NF < 3 || NF > 4')"
assert_eq "$out" ""
end_test

# ------------------------------------------------------------ the one setup

begin_test "monitor: a new machine ends its one setup run with the monitor installed, running and recording"
run bootstrap.sh --customer v2cc --machine-id m-new-01
assert_rc 0
assert_out "[6/7] 监测程序"
assert_out "✓ 监测程序已安装并启动：每 5 分钟记录一次"
assert_out "✓ 机器编号：m-new-01；客户账户：v2cc"
assert_out "✓ 第一轮已完成"
assert_out "✓ 监测程序在运行（launchd 服务 com.v2cc.monitor 已加载）"
assert_out "✓ 哈希链完整，每条记录都只含字段清单里的字段"
assert_out "! 上传目标没有配置：监测记录只保存在本机，没有传到机器外"
assert_out "验证通过"
assert_order '^activate fresh$' '^launchctl bootstrap system '
assert_called "^sudo chown root:wheel $SB/root/Library/LaunchDaemons/com.v2cc.monitor.plist.new$"
assert_called '^sudo launchctl kickstart -k system/com.v2cc.monitor$'
/usr/bin/plutil -lint "$SB/root/Library/LaunchDaemons/com.v2cc.monitor.plist" >/dev/null 2>&1 ||
  flunk_test "the LaunchDaemon is not a valid property list"
grep -q '<string>/usr/bin:/bin:/usr/sbin:/sbin</string>' "$SB/root/Library/LaunchDaemons/com.v2cc.monitor.plist" ||
  flunk_test "the LaunchDaemon does not fix PATH to the system's own tools"
assert_eq "$(mode_of "$SB/root/Library/LaunchDaemons/com.v2cc.monitor.plist")/$(mode_of "$(monitor_prog)")/$(mode_of "$(config_file)")" "644/755/644"
assert_eq "$(mode_of "$(monitor_records)")/$(mode_of "$(monitor_state)")" "750/700"
assert_eq "$(sed -n 's/^MACHINE_ID=//p' "$(config_file)")/$(sed -n 's/^CUSTOMER=//p' "$(config_file)")" "m-new-01/v2cc"
assert_eq "$(records_of routine | wc -l | tr -d ' ')" "1"
assert_eq "$(status_of upload)" "unset"
# Nothing was sent anywhere.
assert_not_called '^curl https://(store|ots|tsa)\.test'
end_test

begin_test "monitor: rerunning the setup leaves the monitor alone"
run bootstrap.sh --customer v2cc
: >"$SB/calls.log"
run bootstrap.sh --customer v2cc
assert_rc 0
assert_out "监测程序已安装、是这一版，并且在运行"
assert_not_called '^sudo'
end_test

begin_test "monitor: a dry run of the setup only names the monitor"
run bootstrap.sh --customer v2cc --dry-run
assert_rc 0
assert_out "[演练] 将安装并启动监测程序"
assert_not_called '^sudo'
assert_missing "$SB/root/Library/LaunchDaemons/com.v2cc.monitor.plist"
end_test

begin_test "monitor: a machine without a random name keeps the one it was given"
monitor_machine
run monitor.sh install
assert_rc 0
assert_out "机器编号 m-test-01"
run monitor.sh install --machine-id 'bad name'
assert_rc_nonzero
assert_out "机器编号「bad name」只能用字母"
end_test

begin_test "monitor: install, configure and uninstall refuse the customer account and root"
set_running_system fresh
become v2cc
run monitor.sh install
assert_rc_nonzero
assert_out "监测程序不能在客户账户 v2cc 里安装"
run monitor.sh uninstall
assert_rc_nonzero
assert_out "不能在客户账户 v2cc 里卸载"
become v2ccops
echo 0 >"$SB/state/uid"
run monitor.sh install
assert_rc_nonzero
assert_out "不要使用 sudo 或 root"
assert_not_called '^sudo'
end_test

begin_test "monitor: status works from any account and changes nothing"
monitor_machine
become v2cc
run monitor.sh status
assert_rc 0
assert_out "launchd 服务 com.v2cc.monitor：已加载"
assert_out "机器编号：m-test-01"
assert_out "上传：没有配置上传目标"
assert_out "可选的加记（可疑程序的连接地址、文件指纹）：关闭"
assert_not_called '^sudo'
end_test

# ------------------------------------------------------------------ records

begin_test "monitor: every record has only the fields the schema lists, checked by a second parser"
monitor_machine
now=$T
local_login=$((now + 1200))
printf 'v2cc       console                         %s   still logged in\n' "$(local_time "$local_login")" >"$SB/state/mon/last"
rounds 13 300
for file in "$(monitor_records)"/*.jsonl; do
  out="$(schema_check "" "$file")" || flunk_test "a record has a field outside the schema: $out"
done
for kind in notice routine events alert; do
  [ -n "$(records_of "$kind")" ] || flunk_test "no $kind record was written"
done
# The second parser is not just agreeing: a field it does not know fails.
monitor_all_records | tail -n 1 | sed 's/"data":{/"data":{"extra":1,/' >"$SB/state/extra.jsonl"
! out="$(schema_check "" "$SB/state/extra.jsonl")" ||
  flunk_test "the second parser accepted a field outside the schema"
assert_out "field not in the schema: data.extra"
! out="$(as_root check "$SB/state/extra.jsonl" 2>&1)" ||
  flunk_test "the monitor's own check accepted a field outside the schema"
end_test

begin_test "monitor: a record with a field outside the schema is not written"
monitor_machine
# As if a later version of the program produced a field nobody approved.
grep -v 'data.s2.gpu_util' "$SB/root/Library/Application Support/V2CC/monitor/schema.txt" >"$SB/state/schema"
cp "$SB/state/schema" "$SB/root/Library/Application Support/V2CC/monitor/schema.txt"
before="$(records_of routine | wc -l | tr -d ' ')"
rounds 1 300
assert_eq "$(records_of routine | wc -l | tr -d ' ')" "$before"
records_of notice | tail -n 1 | grep -q '"event":"record_rejected","about":"routine"' ||
  flunk_test "no notice says the routine record was rejected"
assert_eq "$(status_of rejected)" "1"
run verify.sh
assert_rc 1
assert_out "✗ 上一轮有 1 条记录因为含有字段清单以外的内容没有写入"
end_test

begin_test "monitor: no file contents, paths, arguments, addresses, web addresses or hardware addresses"
monitor_machine
printf '%s\n' '{"timestamp":"'"$(log_time $((T + 60)))"'","processImagePath":"\/usr\/sbin\/sshd","eventMessage":"Opened https:\/\/example.com\/PRIVATE-MARK for v2cc"}' >"$SB/state/mon/logshow"
rounds 13 300
all="$(monitor_all_records)"
for leak in PRIVATE-MARK 203.0.113.7 160.79.104.10 2607:6bc0 198.51.100.9 aa:bb:cc https:// /Users/ /Applications/ example.com; do
  ! printf '%s' "$all" | grep -Fq -- "$leak" || flunk_test "a record contains: $leak"
done
# Names only: the auto-start file is there by name, its contents are not.
printf '%s' "$all" | grep -Fq '"customer_agents":["com.example.helper.plist"]' ||
  flunk_test "the customer's auto-start item is not recorded by name"
printf '%s' "$all" | grep -Fq '"name":"devserver"' || flunk_test "the program is not recorded by name"
# ps is only ever asked for the executable, never arguments or environment.
assert_not_called '^ps .*(args|command|-E|eww)'
assert_called '^ps -axo pid=,user=,%cpu=,rss=,comm=$'
assert_not_called '^log collect'
end_test

begin_test "monitor: S9 system events keep only time, type, account and right"
monitor_machine
e=$((T + 3000))
{
  printf 'v2cc       ttys000                         %s   still logged in\n' "$(local_time "$e")"
  printf 'v2cc       console                         %s - %s  (00:10)\n' "$(local_time "$e")" "$(date -r $((e + 600)) '+%H:%M')"
  printf 'reboot time                                %s\n' "$(local_time $((e - 60)))"
} >"$SB/state/mon/last"
printf '%s Wake                	DarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC\n%s Assertions          	PID 1(PRIVATE-MARK) Created\n' \
  "$(date -r "$e" '+%Y-%m-%d %H:%M:%S %z')" "$(date -r "$e" '+%Y-%m-%d %H:%M:%S %z')" >"$SB/state/mon/pmsetlog"
{
  printf '{"timestamp":"%s","processImagePath":"\\/usr\\/libexec\\/sshd-session","eventMessage":"Accepted publickey for v2cc from 198.51.100.9 port 50000 ssh2"}\n' "$(log_time "$e")"
  printf '{"timestamp":"%s","processImagePath":"\\/System\\/Library\\/authd","eventMessage":"Succeeded authorizing right '"'"'system.preferences'"'"' by client '"'"'\\/Applications\\/PRIVATE-MARK.app'"'"' [1]"}\n' "$(log_time "$e")"
  printf '{"timestamp":"%s","processImagePath":"\\/usr\\/sbin\\/screensharingd","eventMessage":"Authentication: FAILED :: User Name: v2ccops :: Viewer Address: 198.51.100.9 :: Type: DH"}\n' "$(log_time "$e")"
  printf '{"timestamp":"%s","processImagePath":"\\/usr\\/sbin\\/sshd","eventMessage":"something else entirely"}\n' "$(log_time "$e")"
} >"$SB/state/mon/logshow"
T=$((e + 600))
rounds 1 300
ev="$(records_of events | tail -n 1)"
for want in '"type":"login","account":"v2cc"' '"type":"logout","account":"v2cc"' '"type":"reboot"' '"type":"wake"' \
  '"type":"ssh_accepted","account":"v2cc"' '"type":"auth_succeeded","right":"system.preferences"' \
  '"type":"screensharing_failed","account":"v2ccops"' '"dropped":1'; do
  printf '%s' "$ev" | grep -Fq -- "$want" || flunk_test "the event record lacks: $want"
done
# One console login; the Terminal window (ttys000) is not an event.
assert_eq "$(printf '%s' "$ev" | grep -o '"type":"login"' | wc -l | tr -d ' ')" "1"
! printf '%s' "$ev" | grep -Eq 'PRIVATE-MARK|198\.51|Assertions|DarkWake to' || flunk_test "an event carries text beyond its fixed fields"
assert_called "^log show --start .* --style ndjson --predicate "
# The next hour does not repeat them.
T=$((T + 3600))
rounds 1 300
! records_of events | tail -n 1 | grep -Fq '"type":"reboot"' || flunk_test "the next hour repeated an event"
end_test

# ------------------------------------------------------------------- alerts

begin_test "monitor: alerts are raised and cleared, and only notify"
monitor_machine
cat >"$SB/state/mon/ps" <<'EOF'
  210 v2cc              95.0  50000 /Users/v2cc/p/bin/devserver
  211 v2cc               0.5  20000 /Users/v2cc/.local/bin/claude
  212 v2cc               0.1   9000 /opt/homebrew/bin/node
  213 v2cc               0.0   3000 /Users/v2cc/Downloads/frpc
  214 v2cc              99.0   3000 /usr/bin/clang
EOF
echo /opt/homebrew/bin/node >"$SB/state/mon/exe.212"
mkdir -p "$CH/.local/bin" && : >"$CH/.local/bin/claude"
echo "$CH/.local/bin/claude" >"$SB/state/mon/exe.211"
rounds 25 300
alerts="$(records_of alert)"
for want in '"alert":"external_listen","state":"raised","category":"H","name":"devserver","user":"v2cc"' \
  '"alert":"name_list","state":"raised","category":"H","name":"frpc","user":"v2cc"' \
  '"alert":"api_direct","state":"raised","category":"C","name":"node","user":"v2cc"' \
  '"alert":"api_direct_exposure","state":"raised","category":"C"' \
  '"alert":"cpu_sustained","state":"raised","category":"F","name":"devserver","user":"v2cc","value":95'; do
  printf '%s' "$alerts" | grep -Fq -- "$want" || flunk_test "no alert: $want"
done
# Claude Code is on the allowlist by its signature; clang is a normal busy tool.
! printf '%s' "$alerts" | grep -Fq '"alert":"api_direct","state":"raised","category":"C","name":"claude"' || flunk_test "Claude Code raised a direct-API alert"
! printf '%s' "$alerts" | grep -Fq '"name":"clang"' || flunk_test "clang raised an alert"
records_of routine | tail -n 1 | grep -Fq '"name":"claude","user":"v2cc","conns":1,"remotes":1,"syn_sent":0,"ports":[{"port":443,"n":1}],"ports_other":0,"api":1,"api_signer":"Q6L2SF6YDW","api_allowed":true' ||
  flunk_test "the connection summary does not show Claude Code as allowed by its signature"
# A sustained alert is raised once, not every round.
assert_eq "$(printf '%s\n' "$alerts" | grep -c '"alert":"external_listen","state":"raised"')" "1"
# The listener goes away: the alert is cleared.
grep -v '3000' "$SB/state/mon/lsof" >"$SB/state/mon/lsof.new" && mv "$SB/state/mon/lsof.new" "$SB/state/mon/lsof"
rounds 1 300
records_of alert | grep -Fq '"alert":"external_listen","state":"cleared","category":"H","name":"devserver"' ||
  flunk_test "the external listener alert was not cleared"
# Nothing is stopped, blocked or changed because of an alert.
assert_not_called '^(kill|pkill|pfctl|launchctl (bootout|remove|disable)|sudo)'
end_test

begin_test "monitor: a gap in the records, a changed component and a connection burst raise alerts"
monitor_machine
rounds 1 300
T=$((T + 3600))
awk 'BEGIN { for (i = 1; i <= 501; i++) printf "f%d\nPTCP\nn10.0.0.2:%d->198.18.%d.%d:22\nTST=SYN_SENT\n", i + 100, 40000 + i, int(i / 250), i % 250 + 1 }' >"$SB/state/mon/lsof.burst"
{ printf 'p210\ncdevserver\nLv2cc\n'; cat "$SB/state/mon/lsof.burst"; } >"$SB/state/mon/lsof"
sed 's/activated enabled/activated waiting for user/' "$SB/state/mon/sysext" >"$SB/state/mon/sysext.new" && mv "$SB/state/mon/sysext.new" "$SB/state/mon/sysext"
rounds 1 300
alerts="$(records_of alert)"
printf '%s' "$alerts" | grep -Fq '"alert":"heartbeat_gap","state":"raised","value":3900' || flunk_test "no heartbeat gap alert"
printf '%s' "$alerts" | grep -Fq '"alert":"component_changed","state":"raised","category":"G","check":"sysext"' || flunk_test "no component change alert"
printf '%s' "$alerts" | grep -Fq '"alert":"connection_burst","state":"raised","category":"A2","name":"devserver","user":"v2cc","value":501' || flunk_test "no connection burst alert"
records_of routine | tail -n 1 | grep -Fq '"syn_sent":501' || flunk_test "half-open connections are not counted"
end_test

# ------------------------------------------------------------------- upload

begin_test "monitor: without an upload target the records stay on the machine, and it says so"
monitor_machine
rounds 13 300
assert_not_called '^curl'
assert_eq "$(status_of upload)" "unset"
records_of routine | tail -n 1 | grep -Fq '"upload_configured":false' || flunk_test "the record does not say it is not uploaded"
grep -Fq '没有配置上传目标：记录只保存在本机，不上传。' "$(monitor_state)/monitor.log" || flunk_test "the log does not say it"
run verify.sh
assert_rc 0
assert_out "! 上传目标没有配置：监测记录只保存在本机，没有传到机器外。"
assert_out "! 每日时间戳没有配置"
end_test

begin_test "monitor: records go to an S3-compatible store, the credential is never shown"
monitor_machine
run monitor.sh configure --upload-endpoint https://store.test --upload-bucket v2cc-records
assert_rc 0
assert_out "UPLOAD_ENDPOINT=https://store.test"
TTY_DIALOG="Access Key ID=AKIDEXAMPLE12345|Secret Access Key=SECRETvalue0123456789/abc"
run_tty monitor.sh configure --upload-credential
assert_rc 0
assert_out "上传凭证已保存"
assert_no_out "SECRETvalue"
assert_eq "$(cat "$(credential_file)")" "$(printf 'id=AKIDEXAMPLE12345\nsecret=SECRETvalue0123456789/abc')"
assert_eq "$(mode_of "$(credential_file)")" "600"
rounds 1 300
uploaded="$(find "$SB/state/uploads/v2cc-records/m-test-01/records" -name '*.jsonl' | sort)"
[ -n "$uploaded" ] || flunk_test "nothing was uploaded"
case "$uploaded" in */records/????-??-??/0000000001-00000000??.jsonl*) ;; *) flunk_test "unexpected object name: $uploaded" ;; esac
grep -q '^header = "Authorization: AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE12345/[0-9]\{8\}/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=[0-9a-f]\{64\}"$' \
  "$(printf '%s\n' "$uploaded" | head -n 1).headers" || flunk_test "the upload is not signed with Signature Version 4"
grep -q '^header = "If-None-Match: \*"$' "$(printf '%s\n' "$uploaded" | head -n 1).headers" || flunk_test "the upload may overwrite"
assert_eq "$(status_of upload)" "configured"
[ -n "$(status_of last_upload_ok_epoch)" ] || flunk_test "no successful upload recorded"
# The secret is in no log, record, status, call or command line.
for f in "$SB/calls.log" "$(monitor_state)/monitor.log" "$SB/root/var/db/v2cc/monitor-status" "$SB/state/monitor_runs.log" $uploaded "$(printf '%s\n' "$uploaded" | head -n 1).headers"; do
  ! grep -Fq SECRETvalue "$f" 2>/dev/null || flunk_test "the secret is in $f"
done
# The next upload starts where the last one ended, as a new object.
T=$((T + 3600))
rounds 1 300
assert_eq "$(cat "$SB/state/uploads/v2cc-records/m-test-01/records"/*/*.jsonl)" "$(monitor_all_records)"
run verify.sh
assert_out "✓ 记录已上传到机器外"
end_test

begin_test "monitor: a failed upload is retried and verify says so"
monitor_machine
run monitor.sh configure --upload-endpoint https://store.test --upload-bucket v2cc-records
printf 'AKIDEXAMPLE12345\nSECRETvalue0123456789/abc\n' | as_root set-credential >/dev/null
echo 503 >"$SB/state/upload_code"
rounds 1 300
assert_eq "$(status_of upload)" "configured"
case "$(status_of last_upload_error)" in *"HTTP 503") ;; *) flunk_test "the failure is not recorded" ;; esac
run verify.sh
assert_rc 1
assert_out "✗ 记录最近 2 小时没有上传成功（最近一次失败："
rm -f "$SB/state/upload_code"
T=$((T + 3600))
rounds 1 300
assert_eq "$(cat "$SB/state/uploads/v2cc-records/m-test-01/records"/*/*.jsonl)" "$(monitor_all_records)"
# A credential anyone but root could read is not used.
echo "root:644" >"$SB/state/credential_mode"
T=$((T + 3600))
rounds 1 300
assert_eq "$(status_of upload)" "credential-missing"
run verify.sh
assert_out "✗ 已配置上传目标，但上传凭证不存在，或不是只有 root 能读"
end_test

# --------------------------------------------------------- chain and stamps

begin_test "monitor: a changed record breaks the hash chain, and check and verify find it"
monitor_machine
rounds 3 300
out="$(as_root check "$(monitor_records)"/*.jsonl 2>&1)"
assert_eq "$?" "0"
set -- "$(monitor_records)"/*.jsonl
file="$1"
sed -i '' '2s/"cpu_user":[0-9.]*/"cpu_user":0.0/' "$file"
! out="$(as_root check "$file" 2>&1)" ||
  flunk_test "check accepted a changed record"
assert_out "哈希链断开"
run verify.sh
assert_rc 1
assert_out "✗ 记录的哈希链或字段检查没有通过"
end_test

begin_test "monitor: each day's file gets a fingerprint, sent to timestamp services only when configured"
monitor_machine
day1="$(date -u -r "$T" '+%Y-%m-%d')"
rounds 1 300
T=$(($(date -u -j -f '%Y-%m-%d %H:%M:%S' "$day1 00:00:00" +%s) + 86400 + 60))
rounds 1 300
sum="$(openssl dgst -sha256 <"$(monitor_records)/$day1.jsonl" | awk '{ print $NF }')"
records_of daily | grep -Fq "\"date\":\"$day1\",\"file_sha256\":\"$sum\"" || flunk_test "no daily fingerprint of $day1"
records_of daily | grep -Fq '"ots":"unset","tsa":"unset"' || flunk_test "unset timestamp services were used"
assert_not_called '^curl'
run monitor.sh configure --ots-url https://ots.test --tsa-url https://tsa.test/tsr
assert_rc 0
day2="$(date -u -r "$T" '+%Y-%m-%d')"
T=$((T + 86400))
rounds 1 300
records_of daily | grep -Fq "\"date\":\"$day2\"" || flunk_test "no daily fingerprint of $day2"
records_of daily | tail -n 1 | grep -Fq '"ots":"ok","tsa":"ok"' || flunk_test "the timestamps were not taken"
sum="$(openssl dgst -sha256 <"$(monitor_records)/$day2.jsonl" | awk '{ print $NF }')"
# Only the 32-byte fingerprint left the machine.
assert_eq "$(od -An -v -tx1 "$SB/state/ots_digest" | tr -d ' \n')" "$sum"
assert_eq "$(od -An -v -tx1 "$SB/state/tsa_request" | tr -d ' \n')" "30390201013031300d060960864801650304020105000420${sum}0101ff"
openssl asn1parse -inform DER -in "$SB/state/tsa_request" >/dev/null 2>&1 || flunk_test "the RFC 3161 request is not valid DER"
assert_eq "$(head -c 33 "$SB/root/Library/Application Support/V2CC/monitor/receipts/$day2.jsonl.ots" | od -An -v -tx1 | tr -d ' \n')" \
  "004f70656e54696d657374616d7073000050726f6f6600bf89e2e884e892940108"
assert_exists "$SB/root/Library/Application Support/V2CC/monitor/receipts/$day2.jsonl.tsr"
end_test

begin_test "monitor: records are kept 90 days, then deleted from the machine"
monitor_machine
old="$(date -u -r $((T - 91 * 86400)) '+%Y-%m-%d')"
kept="$(date -u -r $((T - 89 * 86400)) '+%Y-%m-%d')"
: >"$(monitor_records)/$old.jsonl"
: >"$(monitor_records)/$kept.jsonl"
echo "$old" >>"$(monitor_state)/stamped"
echo "$kept" >>"$(monitor_state)/stamped"
T=$((T + 86400))
rounds 1 300
assert_missing "$(monitor_records)/$old.jsonl"
assert_exists "$(monitor_records)/$kept.jsonl"
end_test

# ------------------------------------------------------------------ options

begin_test "monitor: recording beyond the website's sentence is off unless turned on"
monitor_machine
cat >"$SB/state/mon/ps" <<'EOF'
  213 v2cc               0.0   3000 /Users/v2cc/Downloads/frpc
EOF
printf 'p213\ncfrpc\nLv2cc\nf7\nPTCP\nn192.168.1.20:52000->203.0.113.7:7000\nTST=ESTABLISHED\n' >"$SB/state/mon/lsof"
rounds 2 300
records_of alert | grep -Fq '"name":"frpc"' || flunk_test "no alert about frpc"
[ -z "$(records_of detail)" ] || flunk_test "a detail record was written with the options off"
! monitor_all_records | grep -Fq 203.0.113.7 || flunk_test "an address was recorded with the options off"
assert_eq "$(sed -n 's/^DETAIL_[A-Z]*=//p' "$(config_file)")" ""
# The owner decides to turn them on.
run monitor.sh configure --detail-addresses on --detail-fingerprint on
assert_rc 0
printf 'binary bytes\n' >"$SB/state/frpc-binary"
echo "$SB/state/frpc-binary" >"$SB/state/mon/exe.213"
cat >>"$SB/state/mon/ps" <<'EOF'
  214 v2cc               0.0   3000 /Users/v2cc/Downloads/ngrok
EOF
rounds 2 300
detail="$(records_of detail | tail -n 1)"
printf '%s' "$detail" | grep -Fq '"alert":"name_list","name":"ngrok","user":"v2cc"' || flunk_test "no detail record for the new alert"
assert_eq "$(status_of detail_options)" "DETAIL_ADDRESSES,DETAIL_FINGERPRINT"
run verify.sh
assert_out "! 已开启超出网站那句话的加记"
# Default records only pass the schema without the options; detail records need them.
set -- "$(monitor_records)"/*.jsonl
for file; do :; done
! out="$(schema_check "" "$file")" ||
  flunk_test "detail records passed the default schema"
out="$(schema_check "DETAIL_ADDRESSES,DETAIL_FINGERPRINT" "$file")" || flunk_test "detail records fail the schema with the options: $out"
end_test

begin_test "monitor: with the options on, the program an alert is about gets its addresses and fingerprint"
monitor_machine
run monitor.sh configure --detail-addresses on --detail-fingerprint on
cat >"$SB/state/mon/ps" <<'EOF'
  213 v2cc               0.0   3000 /Users/v2cc/Downloads/frpc
  300 v2ccops            0.0   1000 /bin/zsh
EOF
printf 'p213\ncfrpc\nLv2cc\nf7\nPTCP\nn192.168.1.20:52000->203.0.113.7:7000\nTST=ESTABLISHED\np300\nczsh\nLv2ccops\nf3\nPTCP\nn192.168.1.20:52009->192.0.2.44:443\nTST=ESTABLISHED\n' >"$SB/state/mon/lsof"
printf 'binary bytes\n' >"$SB/state/frpc-binary"
echo "$SB/state/frpc-binary" >"$SB/state/mon/exe.213"
rounds 1 300
detail="$(records_of detail | tail -n 1)"
sum="$(openssl dgst -sha256 <"$SB/state/frpc-binary" | awk '{ print $NF }')"
printf '%s' "$detail" | grep -Fq "\"data\":{\"alert\":\"name_list\",\"name\":\"frpc\",\"user\":\"v2cc\",\"remotes\":[{\"addr\":\"203.0.113.7\",\"port\":7000,\"n\":1}],\"sha256\":\"$sum\"}" ||
  flunk_test "unexpected detail record: $detail"
# Nothing about any other program.
! monitor_all_records | grep -Fq 192.0.2.44 || flunk_test "another program's address was recorded"
# After 24 hours the window closes.
T=$((T + 86400))
before="$(records_of detail | wc -l | tr -d ' ')"
rounds 1 300
assert_eq "$(records_of detail | wc -l | tr -d ' ')" "$before"
end_test

# ---------------------------------------------------------------- uninstall

begin_test "monitor: uninstall stops it and keeps the records unless asked"
monitor_machine
printf 'AKIDEXAMPLE12345\nSECRETvalue0123456789/abc\n' | as_root set-credential >/dev/null
RUN_ENV="V2CC_ASSUME_YES=1"
run monitor.sh uninstall
assert_rc 0
assert_called '^sudo launchctl bootout system/com.v2cc.monitor$'
assert_missing "$SB/root/Library/LaunchDaemons/com.v2cc.monitor.plist"
assert_missing "$(monitor_prog)"
assert_missing "$(credential_file)"
assert_exists "$(monitor_records)"
assert_out "本机的记录保留在"
run verify.sh
assert_rc 1
assert_out "✗ 监测程序没有安装"
run monitor.sh install
assert_rc 0
assert_out "机器编号：m-test-01"
RUN_ENV="V2CC_ASSUME_YES=1"
run monitor.sh uninstall --delete-records
assert_rc 0
assert_missing "$SB/root/Library/Application Support/V2CC/monitor"
end_test

begin_test "monitor: verify reports a monitor that stopped"
monitor_machine
rm -f "$SB/state/monitor_loaded"
sed -i '' "s/^last_run_epoch=.*/last_run_epoch=$(($(date -u +%s) - 3600))/" "$SB/root/var/db/v2cc/monitor-status"
run verify.sh
assert_rc 1
assert_out "✗ 监测程序没有在运行：launchd 服务 com.v2cc.monitor 没有加载"
assert_out "✗ 最近一次记录在 60 分钟前，超过 15 分钟"
end_test

printf '\n%s tests, %s failed\n' "$tests_run" "$tests_failed"
[ "$tests_failed" -eq 0 ]
