#!/bin/bash
set -euo pipefail

if [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zprofile" 2>/dev/null ||
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"

"$HOME/.local/bin/claude" --version
