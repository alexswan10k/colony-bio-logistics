#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
$(command -v luajit || command -v lua) sim/balance.lua
