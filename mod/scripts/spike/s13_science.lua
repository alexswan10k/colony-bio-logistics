-- SPIKE #13: Colony Science feasibility (Issues #19 and #42)
-- /spike run s13_science
-- Questions:
-- 1. Does lab whitelist work (vanilla labs reject colony packs, colony lab rejects vanilla packs)?
-- 2. Can lab research progress colony tech?
-- 3. Does unpowering a lab stop research and repowering resume?
-- 4. How does spoilage behave inside a lab? Does it enter lab_trash? Does research continue?
-- 5. Can custom_status be set with entity_status_diode?
-- 6. Is tech.saved_progress writable?
local core = require("scripts.spike.core")

core.register("s13_science", {
  issue = 19, auto = true, desc = "science: lab whitelist, staffing power/spoilage, tech progress", usage = "",
  run = function(ctx)
    ctx.flat_area(20)
    local s, p = ctx.surface, ctx.position
    local force = game.forces["player"]
    force.enable_all_technologies()

    -- 1. Prototypes check
    ctx.check("spike prototypes loaded",
      prototypes.item["colony-test-pack"] ~= nil
      and prototypes.entity["colony-test-lab"] ~= nil
      and prototypes.technology["colony-test-tech"] ~= nil)

    local vanilla_lab = s.create_entity{name = "lab", position = {p.x - 4, p.y - 4}, force = force}
    local custom_lab = s.create_entity{name = "colony-test-lab", position = {p.x + 4, p.y - 4}, force = force}

    -- 2. Whitelist checks
    ctx.check("vanilla lab cannot insert colony pack",
      vanilla_lab.can_insert("colony-test-pack") == false,
      "can_insert=" .. tostring(vanilla_lab.can_insert("colony-test-pack")))
    local v_ins = vanilla_lab.insert{name = "colony-test-pack", count = 5}
    ctx.check("vanilla lab inserted 0 colony packs", v_ins == 0, "inserted=" .. v_ins)

    ctx.check("custom lab can insert colony pack",
      custom_lab.can_insert("colony-test-pack") == true,
      "can_insert=" .. tostring(custom_lab.can_insert("colony-test-pack")))
    local c_ins = custom_lab.insert{name = "colony-test-pack", count = 5}
    ctx.check("custom lab inserted colony packs", c_ins == 5, "inserted=" .. c_ins)

    ctx.check("custom lab cannot insert vanilla pack",
      custom_lab.can_insert("automation-science-pack") == false,
      "can_insert=" .. tostring(custom_lab.can_insert("automation-science-pack")))

    -- 3. Probe lab inventories
    ctx.probe("lab inventories", function()
      local invs = {}
      for k, v in pairs(defines.inventory) do
        local ok, inv = pcall(function() return custom_lab.get_inventory(v) end)
        if ok and inv ~= nil then invs[#invs + 1] = k .. "=" .. tostring(#inv) end
      end
      return table.concat(invs, ", ")
    end)

    -- 4. Custom status check
    ctx.probe("custom_status diode table", function()
      local ok, err = pcall(function()
        custom_lab.custom_status = {
          diode = defines.entity_status_diode.green,
          label = {"", "Staffed: 2 scholars"},
        }
        return custom_lab.custom_status ~= nil
      end)
      return ok and tostring(err) or tostring(err)
    end)

    -- 5. Power labs
    ctx.power_at({x = p.x - 4, y = p.y - 4})
    ctx.power_at({x = p.x + 4, y = p.y - 4})

    -- 6. Test research progress
    force.research_queue = {"colony-test-tech"}
    local p_start = force.research_progress

    ctx.after(120, function()
      local p_active = force.research_progress
      ctx.check("active lab progresses colony research", p_active > p_start,
        "progress: " .. tostring(p_start) .. " -> " .. tostring(p_active))

      -- Test unpowered lab
      for _, e in ipairs(s.find_entities_filtered{type = {"electric-pole", "electric-energy-interface"}}) do
        e.destroy()
      end
      custom_lab.energy = 0
      local p_stop_start = force.research_progress

      ctx.after(120, function()
        local p_stop_end = force.research_progress
        ctx.check("unpowered lab stops research", p_stop_end == p_stop_start,
          "progress: " .. tostring(p_stop_start) .. " -> " .. tostring(p_stop_end))

        -- Repower custom_lab
        ctx.power_at({x = p.x + 4, y = p.y - 4})

        ctx.after(120, function()
          local p_repower = force.research_progress
          ctx.check("repowered lab resumes research", p_repower > p_stop_end,
            "progress: " .. tostring(p_stop_end) .. " -> " .. tostring(p_repower))

          -- 7. Test tech.saved_progress direct write
          local t2 = force.technologies["colony-test-tech-2"]
          t2.saved_progress = 0.5
          ctx.check("tech.saved_progress directly writable", t2.saved_progress == 0.5,
            "saved_progress=" .. tostring(t2.saved_progress))

          -- 8. Test spoilage in lab
          custom_lab.insert{name = "colony-test-spoil-pack", count = 2}
          local lab_in = custom_lab.get_inventory(defines.inventory.lab_input)
          local lab_trash = custom_lab.get_inventory(defines.inventory.lab_trash)

          ctx.after(150, function()
            local spoil_in = lab_in.get_item_count("spoilage")
            local spoil_trash = lab_trash and lab_trash.get_item_count("spoilage") or 0
            ctx.check("spoilage appears in lab", spoil_in > 0 or spoil_trash > 0,
              "in=" .. tostring(spoil_in) .. " trash=" .. tostring(spoil_trash))

            local removed = custom_lab.remove_item{name = "spoilage", count = 1}
            ctx.check("remove_item extracts from lab_trash", removed == 1, "removed=" .. tostring(removed))

            -- Lab can still research when spoilage is in trash/input
            custom_lab.insert{name = "colony-test-pack", count = 5}
            local p_pre = force.research_progress

            ctx.after(120, function()
              local p_post = force.research_progress
              ctx.check("lab progresses even with spoilage present", p_post > p_pre,
                "progress: " .. tostring(p_pre) .. " -> " .. tostring(p_post))
              ctx.finish()
            end)
          end)
        end)
      end)
    end)
  end,
})
