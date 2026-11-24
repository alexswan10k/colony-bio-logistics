-- SPIKE #39: save/load round-trip. Phase 1 builds a live colony and asks the game to auto-save it;
-- phase 2 runs from the loaded save (scripts/save-load.sh passes --test-arg m1_persist_load) and asserts
-- that every registry, scheduler entry and rendering came back. Nothing in `storage.persist_expected` may
-- be a Lua object: it has to survive serialisation as plain data.
local core = require("scripts.spike.core")
local events = require("scripts.events")
local scheduler = require("scripts.scheduler")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local tags = require("scripts.model.tags")

local function count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

local function chunks_of(c)
  return #territory.chunks(c)
end

-- Runs after load, proving the mod's own scheduler queue came back and still fires.
scheduler.register("persist.probe", function()
  storage.persist_probe = (storage.persist_probe or 0) + 1
end)

core.register("m1_persist", {
  issue = 39, auto = true, desc = "build a colony, auto-save it, then reload and assert it survived", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(60, "grass-1")
    storage.interval_override = 30          -- fast evaluations so the colony has colonists before the save
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    local hall = build("colony-town-hall", p)
    local c = storage.colonies[territory.owner_at(s.index, p)]
    ctx.check("colony created", hall ~= nil and c ~= nil)
    if not c then return ctx.finish() end
    local tent = build("colony-housing-tent", {p.x + 6, p.y})
    build("colony-woodcutter-hut", {p.x - 6, p.y})
    local crate = build("colony-demand-crate", {p.x + 10, p.y + 6})
    -- Armory (#56 remainder): a plain registry record with a non-default manning limit and gear in its chest.
    local armory_e = build("colony-armory", {p.x + 6, p.y + 6})
    if armory_e and armory_e.valid then
      c.armories[armory_e.unit_number].limit = 1
      armory_e.insert{name = "colony-rifle", count = 1}
    end
    -- Patrol Post (#57): an ordered waypoint list is plain data and must survive the round-trip.
    local post_e = build("colony-patrol-post", {p.x - 6, p.y + 6})
    if post_e and post_e.valid then
      c.patrol_posts[post_e.unit_number].waypoints = {{x = p.x - 3, y = p.y + 6}, {x = p.x - 6, y = p.y + 9}}
    end
    build("colony-farm-plot", {p.x + 4, p.y - 8})
    -- A ghost the colony cannot pay for stays a ghost, so the registry has something to survive.
    local ghost = s.create_entity{name = "entity-ghost", inner_name = "steel-chest",
      position = {p.x - 10, p.y + 8}, force = "player", raise_built = true}
    c.crates[crate.unit_number].filters = {{item = "coal", count = 25}}
    hall.insert{name = "raw-fish", count = 300}
    hall.insert{name = "wood", count = 300}
    hall.insert{name = "colony-axe", count = 3}
    tent.health = tent.max_health - 50      -- damage with no repair pack in stock: the registry keeps it
    ctx.check("ghost placed", ghost ~= nil and ghost.valid)
    -- Blueprint tags are engine data on the ghost (#36): a save must keep them, not just our registry.
    if ghost and ghost.valid then
      ghost.tags = tags.dictionary(tags.machine({collect = false, requests = {{item = "coal", count = 7}}}))
      ctx.check("ghost carries blueprint tags", ghost.tags[tags.TAG] ~= nil)
    end

    -- #63 review: a SECOND colony founded by a Habitat Dome far outside the hall's 64-tile territory, on the
    -- SAME surface. Its plain core identity (unit number, force string, dome registry) must survive a save
    -- exactly like the hall-founded town's does - there is no schema bump for these fields.
    local far = {x = p.x + 200, y = p.y}
    s.request_to_generate_chunks(far, 2)
    s.force_generate_chunk_requests()
    do
      local tiles = {}
      for x = far.x - 6, far.x + 6 do
        for y = far.y - 6, far.y + 6 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
      end
      s.set_tiles(tiles)
    end
    ctx.check("the far-away spot is outside the first colony", territory.owner_at(s.index, far) == nil,
      tostring(territory.owner_at(s.index, far)))
    local dome = build("colony-habitat-dome", far)
    local dome_cid = territory.owner_at(s.index, far)
    local dome_c = dome_cid and storage.colonies[dome_cid]
    ctx.check("a Habitat Dome founded a second colony", dome and dome.valid and dome_c ~= nil
      and dome_c.id ~= c.id and dome_c.hall == dome,
      "cid=" .. tostring(dome_cid) .. " hall=" .. tostring(dome_c and dome_c.hall and dome_c.hall.name))
    if dome_c then
      ctx.check("the dome colony has a plain core identity and one dome",
        dome_c.hall_un == dome.unit_number and dome_c.hall_force == "player" and #colony.dome_list(dome_c) == 1,
        "un=" .. tostring(dome_c.hall_un) .. " force=" .. tostring(dome_c.hall_force))
    end

    local lock_un
    ctx.after(400, function()
      local ids = colony.colonist_ids(c)
      lock_un = ids[1]
      if lock_un then c.locks[lock_un] = "chop" end
    end)

    ctx.after(500, function()
      local exp = {
        colony_id = c.id, colonists = colony.live_colonists(c), houses = #colony.house_list(c),
        huts = count(c.huts), plots = count(c.plots), crates = count(c.crates),
        armories = count(c.armories), armory_un = armory_e and armory_e.valid and armory_e.unit_number or nil,
        patrol_posts = count(c.patrol_posts), post_un = post_e and post_e.valid and post_e.unit_number or nil,
        post_wp_x = p.x - 3,
        ghosts = count(c.ghosts), repairs = count(c.repairs), chunks = chunks_of(c),
        crate_un = crate.unit_number, lock_un = lock_un, next_colony_id = storage.next_colony_id,
        hall_fish = hall.get_item_count("raw-fish"), scheduled = count(storage.scheduled), schema = storage.schema,
        labels = count(storage.unit_labels), unit_state = count(storage.unit_state),
        links = (storage.links ~= nil) and count(storage.links) or -1,
        next_link_id = storage.next_link_id,
        -- #63: plain core identity of both colonies (no LuaEntity / LuaForce may go into persist_expected).
        hall_un = c.hall_un, hall_force = c.hall_force, hall_un_actual = c.hall and c.hall.unit_number or nil,
        dome_un = dome and dome.valid and dome.unit_number or nil,
        dome_colony_id = dome_c and dome_c.id or nil,
        dome_hall_un = dome_c and dome_c.hall_un or nil,
        dome_hall_force = dome_c and dome_c.hall_force or nil,
        dome_count = dome_c and #colony.dome_list(dome_c) or nil,
      }
      storage.persist_expected = exp
      ctx.log(string.format("pre-save: pop=%d houses=%d huts=%d plots=%d crates=%d ghosts=%d repairs=%d chunks=%d",
        exp.colonists, exp.houses, exp.huts, exp.plots, exp.crates, exp.ghosts, exp.repairs, exp.chunks))
      ctx.check("both colonies exist before the save", count(storage.colonies) == 2, count(storage.colonies))
      ctx.check("core identities are plain, serialisable data",
        type(exp.hall_un) == "number" and type(exp.hall_force) == "string"
          and type(exp.dome_hall_un) == "number" and type(exp.dome_hall_force) == "string",
        exp.hall_un .. "/" .. exp.hall_force .. " " .. tostring(exp.dome_hall_un) .. "/" .. tostring(exp.dome_hall_force))
      ctx.check("colonists exist before the save", exp.colonists > 0, exp.colonists)
      ctx.check("crate filter set before the save", exp.crates > 0 and c.crates[crate.unit_number].filters[1].item == "coal")
      ctx.check("ghost registered before the save", exp.ghosts > 0, exp.ghosts)
      ctx.check("damage registered before the save", exp.repairs > 0, exp.repairs)
      ctx.check("scheduler has pending work before the save", exp.scheduled > 0, exp.scheduled)
      ctx.check("colonists have state before the save", exp.unit_state > 0, exp.unit_state)
      ctx.check("freight link registry exists before the save", exp.links >= 0, exp.links)
      -- server_save only writes in multiplayer, so scripts/save-load.sh runs phase 1 as a headless server.
      game.server_save("colony-persist")
      ctx.log("save requested; is_multiplayer=" .. tostring(game.is_multiplayer()))
      ctx.check("auto-save requested", true)
    end)
  end,
})

core.register("m1_persist_load", {
  issue = 39, auto = false, desc = "post-load assertions for the save/load round-trip", usage = "",
  run = function(ctx)
    local exp = storage.persist_expected
    ctx.check("expected state was written before the save", exp ~= nil)
    if not exp then return ctx.finish() end
    local c = storage.colonies[exp.colony_id]
    ctx.check("colony survived the round-trip", c ~= nil)
    if not c then return ctx.finish() end
    ctx.check("hall is valid after load", c.hall and c.hall.valid)
    ctx.check("schema unchanged", storage.schema == exp.schema, storage.schema)
    ctx.check("no colony was created twice", count(storage.colonies) == 2, count(storage.colonies))
    ctx.check("hall-founded colony kept its plain core identity", c.hall_un == exp.hall_un
      and c.hall_un == c.hall.unit_number and c.hall_force == exp.hall_force,
      tostring(c.hall_un) .. "/" .. tostring(c.hall_force))

    -- #63: the second colony's core is a Habitat Dome; its unit number, id, domes registry and plain force
    -- string all came back from storage unchanged.
    local dc = exp.dome_colony_id and storage.colonies[exp.dome_colony_id]
    ctx.check("dome-founded colony survived the round-trip", dc ~= nil)
    if dc then
      ctx.check("dome colony's hall is still the same dome", dc.hall and dc.hall.valid
        and dc.hall.unit_number == exp.dome_un, tostring(dc.hall and dc.hall.unit_number))
      ctx.check("dome colony kept its plain core identity", dc.hall_un == exp.dome_hall_un
        and dc.hall_un == dc.hall.unit_number and dc.hall_force == exp.dome_hall_force
        and dc.hall_force == "player", tostring(dc.hall_un) .. "/" .. tostring(dc.hall_force))
      ctx.check("dome registry survived", dc.domes and dc.domes[exp.dome_un] ~= nil
        and #colony.dome_list(dc) == exp.dome_count, "#" .. tostring(dc.domes and #colony.dome_list(dc)))
    end
    ctx.check("next colony id unchanged", storage.next_colony_id == exp.next_colony_id, storage.next_colony_id)
    ctx.check("freight link registry survived the round-trip", storage.links ~= nil
      and count(storage.links) == exp.links and storage.next_link_id == exp.next_link_id,
      tostring(storage.next_link_id))
    ctx.check("colonists survived", colony.live_colonists(c) == exp.colonists,
      colony.live_colonists(c) .. "/" .. exp.colonists)
    ctx.check("houses survived", #colony.house_list(c) == exp.houses)
    ctx.check("huts survived", count(c.huts) == exp.huts)
    ctx.check("plots survived", count(c.plots) == exp.plots)
    ctx.check("crates survived", count(c.crates) == exp.crates)
    ctx.check("armory registry survived", count(c.armories) == exp.armories, count(c.armories))
    local armory_rec = exp.armory_un and c.armories[exp.armory_un]
    ctx.check("armory entity + manning limit survived", armory_rec ~= nil and armory_rec.entity.valid
      and armory_rec.limit == 1 and armory_rec.inflight ~= nil and armory_rec.equipped ~= nil,
      armory_rec and ("limit=" .. tostring(armory_rec.limit)) or "no armory record")
    ctx.check("armory gear survived", armory_rec ~= nil and armory_rec.entity.get_item_count("colony-rifle") == 1,
      armory_rec and tostring(armory_rec.entity.get_item_count("colony-rifle")) or "no armory")
    ctx.check("patrol post registry survived", count(c.patrol_posts) == exp.patrol_posts, count(c.patrol_posts))
    local post_rec = exp.post_un and c.patrol_posts[exp.post_un]
    ctx.check("patrol post entity + ordered waypoints survived", post_rec ~= nil and post_rec.entity.valid
      and #post_rec.waypoints == 2 and post_rec.waypoints[1].x == exp.post_wp_x,
      post_rec and ("waypoints=" .. #post_rec.waypoints) or "no post")
    local crate = c.crates[exp.crate_un]
    ctx.check("crate filters survived", crate ~= nil and crate.filters[1] ~= nil and crate.filters[1].item == "coal",
      crate and crate.filters[1] and crate.filters[1].item)
    ctx.check("ghost registry survived", count(c.ghosts) == exp.ghosts, count(c.ghosts))
    local ghosts_valid = true
    for _, g in pairs(c.ghosts or {}) do if not g.valid then ghosts_valid = false end end
    ctx.check("ghost entities are still valid", ghosts_valid)
    local tagged_ghost
    for _, g in pairs(c.ghosts or {}) do if g.valid and g.tags and g.tags[tags.TAG] then tagged_ghost = g end end
    ctx.check("blueprint tags survived the save", tagged_ghost ~= nil
      and tagged_ghost.tags[tags.TAG].machine == true and tagged_ghost.tags[tags.TAG].collect == false,
      tagged_ghost and tostring(tagged_ghost.tags[tags.TAG].collect) or "no tagged ghost")
    ctx.check("damage registry survived", count(c.repairs) == exp.repairs, count(c.repairs))
    ctx.check("job lock survived", exp.lock_un ~= nil and c.locks[exp.lock_un] == "chop",
      exp.lock_un and c.locks[exp.lock_un])
    ctx.check("territory index survived", chunks_of(c) == exp.chunks, chunks_of(c) .. "/" .. exp.chunks)
    ctx.check("colonist unit state survived", count(storage.unit_state) == exp.unit_state, count(storage.unit_state))
    local st = exp.lock_un and storage.unit_state[exp.lock_un]
    ctx.check("locked colonist kept its state", st ~= nil and st.colony_id == c.id)
    local labels_ok = true
    for un in pairs(storage.unit_state or {}) do
      local lbl = storage.unit_labels[un]
      local obj = lbl and (type(lbl) == "table" and lbl.obj or lbl)   -- labels are {mode, obj} since schema 28
      if obj and not obj.valid then labels_ok = false end
    end
    ctx.check("job labels survived", labels_ok)
    ctx.check("hall stock survived", c.hall.get_item_count("raw-fish") <= exp.hall_fish,
      c.hall.get_item_count("raw-fish") .. "/" .. exp.hall_fish)
    ctx.check("scheduler queue survived", count(storage.scheduled) > 0, count(storage.scheduled))

    -- Prove the mod's scheduler and evaluation loop still run after load, not just that tables exist.
    scheduler.after(60, "persist.probe", {})
    ctx.after(200, function()
      ctx.check("scheduler fires after load", (storage.persist_probe or 0) >= 1, storage.persist_probe)
      ctx.check("desirability is being evaluated after load", c.d ~= nil)
      ctx.finish()
    end)
  end,
})

return core
