# Mod portal description (ready to paste)

This is the user-facing copy for the Factorio mod portal page. It is plain text with light markdown; the
portal stores it as the mod's description. Keep gameplay claims here aligned with `mod/changelog.txt`.

---

Bio-Logistics Colonies adds a living settlement layer to Factorio Space Age. Build a Town Hall, claim
territory, and watch colonists take jobs, walk to work, haul goods, eat, sleep, get sick and start
families. Every colonist is a real unit with a home, a job and a roster entry - not a floating number.

## Core loop

- Colonists staff woodcutter, forager, miner, farm, forester, hunter, fisher, smokehouse, clinic,
  research and construction huts, each with its own tool and wear.
- Haulers carry goods from huts, crates and your vanilla machines into colony stock, and bring tools,
  food, water, fertilizer and ammunition back out. Opt in a machine with the marker tool; belts and
  inserters still work on our containers.
- Tents, cabins, homesteads, townhouses, apartments and Habitat Domes house colonists. Desirability
  reads real food, housing, jobs, leisure and scenery; migrants arrive and children are born when the
  town is worth living in.
- Spoilage is cleared into compost bins for fertilizer; perishable science packs spoil into lab trash.

## Research and progression

Two custom science packs - the Frontier Charter and the Civic Treatise - unlock a colony tech tree that
interlocks with (but is paid for separately from) vanilla research. The endgame adds a genuine second
pack, the Sovereign Codex, distilled from Treatises and Federation Plating.

## Transport, defence and logistics

- Motor-pool trucks, passenger platforms and coaches, commuter outposts, tourism and freight crates
  connect towns. A Command Whistle lets you drag-select colonists and issue direct Move/Attack orders.
- Militia, watchtower garrisons, armories, patrol posts and ammo-turret logistics defend the town.
- A Colony Ledger publishes the town's total stock (or its shortfall against quotas) onto the circuit
  network using a vanilla constant combinator clone.

## Off-world (Space Age)

Habitat Domes can found a colony where a Town Hall cannot - on Vulcanus, Fulgora, Aquilo and space
platforms. Gleba fruit is cured into long-life jam, but working in the spores risks Swamp Fever; the
Vulcanus open air causes Heat Stroke unless you work near a dome. Late gear includes cryo storage,
Enviro-Suits, EVA crew, orbital hydroponics, cryo pods for off-world births and launches, and fusion
arcologies.

## Requirements and caveats

Requires Factorio 2.1+ with the Space Age DLC. This is a pre-alpha M4 build: the core loop and all M4
features are implemented and covered by headless regression spikes, but Fulgora- and Aquilo-specific
hazards are still open, and a full M4 playtest/balance pass is in progress. Because colony storage is
versioned, keep backups when upgrading between versions.

Report bugs and follow development on the GitHub repository (alexswan10k/colony-bio-logistics).
