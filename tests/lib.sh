#!/bin/bash
# shellcheck shell=bash
#
# Sandbox and stubs for tests/run.sh.
#
# Every test gets its own fake machine: a fake filesystem root (V2CC_SYSROOT),
# a fake home, a private copy of the scripts, and a directory of stub
# commands placed first on PATH. sudo, installers, nix, softwareupdate and
# friends are all stubs that only touch the sandbox and append what they
# were asked to do to calls.log. Nothing here can change the real machine.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

tests_run=0
tests_failed=0
current_test=""
current_failed=0
SB=""
out=""
rc=0

begin_test() {
  current_test="$1"
  current_failed=0
  tests_run=$((tests_run + 1))
  new_sandbox
}

end_test() {
  if [ "$current_failed" -eq 0 ]; then
    printf 'ok   %s\n' "$current_test"
  else
    tests_failed=$((tests_failed + 1))
    printf 'FAIL %s\n' "$current_test"
    printf -- '---- output ----\n%s\n---- calls ----\n%s\n----\n' \
      "$out" "$(cat "$SB/calls.log" 2>/dev/null)"
  fi
}

flunk_test() {
  current_failed=1
  printf '     assertion failed: %s\n' "$1"
}

assert_rc() { [ "$rc" -eq "$1" ] || flunk_test "exit code $rc, expected $1"; }
assert_rc_nonzero() { [ "$rc" -ne 0 ] || flunk_test "exit code 0, expected failure"; }
assert_out() { printf '%s' "$out" | grep -Fq -- "$1" || flunk_test "output lacks: $1"; }
assert_no_out() { ! printf '%s' "$out" | grep -Fq -- "$1" || flunk_test "output has: $1"; }
assert_called() { grep -Eq -- "$1" "$SB/calls.log" || flunk_test "not called: $1"; }
assert_not_called() { ! grep -Eq -- "$1" "$SB/calls.log" || flunk_test "called: $1"; }
assert_exists() { [ -e "$1" ] || flunk_test "missing: $1"; }
assert_missing() { [ ! -e "$1" ] || flunk_test "should not exist: $1"; }
assert_eq() { [ "$1" = "$2" ] || flunk_test "got '$1', expected '$2'"; }

# Line number of the first call matching $1, to assert ordering.
call_line() { grep -En -- "$1" "$SB/calls.log" | head -n 1 | cut -d: -f1; }
assert_order() {
  local a b
  a="$(call_line "$1")"
  b="$(call_line "$2")"
  if [ -z "$a" ] || [ -z "$b" ] || [ "$a" -ge "$b" ]; then
    flunk_test "expected '$1' before '$2'"
  fi
}

write_stub() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/bin/bash\nSB=%q\n' "$SB"
    cat
  } >"$path"
  chmod +x "$path"
}

new_sandbox() {
  SB="$TMP_ROOT/sb$tests_run"
  mkdir -p "$SB/root/tmp" "$SB/root/run" "$SB/root/nix/var/nix/profiles" \
    "$SB/home" "$SB/state" "$SB/store" "$SB/bin" "$SB/late" "$SB/repo"
  : >"$SB/calls.log"
  cp -R "$REPO_ROOT"/*.sh "$REPO_ROOT/lib" "$REPO_ROOT/tools" "$REPO_ROOT/flake.nix" "$SB/repo/"

  # A blank Apple Silicon Mac, in a fresh administrator account named v2cc.
  echo v2cc >"$SB/state/user"
  echo 502 >"$SB/state/uid"
  echo "staff admin" >"$SB/state/groups"
  printf 'howard\nv2cc\n' >"$SB/state/known_users"
  echo arm64 >"$SB/state/arch"
  echo 27.2 >"$SB/state/macos"
  echo 200 >"$SB/state/free_gb"
  echo v2cc >"$SB/state/brew_owner"

  write_stub "$SB/bin/uname" <<'EOF'
case "$1" in -s) echo Darwin ;; -m) cat "$SB/state/arch" ;; esac
EOF
  write_stub "$SB/bin/id" <<'EOF'
case "$*" in
  -un) cat "$SB/state/user" ;;
  -u) cat "$SB/state/uid" ;;
  -Gn) cat "$SB/state/groups" ;;
  *) for name; do :; done
     grep -Fxq -- "$name" "$SB/state/known_users" && echo 501 ;;
esac
EOF
  write_stub "$SB/bin/sw_vers" <<'EOF'
cat "$SB/state/macos"
EOF
  write_stub "$SB/bin/df" <<'EOF'
printf 'Filesystem 1G-blocks Used Available Capacity\n/dev/disk3s5 460 100 %s 30%%\n' "$(cat "$SB/state/free_gb")"
EOF
  write_stub "$SB/bin/sleep" <<'EOF'
echo "sleep $*" >>"$SB/calls.log"
EOF
  write_stub "$SB/bin/xcode-select" <<'EOF'
echo "xcode-select $*" >>"$SB/calls.log"
clt="$SB/root/Library/Developer/CommandLineTools"
case "$1" in
  -p) [ -e "$clt/usr/bin/git" ] && echo /Library/Developer/CommandLineTools || exit 2 ;;
  --install) mkdir -p "$clt/usr/bin" && : >"$clt/usr/bin/git" ;;
esac
EOF
  write_stub "$SB/bin/softwareupdate" <<'EOF'
echo "softwareupdate $*" >>"$SB/calls.log"
clt="$SB/root/Library/Developer/CommandLineTools"
case "$1" in
  -l) [ -e "$SB/state/no_clt_label" ] || printf '* Label: Command Line Tools for Xcode-26.1\n\tTitle: Command Line Tools\n' ;;
  -i) [ ! -e "$SB/state/clt_softwareupdate_fails" ] || exit 1
      mkdir -p "$clt/usr/bin" && : >"$clt/usr/bin/git" ;;
esac
EOF
  # sudo: record, drop sudo's own flags, run the command inside the sandbox.
  write_stub "$SB/bin/sudo" <<'EOF'
echo "sudo $*" >>"$SB/calls.log"
while [ $# -gt 0 ]; do
  case "$1" in
    -v) exit 0 ;;
    -H | -n) shift ;;
    -u) shift 2 ;;
    --set-home) shift ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || exit 0
exec "$@"
EOF
  write_stub "$SB/bin/curl" <<'EOF'
dest="" url="" config_on_stdin=0 dump_headers=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift ;;
    -K) [ "$2" = "-" ] && config_on_stdin=1; shift ;;
    -D) dump_headers=1; shift ;;
    --proto) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "curl $url" >>"$SB/calls.log"
[ "$config_on_stdin" = 0 ] || cat >"$SB/state/curl_stdin"
[ ! -e "$SB/state/network_down" ] || exit 6
case "$url" in
  https://api.github.com/*)
    [ "$dump_headers" = 1 ] &&
      printf 'HTTP/2 302\r\nlocation: https://codeload.github.com/jasontopia/v2cc-mac-setup/legacy.tar.gz/%s?token=STUBSHORTLIVED\r\n\r\n' "${url##*/}"
    ;;
  https://codeload.github.com/*) cp "$SB/state/bundle.tgz" "$dest" ;;
  *nix-installer-aarch64-darwin)
    { printf '#!/bin/bash\n# STUB-PAYLOAD nix %s\nSB=%q\n' "$(cat "$SB/state/nix_payload" 2>/dev/null)" "$SB"
      cat "$SB/late/nix-installer"; } >"$dest" ;;
  *Homebrew/install/*)
    { printf '#!/bin/bash\n# STUB-PAYLOAD brew\nSB=%q\n' "$SB"; cat "$SB/late/brew-installer"; } >"$dest" ;;
  https://claude.ai/install.sh)
    { printf '#!/bin/bash\nSB=%q\n' "$SB"; cat "$SB/late/claude-installer"; } >"$dest" ;;
  *) exit 22 ;;
esac
EOF
  # shasum: stub payloads hash to the pinned values unless marked tampered.
  write_stub "$SB/bin/shasum" <<'EOF'
for file; do :; done
if grep -q '^# STUB-PAYLOAD nix tampered' "$file" 2>/dev/null; then
  echo "0000000000000000000000000000000000000000000000000000000000000000  $file"
elif grep -q '^# STUB-PAYLOAD nix' "$file" 2>/dev/null; then
  echo "$(sed -n 's/^DETERMINATE_NIX_SHA256="\(.*\)"$/\1/p' "$SB/repo/lib/common.sh")  $file"
elif grep -q '^# STUB-PAYLOAD brew' "$file" 2>/dev/null; then
  echo "$(sed -n 's/^HOMEBREW_INSTALL_SHA256="\(.*\)"$/\1/p' "$SB/repo/lib/common.sh")  $file"
else
  exec /usr/bin/shasum "$@"
fi
EOF
  write_stub "$SB/bin/stat" <<'EOF'
if [ "$1" = "-f" ] && [ "$2" = "%Su" ]; then cat "$SB/state/brew_owner"; else exec /usr/bin/stat "$@"; fi
EOF
  write_stub "$SB/bin/launchctl" <<'EOF'
echo "launchctl $*" >>"$SB/calls.log"
[ "$1" != "print" ] || [ -e "$SB/root/run/current-system" ]
EOF
  write_stub "$SB/bin/security" <<'EOF'
[ -e "$SB/state/keychain_github" ] || exit 44
EOF

  # The real zsh, so startup-file behaviour is the real thing. -d skips the
  # host's own /etc/zprofile and /etc/zshrc, which may put the developer's
  # tools on PATH; the sandbox home's ~/.zprofile and ~/.zshrc still apply.
  write_stub "$SB/root/bin/zsh" <<'EOF'
exec /bin/zsh -d "$@"
EOF

  # Installed later by the stub installers, exactly where the real ones land.
  write_stub "$SB/late/nix" <<'EOF'
echo "nix $*" >>"$SB/calls.log"
case " $* " in
  *" --version "*) echo "nix (Determinate Nix 3.24.3) 2.36.0" ;;
  *" build "*) [ ! -e "$SB/state/build_fails" ] || exit 1; cat "$SB/state/new_system" ;;
  *" diff-closures "*) echo "activation-v2cc: (no version) added" ;;
esac
EOF
  write_stub "$SB/late/nix-env" <<'EOF'
echo "nix-env $*" >>"$SB/calls.log"
[ "$1" = "-p" ] && [ "$3" = "--set" ] && ln -sfn "$4" "$2"
EOF
  write_stub "$SB/late/nix-store" <<'EOF'
for path; do :; done
cat "$path/requisites"
EOF
  cat >"$SB/late/nix-installer" <<'EOF'
echo "nix-installer $*" >>"$SB/calls.log"
[ ! -e "$SB/state/nix_install_fails" ] || exit 1
mkdir -p "$SB/root/nix/var/nix/profiles/default/bin"
cp "$SB/late/nix" "$SB/late/nix-env" "$SB/late/nix-store" "$SB/root/nix/var/nix/profiles/default/bin/"
: >"$SB/root/nix/receipt.json"
EOF
  cat >"$SB/late/brew-installer" <<'EOF'
echo "brew-installer NONINTERACTIVE=${NONINTERACTIVE:-}" >>"$SB/calls.log"
[ ! -e "$SB/state/brew_install_fails" ] || exit 1
mkdir -p "$SB/root/opt/homebrew/bin"
printf '#!/bin/bash\necho "Homebrew 5.0.0"\n' >"$SB/root/opt/homebrew/bin/brew"
chmod +x "$SB/root/opt/homebrew/bin/brew"
EOF
  cat >"$SB/late/claude-installer" <<'EOF'
echo "claude-installer" >>"$SB/calls.log"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/bash\necho "2.1.0 (Claude Code)"\n' >"$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
EOF

  # By default the configuration built for this machine manages v2cc only.
  make_system fresh v2cc "v2cc=gen-v2cc"
  system_path fresh >"$SB/state/new_system"
}

# Canonical paths, as the scripts record them (/var is a symlink on macOS).
system_path() { (cd -P "$SB/store/$1" && pwd -P); }
link_target() { (cd -P "$1" 2>/dev/null && pwd -P); }

# make_system NAME PRIMARY_USER "user=generation ..." [EXTRA_PACKAGE...]
#
# A fake nix-darwin system closure with the same layout and the same
# activate-script lines the real one has. Like the real one, its activate
# script only mentions its own path in the systemConfig= line and makes
# itself /run/current-system as its last step. The closure it "depends on"
# (what nix-store --query --requisites prints) is itself, the Home Manager
# generations and any extra packages.
make_system() {
  local name="$1" primary="$2" pairs="$3" dir pair user gen wrapper tool
  shift 3
  dir="$SB/store/$name"
  mkdir -p "$dir/etc/profiles/per-user" "$dir/sw/bin" "$SB/store/wrappers" \
    "$dir/Library/LaunchDaemons" "$dir/user/Library/LaunchAgents"
  : >"$dir/Library/LaunchDaemons/org.nixos.activate-system.plist"
  for tool in git node darwin-rebuild; do
    printf '#!/bin/bash\necho "%s 1.0"\n' "$tool" >"$dir/sw/bin/$tool"
    chmod +x "$dir/sw/bin/$tool"
  done
  (cd -P "$dir" && pwd -P) >"$dir/requisites"
  for tool in "$@"; do
    mkdir -p "$SB/store/$tool"
    (cd -P "$SB/store/$tool" && pwd -P) >>"$dir/requisites"
  done
  # The fake script must contain these expansions literally.
  # shellcheck disable=SC2016
  {
    printf '#!/bin/bash\nset -e\n'
    printf 'systemConfig=%s\n' "$dir"
    printf 'primaryUser=%s\n' "$primary"
    printf 'echo "activate ${systemConfig##*/}" >>%q\n' "$SB/calls.log"
    printf 'if [ -e %q"${systemConfig##*/}" ]; then echo "simulated activation failure" >&2; exit 2; fi\n' \
      "$SB/state/activate_fails_"
    for pair in $pairs; do
      user="${pair%%=*}"
      gen="$SB/store/${pair#*=}"
      wrapper="$SB/store/wrappers/${pair#*=}-activation-$user"
      mkdir -p "$gen" "$dir/etc/profiles/per-user/$user"
      (cd -P "$gen" && pwd -P) >>"$dir/requisites"
      printf 'exec %s/activate --driver-version 1 >&2\n' "$gen" >"$wrapper"
      printf 'echo Activating home-manager configuration for %s >&2\n' "$user"
      printf 'launchctl asuser "$(id -u %s)" sudo -u %s --set-home %s\n' \
        "$user" "$user" "$wrapper"
      printf 'if [ "$(id -un)" = %s ]; then mkdir -p "$HOME/.local/state/home-manager/gcroots" && ln -sfn %q "$HOME/.local/state/home-manager/gcroots/current-home"; fi\n' \
        "$user" "$gen"
    done
    printf 'ln -sfn "$systemConfig" %q\n' "$SB/root/run/current-system"
  } >"$dir/activate"
  chmod +x "$dir/activate"
}

# Make NAME the running system, as if it had been activated earlier.
set_running_system() {
  ln -sfn "$SB/store/$1" "$SB/root/run/current-system"
  ln -sfn "$SB/store/$1" "$SB/root/nix/var/nix/profiles/system"
}

have_clt() {
  mkdir -p "$SB/root/Library/Developer/CommandLineTools/usr/bin"
  : >"$SB/root/Library/Developer/CommandLineTools/usr/bin/git"
}
have_nix() {
  mkdir -p "$SB/root/nix/var/nix/profiles/default/bin"
  cp "$SB/late/nix" "$SB/late/nix-env" "$SB/late/nix-store" "$SB/root/nix/var/nix/profiles/default/bin/"
  : >"$SB/root/nix/receipt.json"
}
have_brew() {
  mkdir -p "$SB/root/opt/homebrew/bin"
  printf '#!/bin/bash\necho "Homebrew 5.0.0"\n' >"$SB/root/opt/homebrew/bin/brew"
  chmod +x "$SB/root/opt/homebrew/bin/brew"
}
have_claude() {
  mkdir -p "$SB/home/.local/bin"
  printf '#!/bin/bash\necho "2.1.0 (Claude Code)"\n' >"$SB/home/.local/bin/claude"
  chmod +x "$SB/home/.local/bin/claude"
}

# run SCRIPT [ARGS...]: run one of the sandboxed scripts with a clean
# environment and no terminal. Extra environment goes in RUN_ENV; RUN_PATH
# is put in front of PATH, as a terminal window that already has it would.
RUN_ENV=""
RUN_PATH=""
run() {
  local script="$1"
  shift
  # shellcheck disable=SC2086
  out="$(env -i PATH="$RUN_PATH$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$SB/home" \
    V2CC_SYSROOT="$SB/root" LC_ALL=en_US.UTF-8 $RUN_ENV \
    /bin/bash "$SB/repo/$script" "$@" 2>&1 </dev/null)"
  rc=$?
  RUN_ENV=""
  RUN_PATH=""
}

# A GitHub token-shaped string, assembled at run time so that no
# token-shaped literal is ever committed.
fake_token() { printf 'gh%s_%s' p "$(printf 'A%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36)"; }
