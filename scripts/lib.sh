# Shared helpers (source me). Defaults target macOS + Steam; override via env.
#   FACTORIO_USER_DIR   write-data dir (mods/, saves/, script-output/, factorio-current.log)
#   FACTORIO_BIN        factorio executable
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD_NAME=$(python3 -c "import json;print(json.load(open('$REPO_ROOT/mod/info.json'))['name'])")
MOD_VERSION=$(python3 -c "import json;print(json.load(open('$REPO_ROOT/mod/info.json'))['version'])")

case "$(uname -s)" in
  Darwin)
    : "${FACTORIO_USER_DIR:=$HOME/Library/Application Support/factorio}"
    for c in "/Volumes/RTL9210/SteamLibrary/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio" \
             "$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio" \
             "/Applications/factorio.app/Contents/MacOS/factorio" \
             "/Applications/Factorio.app/Contents/MacOS/factorio"; do
      [ -x "$c" ] && : "${FACTORIO_BIN:=$c}"
    done ;;
  Linux)
    : "${FACTORIO_USER_DIR:=$HOME/.factorio}"
    for c in "$HOME/.steam/steam/steamapps/common/Factorio/bin/x64/factorio" "$HOME/factorio/bin/x64/factorio"; do
      [ -x "$c" ] && : "${FACTORIO_BIN:=$c}"
    done ;;
esac
export FACTORIO_USER_DIR
need_bin() { [ -n "${FACTORIO_BIN:-}" ] && [ -x "$FACTORIO_BIN" ] || { echo "Factorio binary not found. Set FACTORIO_BIN (Steam: right-click Factorio > Manage > Browse local files)."; exit 1; }; }
