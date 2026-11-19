#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

USERNAME="$(id -un)"
printf '"%s"\n' "$USERNAME" > local-user.nix

echo "V2CC 用户: $USERNAME"
echo "本机配置已生成"
