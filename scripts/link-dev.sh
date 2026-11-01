#!/usr/bin/env bash
# Symlink ./mod into the Factorio mods dir as colony-bio-logistics_<version>.
set -euo pipefail
MODS="${FACTORIO_MODS:-$HOME/Library/Application Support/factorio/mods}"
VER=$(python3 -c "import json;print(json.load(open('mod/info.json'))['version'])")
mkdir -p "$MODS"
ln -sfn "$(pwd)/mod" "$MODS/colony-bio-logistics_$VER"
echo "Linked -> $MODS/colony-bio-logistics_$VER"
