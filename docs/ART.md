# Art plan (issue #13)
Policy: **no feature blocks on art.** Every entity ships with a placeholder (tinted vanilla sprite + generated icon) until the milestone's playtest passes.
Minimum assets per milestone:
- M1: colonist (walk/idle/work), town hall, tent/shack, labour huts (forager/woodcutter/miner/farm), crates x3, compost bin, hunting lodge, wild boar, fishing dock, salt pan, smokehouse, selection tool/shortcut icons, badge icon, ~16 item icons (incl. basket/axe/pickaxe/hoe/rifle/rod, meat/fish/fertilizer/salt/preserved meat/preserved fish).
- M2: 3 science packs, archive/university, homestead, townhouse, apartment, farm, kitchen, smokehouse, salt pan, clinic, taverns, passenger coach + platform, canteen, resort, cannery, refrigerated warehouse, refrigerated wagon, canned food icons.
- M3: armory, watchtower, patrol post, motor pool, whistle tool.
- M4: habitat dome, orbital dome, hydroponics, nursery, airlock, pod item, suits, gear icons.
Decision needed from owner: placeholder-only for MVP vs commissioned/AI-generated sprites.

## Generated art pipeline

`scripts/gen_art.py` draws every placeholder sprite; `scripts/artlib.py` is the drawing library. Run `python3 scripts/gen_art.py` to regenerate `mod/graphics/` (main sprite + projected shadow + 64x64 icon per asset).

Buildings are drawn in a real 3/4 top-down projection, not as flat front elevations:

- `artlib.View` maps a plan footprint (`wt x dt` tiles) onto a screen-aligned ground square, foreshortens height by `FZ = 28.8` art px per tile and narrows the back edge slightly (`persp`) so roofs are trapezoids and the side walls show.
- Roof helpers (`hip_roof`, `gable_roof`, `shed_roof`, `flat_roof`, `front_gable`) give each building a distinct silhouette; props (lean-to, log pile, adit/headframe, silo, antlers, dock/boat/net, oven, anvil, awning, tower, balconies, dome, loading doors, trailer, garage) make them readable at a glance.
- `finish()` writes the sprite, its shadow and its icon, and registers the sprite geometry in `mod/prototypes/art_manifest.lua`. The manifest carries source width/height, scale and the upward `shift` that keeps the footprint on the entity box, so taller buildings stand up instead of being squashed. `mod/prototypes/buildings.lua` builds every entity picture from that manifest (`sprite(name)`), including the shadow layer; do not hardcode sprite sizes there.
- Icons are cropped to each sprite's alpha bounding box and scaled to fit 64x64 with a small margin, so a 3x3/4x4 building is not a speck in the crafting grid.

When adding a building, draw it with `building(wt, dt)` + `finish(a, b, name, wt, dt)`; the manifest entry is generated for you.

