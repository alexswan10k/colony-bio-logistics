-- Loads all feasibility spikes. scripts/package.sh --release replaces this file with an empty stub.
require("scripts.spike.core")
for _, m in ipairs({
  "s01_units", "s02_trains", "s03_cars", "s04_platform", "s05_pod", "s06_tiles",
  "s07_territory", "s08_registry", "s09_crates", "s10_work", "s11_biters", "m1_colony", "m1_food",
}) do
  require("scripts.spike." .. m)
end
