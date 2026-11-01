#!/usr/bin/env bash
# Build build/<name>_<version>.zip (top-level folder <name>_<version>/ as Factorio requires).
#   scripts/package.sh            dev build (includes spikes)
#   scripts/package.sh --release  strips spike code (stubs keep requires valid)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
STAGE="$REPO_ROOT/build/stage/${MOD_NAME}_${MOD_VERSION}"
rm -rf "$REPO_ROOT/build/stage"; mkdir -p "$STAGE" "$REPO_ROOT/build"
cp -R "$REPO_ROOT/mod/." "$STAGE/"
rm -f "$STAGE/autorun.lua"
if [ "${1:-}" = "--release" ]; then
  rm -f "$STAGE"/scripts/spike/s[0-9]*.lua "$STAGE/scripts/spike/core.lua"
  echo "-- release stub" > "$STAGE/scripts/spike/loader.lua"
  echo "-- release stub" > "$STAGE/prototypes/spikes.lua"
fi
find "$STAGE" -name .DS_Store -delete
ZIP="$REPO_ROOT/build/${MOD_NAME}_${MOD_VERSION}.zip"; rm -f "$ZIP"
(cd "$REPO_ROOT/build/stage" && zip -qr "$ZIP" "${MOD_NAME}_${MOD_VERSION}")
echo "$ZIP"
