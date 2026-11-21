#!/bin/bash
#
# Operator side: print the one command a customer account runs to set up
# its Mac.
#
#   tools/make-entry-command.sh [--dry-run] [git-ref]      (default: main)
#
# With --dry-run the printed command only checks the machine and reports
# what it would do; it installs and changes nothing.
#
# Run this on a machine that is already signed in to GitHub with `gh` and
# can read the private repository. It asks GitHub for a download link to
# the exact commit. GitHub answers with a link that carries its own
# short-lived download token (about five minutes), which is not your
# personal token. The printed command contains that link and the SHA-256
# of the bundle, so:
#
#   - no GitHub token of yours ever reaches the customer account;
#   - nothing is executed there unless it is byte-for-byte the bundle that
#     was hashed here;
#   - the link stops working within minutes, so what is left in the shell
#     history afterwards cannot download anything.
#
# If the link expires before it is used, just run this again.
set -euo pipefail

repo="${V2CC_REPO:-jasontopia/v2cc-mac-setup}"
prefix=""
if [ "${1:-}" = "--dry-run" ]; then
  prefix="V2CC_DRY_RUN=1 "
  shift
fi
ref="${1:-main}"

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

command -v gh >/dev/null 2>&1 || die "需要已登录的 GitHub CLI（gh）。"

commit="$(gh api "repos/$repo/commits/$ref" --jq .sha)" ||
  die "无法解析 $repo 的 ${ref}。"
case "$commit" in
  *[!0-9a-f]* | '') die "GitHub 返回了意外的提交号。" ;;
esac

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# The personal token goes to curl on stdin, never on a command line, and
# only to api.github.com. The redirect is read, not followed, so the token
# is not replayed to the download host.
url="$(gh auth token | sed 's/^/header = "Authorization: Bearer /; s/$/"/' |
  curl --proto '=https' --tlsv1.2 -sS -K - -o /dev/null -D - \
    "https://api.github.com/repos/$repo/tarball/$commit" |
  tr -d '\r' | awk 'tolower($1) == "location:" { print $2 }')"
case "$url" in
  https://codeload.github.com/*) ;;
  *) die "GitHub 没有返回下载链接（请确认 gh 已登录且有该仓库的读取权限）。" ;;
esac
case "$url" in
  *[\'\"\\\$\`\ ]*) die "下载链接中含有意外的字符。" ;;
esac

curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$work_dir/bundle.tgz" ||
  die "下载部署包失败。"
sha256="$(shasum -a 256 "$work_dir/bundle.tgz" | cut -d' ' -f1)"
tar -tzf "$work_dir/bundle.tgz" | grep -q '/bootstrap\.sh$' ||
  die "部署包中没有 bootstrap.sh，$ref 不是可部署的版本。"

cat >&2 <<EOF
仓库：$repo
版本：$commit
部署包 SHA-256：$sha256

把下面这一整行发给机主，在新建的管理员账户（例如 v2cc）的「终端」里粘贴运行。
链接约 5 分钟后失效；过期了重新运行本脚本即可。
$([ -z "$prefix" ] || printf '这是演练命令：只检查并报告，不安装、不改动系统。')

EOF

# Everything the customer account runs before the bundle is verified is in
# this one line. It must work when pasted into zsh, so it contains no
# single quotes.
cat <<EOF
${prefix}/bin/bash -c 'set -euo pipefail; u="$url"; s="$sha256"; c="$commit"; t="\$HOME/v2cc-mac-setup"; d="\$(mktemp -d)"; trap "rm -rf \\"\$d\\"" EXIT; echo "==> 下载 V2CC 部署包 \${c:0:12}"; curl --proto "=https" --tlsv1.2 -fsSL "\$u" -o "\$d/bundle.tgz" || { echo "错误：下载失败。链接约 5 分钟后失效，请向 V2CC 运营方索取新的入口命令。"; exit 1; }; [ "\$(shasum -a 256 "\$d/bundle.tgz" | cut -d" " -f1)" = "\$s" ] || { echo "错误：部署包完整性校验失败，已中止，没有执行任何内容。"; exit 1; }; mkdir "\$d/src"; tar -xzf "\$d/bundle.tgz" -C "\$d/src" --strip-components 1; echo "\$c" > "\$d/src/.v2cc-commit"; rm -rf "\$t.previous"; [ ! -e "\$t" ] || mv "\$t" "\$t.previous"; mv "\$d/src" "\$t"; rm -rf "\$t.previous"; "\$t/bootstrap.sh"'
EOF
