-- Loads all feasibility spikes. scripts/package.sh --release replaces this file with an empty stub.
require("scripts.spike.core")
for _, m in ipairs({
  "s01_units", "s02_trains", "s03_cars", "s04_platform", "s05_pod", "s06_tiles",
  "s07_territory", "s08_registry", "s09_crates", "s10_work", "s11_biters", "s12_wildlife", "s13_science", "m1_colony", "m1_food", "m1_persist",
  "m1_bench", "m1_desirability", "m1_blueprint", "m1_motor", "m1_tavern", "m1_rail", "m1_death", "m1_shelter", "m1_commute", "m1_illness",
  "m1_stats", "m1_breed", "m1_migrant", "m1_garrison",
}) do
  require("scripts.spike." .. m)
end
