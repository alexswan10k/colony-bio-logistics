require("prototypes.colonist")
-- Throwaway prototypes needed by feasibility spikes. If the game fails to load, untick
-- "colony-spike-protos" in Settings > Mod settings > Startup and report which prototype broke.
if settings.startup["colony-spike-protos"].value then
  require("prototypes.spikes")
end
require("prototypes.buildings")
