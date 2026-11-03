# Bio-Logistics Colonies (Factorio 2.0 + Space Age)
Colony-simulation mod. See [design document](docs/factorio_colony_mod_design_document.md). Status: **pre-alpha, milestone M2 in progress** (M0 spikes and the M1 core loop are done; see [AGENTS.md](AGENTS.md) for the current state and open issues).

- Run the feasibility spikes: [docs/SPIKES.md](docs/SPIKES.md)
- Build, link, release (Steam / mod portal): [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md)
- Testing without the game (unit tests, mocks, balance sim): [docs/TESTING.md](docs/TESTING.md)
- Art policy: [docs/ART.md](docs/ART.md)

Layout: `mod/` (the mod), `scripts/` (dev/CI tooling), `docs/`, `spike-results/` (committed run reports).
Quick start (macOS+Steam): `scripts/link-dev.sh` → launch Factorio → enable mod → `/spike list`.
