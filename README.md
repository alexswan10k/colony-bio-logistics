# Bio-Logistics Colonies (Factorio 2.0 + Space Age)

A RimWorld/Settlers-style colony layer for Factorio: real colonists with jobs, homes, hunger, sleep,
illness and mortality, a territory you claim chunk by chunk, and a supply chain that hauls into and out
of vanilla machines. **Space Age is a hard dependency.** Design: [design document](docs/factorio_colony_mod_design_document.md).

Status: **pre-alpha, M4 feature-complete and in final playtest/balance** (M0 spikes, the M1 core loop,
M2 economy/transport, M3 defence and the M4 off-world/content tier are landed; see [AGENTS.md](AGENTS.md)
for the full decision log and remaining open issues, notably Fulgora/Aquilo hazards under #70).

## What is in the build

- **Town Hall → territory → jobs.** Colonists staff huts, walk to real harvest sites, haul goods inward,
  build ghosts, and get promoted through tool tiers. Desirability drives migration and breeding.
- **Economy.** Farms and kitchens, salt pans and smokehouses, cold chain and canning, water wells and
  towers, a Town Archive/University with perishable custom science packs, and a circuit-network Colony
  Ledger that publishes stock or shortfall onto vanilla wires.
- **Transport and defence.** Motor-pool trucks, passenger rail, commuting and tourism, a Command Whistle
  for direct RTS orders, militia, watchtower garrisons, armories, patrol posts and ammo-turret logistics.
- **M4 off-world.** Habitat Domes found colonies on hostile planets and platforms; Gleba jam and spore-
  borne Swamp Fever, Vulcanus Heat Stroke, cryo storage, EVA crew, orbital hydroponics, pod launches,
  a second science pack (Sovereign Codex), and endgame gear/housing tiers.

A headless release regression spike (`m4_release_regression`) exercises the merged M4 integrations
together; run it with `TICKS=3600 scripts/headless-spike.sh m4_release_regression`.

## Docs

- Mod portal / store description: [docs/MOD_PORTAL.md](docs/MOD_PORTAL.md)
- Changelog: [mod/changelog.txt](mod/changelog.txt)
- Feasibility spikes and headless harness: [docs/SPIKES.md](docs/SPIKES.md)
- Build, link, release (Steam / mod portal): [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
- Testing without the game (unit tests, mocks, balance sim): [docs/TESTING.md](docs/TESTING.md)
- Art policy: [docs/ART.md](docs/ART.md)

Layout: `mod/` (the mod), `scripts/` (dev/CI tooling), `docs/`, `spike-results/` (committed run reports).
Quick start (macOS + Steam): `scripts/link-dev.sh` → launch Factorio → enable mod → `/spike list`.
