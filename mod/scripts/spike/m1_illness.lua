-- M1 illness spike (#47). Phase 1: three colonists have Smoker's Lung; haulers bring Herbal Medicine from the hall
-- to a Clinic, a doctor goes on duty and the three are cured, a medicine each. Phase 2: no medicine anywhere, and a
-- colonist whose lung has nearly run its course dies of it - counted once, as an illness death. Phase 3: a house
-- is given only nearly-spoiled food; its occupants catch Food Poisoning, which then passes by itself.
-- Run: TICKS=6600 scripts/headless-spike.sh m1_illness
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local illness = require("scripts.model.illness")

core.register("m1_illness", {
  issue = 47, auto = true, desc = "illness: clinic cures lung with medicine, untreated lung kills, rotten food poisons", usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(60, "grass-1")
    s.always_day, s.freeze_daytime = true, true
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end
    storage.interval_override = 150
    local hall = build("colony-town-hall", {p.x, p.y})
    local c
    for _, col in pairs(storage.colonies) do c = col end
    ctx.check("colony registered", c ~= nil and hall and hall.valid)
    if not c then return ctx.finish() end
    c.accept_migrants = false
    local cabins = {}
    for i = 0, 1 do cabins[#cabins + 1] = build("colony-housing-cabin", {p.x - 6 + i * 12, p.y - 9}) end
    hall.insert{name = "raw-fish", count = 1500}
    hall.insert{name = illness.MEDICINE, count = 20}
    local clinic = build("colony-clinic", {p.x + 8, p.y + 6})
    ctx.check("clinic registered as a labour hut (job heal)", clinic and clinic.valid and c.huts[clinic.unit_number] ~= nil
      and c.huts[clinic.unit_number].job == "heal")
    if not (clinic and clinic.valid) then return ctx.finish() end
    for _ = 1, 8 do colony.spawn_colonist(c) end
    local ids = {}
    for un in pairs(c.colonists) do ids[#ids + 1] = un end
    table.sort(ids)

    local st = {doctor = false, label = {}, sickness_part = 0, poisoned = {}, poison_seen = false}
    storage.sick = storage.sick or {}
    for i = 1, 3 do storage.sick[ids[i]] = {kind = "lung", age = 1} end
    local function medicine_total()
      return hall.get_item_count(illness.MEDICINE) + (clinic.valid and clinic.get_item_count(illness.MEDICINE) or 0)
    end
    local function sample()
      for un in pairs(c.colonists) do
        local u = storage.unit_state[un]
        if u and u.job == "heal" and u.state == "working" then st.doctor = true end
        local rec = storage.sick[un]
        if rec and rec.kind == "poison" then st.poisoned[un] = true; st.poison_seen = true
        elseif st.poisoned[un] and not rec and c.colonists[un] then st.recovered = true end
      end
      local cs = clinic.valid and clinic.custom_status
      local lab = cs and cs.label and cs.label[1]
      if lab then st.label[lab] = true end
      st.sickness_part = math.min(st.sickness_part, c.d_parts and c.d_parts.sickness or 0)
    end
    local t0 = game.tick
    local function every()
      ctx.after(30, function()
        sample()
        if game.tick - t0 < 5800 then every() end
      end)
    end
    every()

    ctx.after(1800, function()
      local left = 0
      for i = 1, 3 do if storage.sick[ids[i]] then left = left + 1 end end
      ctx.check("1 a doctor went on duty at the clinic", st.doctor)
      ctx.check("1 the clinic said it was treating", st.label["colony-status.clinic-treating"] == true)
      ctx.check("1 all three lung patients cured", left == 0, left .. " still sick")
      ctx.check("1 one medicine per cure", medicine_total() == 17, medicine_total() .. " medicine left of 20")
      ctx.check("1 being sick cost desirability", st.sickness_part < 0, string.format("%.3f", st.sickness_part))
      -- Phase 2: no medicine; colonist 4's lung is about to kill.
      if clinic.valid then clinic.remove_item{name = illness.MEDICINE, count = 100} end
      hall.remove_item{name = illness.MEDICINE, count = 100}
      for _, u in pairs(storage.unit_state) do
        for _, cr in ipairs(u.carry or {}) do if cr.item == illness.MEDICINE then cr.count = 0 end end
      end
      storage.sick[ids[4]] = {kind = "lung", age = illness.DISEASES.lung.fatal_after - 2}
      st.fallen0 = c.fallen or 0
    end)

    ctx.after(2700, function()
      ctx.check("2 untreated lung kills", c.colonists[ids[4]] == nil and storage.sick[ids[4]] == nil)
      ctx.check("2 counted once, as an illness death", (c.fallen or 0) == st.fallen0 + 1 and c.last_death == "illness",
        tostring(c.fallen) .. " dead, last " .. tostring(c.last_death))
      -- Phase 3: cabin 1 holds only nearly-spoiled forage.
      local cab = cabins[1]
      cab.clear_items_inside()
      local ok = pcall(function() cab.insert{name = "colony-forage", count = 40, spoil_percent = 0.9} end)
      local stack = cab.get_inventory(defines.inventory.chest).find_item_stack("colony-forage")
      ctx.check("3 rotten forage stocked (spoil_percent settable)", ok and stack and stack.spoil_percent >= illness.ROTTEN,
        stack and string.format("%.2f", stack.spoil_percent) or "no stack")
    end)

    ctx.after(5900, function()
      local n, still = 0, 0
      for un in pairs(st.poisoned) do
        n = n + 1
        if storage.sick[un] then still = still + 1 end
      end
      ctx.check("3 a rotten meal poisons the house's occupants", n > 0, n .. " poisoned")
      ctx.check("3 poisoning passes by itself (no medicine in town)", st.recovered == true, still .. " of " .. n .. " sick at the end")
      ctx.finish()
    end)
  end,
})
