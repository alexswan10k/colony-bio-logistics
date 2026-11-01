#!/usr/bin/env bash
# Run unit tests with plain Lua (no Factorio). Needs luajit or lua (brew install luajit). Optional arg: name filter.
set -euo pipefail
cd "$(dirname "$0")/.."
LUA=$(command -v luajit || command -v lua || { echo "install luajit"; exit 1; })
$LUA tests/runner.lua "$@"
