#!/usr/bin/env bash
# Symlink ./mod into the Factorio mods dir as <name>_<version> (unzipped-mod format). Edit Lua, then
# "Restart" a save (or /reload? no - Lua changes need a new load: main menu > load save; data changes need full restart).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
MODS="$FACTORIO_USER_DIR/mods"
mkdir -p "$MODS"
# A stale released zip with the same name would shadow/conflict with the symlink.
ls "$MODS"/${MOD_NAME}_*.zip >/dev/null 2>&1 && echo "WARNING: remove zipped copies of ${MOD_NAME} in $MODS, they conflict with the dev link"
rm -f "$MODS/${MOD_NAME}_"* 2>/dev/null || true
ln -sfn "$REPO_ROOT/mod" "$MODS/${MOD_NAME}_${MOD_VERSION}"
echo "Linked $MODS/${MOD_NAME}_${MOD_VERSION} -> $REPO_ROOT/mod"
echo "Launch Factorio from Steam; enable 'Bio-Logistics Colonies' (Space Age mods must be enabled too)."
