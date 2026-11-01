#!/usr/bin/env bash
# Multiplayer-safety grep: forbid non-deterministic / unsafe APIs outside the (dev-only) spike code.
set -euo pipefail
cd "$(dirname "$0")/.."
bad=$(grep -rnE '\bmath\.random\b|\bos\.(time|clock|date)\b|\bio\.|\bpairs\(_G\)' mod --include=*.lua | grep -v 'mod/scripts/spike/' | grep -vE ':[0-9]+:[[:space:]]*--' || true)
if [ -n "$bad" ]; then echo "Non-deterministic API usage:"; echo "$bad"; exit 1; fi
# functions can't live in storage: crude check for 'storage.* = function'
bad=$(grep -rnE 'storage\.[A-Za-z_.]* *= *function' mod --include=*.lua || true)
if [ -n "$bad" ]; then echo "Function stored in storage:"; echo "$bad"; exit 1; fi
echo "determinism lint ok"
