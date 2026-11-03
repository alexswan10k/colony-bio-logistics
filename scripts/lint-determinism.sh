#!/usr/bin/env bash
# Multiplayer-safety grep: forbid non-deterministic / unsafe APIs outside the (dev-only) spike code.
set -euo pipefail
cd "$(dirname "$0")/.."
bad=$(grep -rnE '\bmath\.random\b|\bos\.(time|clock|date)\b|\bio\.|\bpairs\(_G\)' mod --include=*.lua | grep -v 'mod/scripts/spike/' | grep -vE ':[0-9]+:[[:space:]]*--' || true)
if [ -n "$bad" ]; then echo "Non-deterministic API usage:"; echo "$bad"; exit 1; fi
# functions can't live in storage: crude check for 'storage.* = function'
bad=$(grep -rnE 'storage\.[A-Za-z_.]* *= *function' mod --include=*.lua || true)
if [ -n "$bad" ]; then echo "Function stored in storage:"; echo "$bad"; exit 1; fi
# Undefined globals (a missing `local x = require(...)` crashes only when that line runs in game).
if command -v luajit > /dev/null; then
  known='game|storage|script|defines|settings|rendering|helpers|prototypes|remote|commands|serpent|log|table|string|math|pairs|ipairs|next|type|tostring|tonumber|require|error|assert|select|unpack|setmetatable|getmetatable|rawget|rawset|rawequal|pcall|xpcall|print|table_size|localised_print|_G|_ENV|data|mods|feature_flags|bit32'
  bad=$(find mod/scripts -name '*.lua' -not -path 'mod/scripts/spike/*' | sort | while read -r f; do
    luajit -bl "$f" 2>/dev/null | grep -oE 'GGET .*"[A-Za-z_][A-Za-z0-9_]*"' | grep -oE '"[A-Za-z_][A-Za-z0-9_]*"' | tr -d '"' \
      | sort -u | grep -vxE "$known" | sed "s|^|$f: |"
  done || true)
  if [ -n "$bad" ]; then echo "Undefined global (missing require?):"; echo "$bad"; exit 1; fi
fi
echo "determinism lint ok"
