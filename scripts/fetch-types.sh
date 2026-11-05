#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/.types"

if [ -d "$TARGET/factorio/library" ]; then
  echo "Factorio type definitions already present in $TARGET/factorio"
  exit 0
fi

echo "Generating Factorio 2.0 LuaLS type definitions..."
mkdir -p "$TARGET"
npx --yes factoriomod-debug docs -o latest "$TARGET"
echo "Done. Factorio type definitions written to $TARGET/factorio"
