#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "=== V2CC Mac mini Bootstrap ==="

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "仅支持 Apple Silicon Mac"
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "请先完成 Xcode Command Line Tools 安装："
  xcode-select --install
  exit 1
fi

export PATH="/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

if ! command -v nix >/dev/null 2>&1; then
  echo "请先安装 Determinate Nix："
  echo "https://determinate.systems/install/"
  echo "安装完成后重新打开终端，再运行本脚本。"
  exit 1
fi

if [ ! -x /opt/homebrew/bin/brew ]; then
  echo "缺少 Homebrew。"
  read -r -p "使用官方安装器安装？[y/N] " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    exit 1
  fi

  /bin/bash -c "$(curl -fsSL \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/nix/var/nix/profiles/default/bin:$PATH"

echo "基础依赖检查完成。"
read -r -p "继续部署 V2CC 系统配置？[y/N] " answer

if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
  ./deploy.sh
else
  echo "未执行系统部署。"
fi
