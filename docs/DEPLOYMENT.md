# Deployment (Steam, macOS-first)

Factorio has **no Steam Workshop**. Steam players install mods from the in-game *Mods → Mod portal* (mods.factorio.com) or by dropping a zip/folder in the user mods dir. So:

| Stage | How |
|---|---|
| Dev loop | `scripts/link-dev.sh` symlinks `mod/` → `~/Library/Application Support/factorio/mods/colony-bio-logistics_<ver>` (same dir for the Steam build). Launch from Steam, enable the mod (Space Age must be enabled). |
| Share a test build | `scripts/package.sh` → `build/colony-bio-logistics_<ver>.zip`; testers drop it into their `mods/` folder. |
| Release build | `scripts/package.sh --release` strips all spike code. |
| GitHub release | bump `mod/info.json` version + add entry to `mod/changelog.txt`, then `git tag vX.Y.Z && git push --tags`. `.github/workflows/release.yml` validates tag/version/changelog, lints, packages, creates the GitHub Release. |
| Mod portal | Same workflow publishes if repo secret `FACTORIO_API_KEY` is set (key from factorio.com/profile, scope *ModPortal: Upload Mods*). Manual: `FACTORIO_API_KEY=… scripts/publish.sh`. First publish creates the mod page; add description/thumbnail/screenshots on the portal afterwards. |

## Paths (macOS + Steam)
- Binary: `~/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio` (auto-detected; override `FACTORIO_BIN`)
- User data / mods / logs / script-output: `~/Library/Application Support/factorio/`
- Log: `factorio-current.log`; spike reports: `script-output/colony-spikes/`

## Gotchas
- Dev link folder must be named `<name>_<version>`; don't keep a zipped copy of the same mod alongside it.
- Lua changes: reload the save from the main menu. `data.lua` / `settings.lua` / prototype changes: restart the game.
- Headless runs (`scripts/headless-spike.sh`, `scripts/benchmark.sh`) can't run while the Steam GUI instance is open.
- Versioning: Factorio mods use `major.minor.patch` and saves migrate via `mod/scripts/store.lua` (bump `SCHEMA`). Never ship without a migration if storage layout changed.
- `space-age` is a hard dependency (`info.json`); players without the DLC can't enable the mod.
