#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v lua-language-server >/dev/null 2>&1; then
  echo "Error: lua-language-server not found."
  echo "Install it via: brew install lua-language-server (on macOS) or download from https://github.com/LuaLS/lua-language-server/releases"
  exit 1
fi

"$REPO_ROOT/scripts/fetch-types.sh"

echo "Running lua-language-server type verification..."
lua-language-server --check="$REPO_ROOT" --configpath="$REPO_ROOT/.luarc.json" --check_format=pretty "$@"
