# Feasibility spike runbook (milestone M0)

All spikes are in `mod/scripts/spike/`. Setup once: `scripts/link-dev.sh`, launch from Steam, new Space Age map, enable cheats if wanted (`/c game.player.cheat_mode=true`).
Reports: chat + `script-output/colony-spikes/<spike>.txt`. Each line is `[PASS]/[FAIL]/[????]` (judgement needed) or `[OK ]/[ERR]` (raw API probe — **an [ERR] is a finding**, not a harness failure). `[PROF]` lines give Lua cost.
After a run: `scripts/collect-results.sh`, then `scripts/post-results.sh spike-results/<ts>/<spike>.txt` posts it to the right issue.
`/spike list` lists everything. If the game won't load, untick startup setting **Spike prototypes** and report which prototype broke.

| Spike | Issue | Command | Where to stand | Decides |
|---|---|---|---|---|
| s05_pod | #5 | `/spike run s05_pod` | anywhere (headless ok) | Can pods keep tags+spoil; refresh recipe behaviour |
| s09_crates | #9 | `/spike run s09_crates` | anywhere (headless ok) | Real logistic-container vs custom crate |
| s02_trains | #2 | `/spike run s02_trains` | flat-ish ground | Can anything ride a coach → abstract commuting? |
| s03_cars | #3 | `/spike run s03_cars` | open ground | Keep/cut colonist-driven cars |
| s04_platform | #4 | `/spike run s04_platform` | anywhere | Units on platforms: M4 viability |
| s06_tiles | #6 | `/spike run s06_tiles 32` | coast + forest | Fertility table, scan costs |
| s07_territory | #7 | `/spike run s07_territory` | open ground; then hand-place furnaces/bots/blueprints | Cancel/refund viability |
| s08_registry | #8 | `/spike run s08_registry 5000 10` | open ground; then open machines, blueprint | gui.relative coverage, blueprint tags, dispatcher cost |
| s10_work | #10 | `/spike run s10_work` | on ore, next to trees | tree/ore/pollution/ghost API |
| s11_biters | #11 | `/spike run s11_biters 10 20 0` then `... 1` (flee) | open ground | Civilian vulnerability, evolution |
| s01_units | #1 | `/spike run s01_units 300 60`, then `... 300 60 5` (biters); repeat with startup setting *colonist without attack_parameters* | forest | Colonist representation: go/no-go |

Suggested order (fast→slow, riskiest first): s01, s02, s05, s09, s08, s07, s03, s04, s06, s10, s11.
UPS: save a map after spawning with `/spike run s01_units 300 600`, then `scripts/benchmark.sh <save> 3600` with/without the mod.
Headless (no player; no terrain-dependent spikes): `scripts/headless-spike.sh s05_pod s09_crates s04_platform`.

## Not code-spikes
- #13 art: see `docs/ART.md`. #14 multiplayer/determinism: `scripts/lint-determinism.sh` + CI; MP test = host a LAN game, join from 2nd client, run `/spike run s08_registry`.
- Decisions (#16–#22) need your call, not a run.

## Caveats
Spike code was written without access to a Factorio install; API names follow 2.0 docs from memory. Expect a few [ERR]s from wrong signatures — fix in the spike, re-run, they're cheap.
