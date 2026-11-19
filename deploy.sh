#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

./prepare.sh

command -v nix >/dev/null || {
  echo "错误：请先安装 Determinate Nix"
  exit 1
}

if [ ! -x /opt/homebrew/bin/brew ]; then
  echo "需要先安装 Homebrew，停止部署。"
  echo "官方安装说明：https://brew.sh"
  exit 1
fi

if [ ! -x /usr/bin/xcode-select ] || ! xcode-select -p >/dev/null 2>&1; then
  echo "需要先安装 Xcode Command Line Tools，停止部署。"
  exit 1
fi

echo "验证系统配置..."
nix --extra-experimental-features 'nix-command flakes' \
  build "path:$PWD#darwinConfigurations.v2cc-test.system" --no-link

echo "激活系统配置..."
if command -v darwin-rebuild >/dev/null 2>&1; then
  sudo darwin-rebuild switch --flake "path:$PWD#v2cc-test"
else
  sudo nix --extra-experimental-features 'nix-command flakes' \
    run nix-darwin -- switch --flake "path:$PWD#v2cc-test"
fi

echo "安装或验证 Claude Code..."
./install-claude.sh

echo "V2CC 部署完成"
