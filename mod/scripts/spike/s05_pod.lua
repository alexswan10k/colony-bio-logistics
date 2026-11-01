-- SPIKE #5: Cryo-pod item feasibility: item-with-tags + spoilage + result_is_always_fresh recipes.
-- /spike run s05_pod
-- Needs startup setting "colony-spike-protos" (default on). Questions: do tags survive? does item-with-tags spoil?
-- does a refresh recipe reset spoilage? does it preserve tags (expected: NO)?
local core = require("scripts.spike.core")

core.register("s05_pod", {
  issue = 5, auto = true, desc = "pods: tags + spoilage + refresh recipe", usage = "",
  run = function(ctx)
    ctx.flat_area(12)
    local s, p = ctx.surface, ctx.position
    ctx.check("pod prototypes loaded", prototypes.item["colony-pod-plain"] ~= nil and prototypes.item["colony-pod-tagged"] ~= nil)
    local chest = s.create_entity{name = "steel-chest", position = {p.x - 6, p.y}, force = "player"}
    local inv = chest.get_inventory(defines.inventory.chest)
    inv.insert{name = "colony-pod-tagged", count = 1}
    inv.insert{name = "colony-pod-plain", count = 1}
    local tagged, plain
    for i = 1, #inv do
      local st = inv[i]
      if st.valid_for_read then
        if st.name == "colony-pod-tagged" then tagged = st elseif st.name == "colony-pod-plain" then plain = st end
      end
    end
    ctx.probe("tagged.is_item_with_tags", function() return tagged.is_item_with_tags end)
    ctx.probe("tagged.set_tag/get_tag roundtrip", function()
      tagged.set_tag("colonist", {name = "Ann", skill = 3}); local t = tagged.get_tag("colonist"); return t and t.name end)
    ctx.probe("tagged.spoil_percent readable", function() return tagged.spoil_percent end)
    ctx.probe("plain.spoil_percent readable", function() return plain.spoil_percent end)
    ctx.probe("plain.spoil_percent writable (set 0.5)", function() plain.spoil_percent = 0.5; return plain.spoil_percent end)
    ctx.probe("tagged.spoil_percent writable (set 0.5)", function() tagged.spoil_percent = 0.5; return tagged.spoil_percent end)
    ctx.log("tag/spoil percent set to 0.5; running refresh recipes in powered assemblers for 10s")

    ctx.power_at(p)
    local function machine(dx, recipe, item_name)
      local am = s.create_entity{name = "assembling-machine-2", position = {p.x + dx, p.y + 1.5}, force = "player"}
      am.set_recipe(recipe)
      am.insert{name = "iron-plate", count = 5}
      am.get_inventory(defines.inventory.crafter_input).insert{name = item_name, count = 1}
      return am
    end
    local am_plain = machine(0, "colony-pod-plain-refresh", "colony-pod-plain")
    local am_tag = machine(4, "colony-pod-tagged-refresh", "colony-pod-tagged")
    -- set test state on the stacks inside the machines
    for _, am in ipairs({am_plain, am_tag}) do
      local ing = am.get_inventory(defines.inventory.crafter_input)
      for i = 1, #ing do
        local st = ing[i]
        if st.valid_for_read and st.name:find("colony%-pod") then
          pcall(function() st.spoil_percent = 0.5 end)
          if st.name == "colony-pod-tagged" then pcall(function() st.set_tag("colonist", {name = "Ann"}) end) end
        end
      end
    end
    ctx.after(60 * 10, function()
      local function out(am, label)
        local o = am.get_output_inventory()
        for i = 1, #o do
          local st = o[i]
          if st.valid_for_read then
            local tag = "n/a"
            if st.name == "colony-pod-tagged" then local ok, t = pcall(st.get_tag, "colonist"); tag = ok and (t and t.name or "LOST") or "err" end
            local ok, sp = pcall(function() return st.spoil_percent end)
            ctx.log(label, "output:", st.name, "spoil_percent=", ok and sp or "err", "tag=", tag)
            return sp, tag
          end
        end
        ctx.log(label, "produced nothing (power? recipe?)")
      end
      local sp1 = out(am_plain, "plain")
      ctx.check("refresh recipe resets spoilage (plain)", sp1 ~= nil and sp1 < 0.1, tostring(sp1))
      local sp2, tag2 = out(am_tag, "tagged")
      ctx.check("refresh recipe resets spoilage (tagged)", sp2 ~= nil and sp2 < 0.1, tostring(sp2))
      ctx.check("refresh recipe PRESERVES colonist tag", tag2 ~= nil and tag2 ~= "LOST", tostring(tag2))
      ctx.log("If tag LOST: pods must be anonymous items; colonist identity can't ride through recipes (see #5 fallback).")
      ctx.finish()
    end)
  end,
})
