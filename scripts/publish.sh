#!/usr/bin/env bash
# Upload a release zip to the Factorio mod portal (what Steam players use via in-game Mods > Mod portal).
# Requires FACTORIO_API_KEY (https://factorio.com/profile -> API keys, scope "ModPortal: Upload Mods").
# Usage: scripts/publish.sh [zip]   (defaults to build/<name>_<version>.zip)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
: "${FACTORIO_API_KEY:?set FACTORIO_API_KEY}"
ZIP="${1:-$REPO_ROOT/build/${MOD_NAME}_${MOD_VERSION}.zip}"
[ -f "$ZIP" ] || { echo "missing $ZIP (run scripts/package.sh --release)"; exit 1; }
status=$(curl -s -o /dev/null -w '%{http_code}' "https://mods.factorio.com/api/mods/$MOD_NAME")
endpoint=init_upload; [ "$status" = 404 ] && endpoint=init_publish   # first publish creates the mod page
upload_url=$(curl -fsS -H "Authorization: Bearer $FACTORIO_API_KEY" -d "mod=$MOD_NAME" \
  "https://mods.factorio.com/api/v2/mods/releases/$endpoint" | python3 -c 'import json,sys;print(json.load(sys.stdin)["upload_url"])')
curl -fsS -F "file=@$ZIP" "$upload_url"; echo
echo "Published $MOD_NAME $MOD_VERSION via $endpoint"
