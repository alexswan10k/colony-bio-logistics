-- Bio-Logistics entry point. All modules register handlers through scripts.events (single-handler-per-event workaround).
local events = require("scripts.events")
local store = require("scripts.store")
require("scripts.scheduler")
require("scripts.territory")
require("scripts.colony")
require("scripts.work")
require("scripts.marker")
require("scripts.debug")

events.on_init(store.init)
events.on_configuration_changed(store.migrate)

-- Feasibility spikes (dev tooling). Release builds ship an empty loader stub (see scripts/package.sh).
require("scripts.spike.loader")
