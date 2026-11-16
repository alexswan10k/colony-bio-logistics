-- M3 turret ammo spike (#59): a vanilla gun turret is opted in and hand-fed magazines by a colonist.
-- The engine-only questions: does entity-level get_item_count see the turret ammo inventory (or do we need
-- the cached-available fallback), does get_output_inventory expose loaded ammo (it must not), and do the
-- defines/GUI anchors exist in this exact Steam build. The rest is the existing machine-requester path.
-- Run: TICKS=3600 scripts/headless-spike.sh m3_turret
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local gui = require("scripts.gui")
local work = require("scripts.work")
local jobs = require("scripts.model.jobs")
local territory = require("scripts.territory")
local turret_model = require("scripts.model.turret")

core.register("m3_turret", {
  issue = 59, auto = true,
  desc = "opt-in ammo turret: engine facts, default row, demand seed, real haul, no top-up loop",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(64, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end

    -- ---------- 1. engine facts (the beliefs the planner could not confirm from docs alone) ----------
    ctx.check("defines.inventory.turret_ammo exists in this build", defines.inventory.turret_ammo ~= nil,
      tostring(defines.inventory.turret_ammo))
    ctx.log("fact: defines.inventory.artillery_turret_ammo = "
      .. tostring(defines.inventory.artillery_turret_ammo) .. " (a separate slice; not used here)")
    ctx.check("defines.relative_gui_type.turret_gui exists in this build", defines.relative_gui_type.turret_gui ~= nil,
      tostring(defines.relative_gui_type.turret_gui))
    ctx.check("ammo-turret is in the opt-in GUI/marker set",
      gui.MACHINE_GUIS["ammo-turret"] == "turret_gui", tostring(gui.MACHINE_GUIS["ammo-turret"]))

    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local c = hall and hall.valid and storage.colonies[territory.owner_at(s.index, p)] or nil
    ctx.check("colony registered", c ~= nil)
    if not (c and hall and hall.valid) then return ctx.finish() end
    c.accept_migrants = false
    storage.interval_override = 600

    local turret = build("gun-turret", {p.x + 6, p.y})
    ctx.check("gun-turret built inside the territory", turret and turret.valid and turret.type == "ammo-turret",
      turret and turret.name)
    if not (turret and turret.valid) then return ctx.finish() end

    local inserted = turret.insert{name = "firearm-magazine", count = 5}
    local ammo_inv = turret.get_inventory(defines.inventory.turret_ammo)
    local entity_count = turret.get_item_count("firearm-magazine")
    local inv_count = ammo_inv and ammo_inv.get_item_count("firearm-magazine") or -1
    local out_inv = turret.get_output_inventory()
    local out_ammo = out_inv and out_inv.get_item_count("firearm-magazine") or 0
    ctx.check("turret.insert put 5 magazines into the ammo inventory", inserted == 5, "inserted=" .. tostring(inserted))
    ctx.check("entity-level get_item_count sees the loaded magazines", entity_count == 5,
      "entity=" .. tostring(entity_count) .. " inventory=" .. tostring(inv_count))
    ctx.check("turret_ammo inventory agrees", inv_count == 5, "inventory=" .. tostring(inv_count))
    -- Engine fact (2.1.24): a turret's "output inventory" IS its ammo inventory, so a collect=true machine
    -- record would let haulers steal loaded rounds. The protection is the collect=false default (checked
    -- below) plus hiding the collect checkbox in the supply panel - both live in model/turret.defaults.
    ctx.log("fact: turret get_output_inventory = " .. tostring(out_inv) .. " (ammo=" .. tostring(out_ammo)
      .. ") - collect=false and the hidden checkbox are what keep rounds in the gun")
    -- Empty the probe ammo so the opt-in checks start from a genuinely starved turret.
    turret.remove_item{name = "firearm-magazine", count = 5}
    ctx.check("turret emptied for the feed test", turret.get_item_count("firearm-magazine") == 0,
      "count=" .. tostring(turret.get_item_count("firearm-magazine")))

    -- ---------- 2. opt-in: registry record, default row, collect/priority, demand seed ----------
    local m = colony.set_machine(c, turret, true)
    ctx.check("opt-in creates a machine record", m ~= nil and c.machines[turret.unit_number] == m)
    ctx.check("the default ammo row is firearm-magazine x10",
      m and m.requests[1] and m.requests[1].item == "firearm-magazine" and m.requests[1].count == 10,
      m and m.requests[1] and (m.requests[1].item .. "/" .. m.requests[1].count) or "missing")
    ctx.check("collect=false (never empty a turret back into storage)", m and m.collect == false)
    ctx.check("building priority is 3 (ahead of ordinary machines, below houses)",
      m and m.priority == turret_model.DEFAULT_BUILDING_PRIORITY)
    ctx.check("the badge was created", m and m.badge and m.badge.valid)
    local demand = colony.demand_table(c)
    ctx.check("the ammo row became a #90 demand seed", (demand["firearm-magazine"] or 0) >= 10,
      "demand=" .. tostring(demand["firearm-magazine"]))

    -- ---------- 3. demand path: cached need -> machine offer -> matched haul task ----------
    work.refresh_machine(c, m)
    ctx.check("a sweep caches the ammo deficit in m.need",
      m.need and m.need[1] and m.need[1].item == "firearm-magazine" and m.need[1].count > 0,
      m and m.need and m.need[1] and (m.need[1].item .. "/" .. m.need[1].count) or "no need")
    hall.insert{name = "firearm-magazine", count = 10}
    local before = hall.get_item_count("firearm-magazine")
    hall.insert{name = "colony-preserved-meat", count = 200}
    c.storage_cache, c.storage_tick = nil, nil     -- make the freshly inserted magazines visible this tick
    local task = work.find_haul_task(c, nil, hall.position)
    ctx.check("a haul task targets the turret", task ~= nil and task.machine == m,
      task and (task.kind .. "/" .. tostring(task.machine == m)) or "none")
    ctx.check("the load is magazines from colony stock", task and task.load and task.load[1]
      and task.load[1].item == "firearm-magazine", task and task.load and task.load[1] and task.load[1].item or "none")
    ctx.check("the request rides the request band at building priority 3",
      task and task.priority == 4 and task.building_priority == 3,
      task and (tostring(task.priority) .. "/" .. tostring(task.building_priority)) or "none")

    -- ---------- 4. end-to-end feed: the natural job assignment picks the turret, walks, inserts ----------
    -- Only haul is enabled and the turret is the sole requester, so the new colonist must be handed its ammo
    -- task by work.assign (called inside spawn_colonist) - no hand-driven trip, this is the shipped path.
    c.priority = c.priority or jobs.defaults()
    for _, job in ipairs(jobs.JOBS) do jobs.set(c.priority, job, job == "haul" and 1 or 0) end
    local colonist = colony.spawn_colonist(c)
    ctx.check("a colonist spawned", colonist and colonist.valid)
    if not (colonist and colonist.valid) then return ctx.finish() end
    local st = storage.unit_state[colonist.unit_number]
    ctx.check("the colonist was assigned the turret ammo haul", st and st.job == "haul"
      and st.dest_entity == turret, st and (st.job .. "/" .. tostring(st.dest_entity == turret)) or "no state")
    ctx.after(900, function()
      if not (turret.valid and hall.valid and m.entity.valid) then
        ctx.check("turret and hall are still alive at delivery", false)
        ctx.finish()
        return
      end
      local loaded = turret.get_item_count("firearm-magazine")
      local after = hall.get_item_count("firearm-magazine")
      ctx.check("the colonist physically inserted magazines into the turret", loaded > 0,
        "turret=" .. tostring(loaded) .. " hall " .. tostring(before) .. "->" .. tostring(after))
      ctx.check("the magazines left colony stock", after < before, before .. "->" .. after)
      ctx.check("the same number arrived (no teleport duplication)", loaded == before - after,
        "loaded=" .. loaded .. " moved=" .. tostring(before - after))
      ctx.check("inflight settled back to zero after delivery", (m.inflight["firearm-magazine"] or 0) == 0,
        "inflight=" .. tostring(m.inflight["firearm-magazine"]))

      -- ---------- 5. no top-up loop once the turret is full ----------
      -- Top up to exactly the target, then sweep and ask again: a full turret asks for nothing.
      if loaded < 10 then turret.insert{name = "firearm-magazine", count = 10 - loaded} end
      work.refresh_machine(c, m)
      ctx.check("a full turret has no cached need", m.need == nil, "need=" .. tostring(m.need))
      c.storage_cache, c.storage_tick = nil, nil
      local no_offer = work.find_haul_task(c, nil, hall.position)
      ctx.check("no further ammo offer is produced", not (no_offer and no_offer.machine == m),
        no_offer and no_offer.machine and "still offering" or "none")

      -- ---------- 6. opt-out / destruction ----------
      colony.set_machine(c, turret, false)
      ctx.check("opting out clears need and badge", m.enabled == false and m.need == nil
        and (not m.badge or not m.badge.valid))
      local d2 = colony.demand_table(c)
      ctx.check("opting out removes the ammo demand seed", (d2["firearm-magazine"] or 0) < 10,
        "demand=" .. tostring(d2["firearm-magazine"]))
      -- Destroy an opted-in turret mid-haul: the existing entity.valid guards must keep the loop safe.
      local t2 = build("gun-turret", {p.x + 10, p.y})
      if t2 and t2.valid then
        hall.insert{name = "firearm-magazine", count = 5}
        c.storage_cache, c.storage_tick = nil, nil
        local m2 = colony.set_machine(c, t2, true)
        work.refresh_machine(c, m2)
        local t2task = work.find_haul_task(c, nil, hall.position)
        ctx.check("the second turret got its own ammo haul", t2task ~= nil and t2task.machine == m2)
        if t2task and t2task.machine == m2 then
          work.start_haul(c, colonist.unit_number, colonist, t2task, "hauler")
        end
        t2.destroy()   -- a destroyed target must not leave a live offer or crash the sweep
      end
      ctx.after(600, function()
        ctx.check("destroying a turret mid-haul does not crash the colony", true)
        ctx.finish()
      end)
    end)
  end,
})
