-- M2 freight links (#52): the crate-pair slice. Two colonies, one export crate and one import crate, bound
-- through the real player path (colony.bind_link) and exercised through the real haul planner. The rail leg
-- itself belongs to the player and was proven by s16_links; this spike drives the two ends.
-- Run: TICKS=3600 scripts/headless-spike.sh m2_link
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local work = require("scripts.work")
local crates = require("scripts.model.crates")
local links = require("scripts.model.links")
local tags = require("scripts.model.tags")

core.register("m2_link", {
  issue = 52, auto = true,
  desc = "freight crate pair: bind, tags, export reserve, import hauling, self-link, destruction cleanup",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(150, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    storage.interval_override = 150
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end

    ctx.check("freight crate prototype registered", prototypes.entity["colony-freight-crate"] ~= nil)
    ctx.check("link registry migrated", storage.links ~= nil and storage.next_link_id ~= nil)

    local hallA = build("colony-town-hall", {p.x - 110, p.y})
    local hallB = build("colony-town-hall", {p.x + 110, p.y})
    local A, B
    for _, c in pairs(storage.colonies) do
      if c.hall and c.hall.valid then
        if c.hall.position.x < p.x then A = c else B = c end
      end
    end
    ctx.check("two halls made two colonies", A ~= nil and B ~= nil and A.id ~= B.id,
      A and B and (A.id .. "/" .. B.id) or "missing")
    if not (A and B) then return ctx.finish() end
    A.accept_migrants, B.accept_migrants = false, false

    -- One freight crate in each colony, registered as an unpaired link half.
    local crateA = build("colony-freight-crate", {p.x - 110 + 10, p.y + 10})
    local crateB = build("colony-freight-crate", {p.x + 110 - 10, p.y + 10})
    local ra, rb = A.crates[crateA.unit_number], B.crates[crateB.unit_number]
    ctx.check("both freight crates registered as link halves",
      ra ~= nil and rb ~= nil and ra.kind == crates.LINK and rb.kind == crates.LINK
        and ra.role == nil and rb.role == nil)
    if not (ra and rb) then return ctx.finish() end

    -- Self-link rejection goes through the same adapter the panel button calls.
    local crateA2 = build("colony-freight-crate", {p.x - 110 + 14, p.y + 10})
    local ra2 = A.crates[crateA2.unit_number]
    local ok_self, why_self = colony.bind_link(ra, ra2)
    ctx.check("two crates in one colony cannot be linked", ok_self == false and why_self == "link-self",
      tostring(why_self))
    ctx.check("the rejected pair left both halves unpaired", ra.link == nil and ra2.link == nil)
    crateA2.destroy()

    -- The real bind path: A exports, B imports.
    local ok, id = colony.bind_link(ra, rb)
    ctx.check("bind_link paired the two crates", ok == true and id ~= nil, tostring(id))
    ctx.check("roles are export in A and import in B",
      ra.role == links.EXPORT and rb.role == links.IMPORT)
    local rec = storage.links[id]
    ctx.check("the link record holds both colony/un slots",
      rec ~= nil and rec.a.colony_id == A.id and rec.a.un == crateA.unit_number
        and rec.b.colony_id == B.id and rec.b.un == crateB.unit_number)
    ctx.check("the peer resolves in both directions",
      colony.link_peer(ra) == rec.b and colony.link_peer(rb) == rec.a)

    -- Tag round-trip: the pair identity rides the one namespaced key alongside dense filter rows.
    crates.set_filter(ra.filters, 1, "iron-plate"); crates.set_count(ra.filters, 1, 10)
    crates.set_filter(rb.filters, 1, "coal"); crates.set_count(rb.filters, 1, 20)
    local dict = colony.entity_tags(crateA)
    local payload = dict and tags.decode(dict)
    ctx.check("the source crate's tags carry link id + role", payload and payload.crate
      and payload.crate.link.id == id and payload.crate.link.role == "export")
    ctx.check("filter rows stay dense beside the link payload", dict and dict[tags.TAG]
      and #dict[tags.TAG].filters == 1 and dict[tags.TAG].filters[1].row == 1)

    local ghost = s.create_entity{name = "entity-ghost", inner_name = "colony-freight-crate",
      position = {p.x - 110 + 20, p.y + 10}, force = "player"}
    if ghost then ghost.tags = dict end
    local gp = ghost and ghost.valid and tags.decode(ghost.tags)
    ctx.check("a blueprint ghost carries the link payload", gp and gp.crate and gp.crate.link.id == id
      and gp.crate.link.role == "export")
    colony.apply_tags(A, ghost, ghost.tags)
    ctx.check("applying tags to the ghost rewrites it safely", tags.decode(ghost.tags).crate.link.id == id)

    -- Duplicate-id rule: pasting a second copy of a still-live pair must NOT make a self-link or steal the
    -- original's peer. The copy is an unpaired export half the player has to re-link.
    local dup = build("colony-freight-crate", {p.x - 110 + 24, p.y + 10})
    colony.apply_tags(A, dup, dict)
    local rdup = A.crates[dup.unit_number]
    ctx.check("a duplicate paste is unpaired", rdup ~= nil and rdup.link == nil and rdup.role == "export")
    ctx.check("the original pair is untouched by the paste", ra.link == id and rb.link == id
      and storage.links[id] ~= nil)
    ctx.check("an unpaired crate emits no offer", work.link_export_offer(rdup, A, {}) == nil
      and work.link_import_offer(rdup) == nil)
    dup.destroy(); if ghost and ghost.valid then ghost.destroy() end

    -- Trust boundary, checked at offer-build time before any colonist walks.
    colony.set_quota(A, "iron-plate", 40)
    hallA.insert{name = "iron-plate", count = 45}
    A.stock_cache, A.stock_tick = nil, nil
    local surplus = work.link_export_surplus(A, colony.link_crate_list(A))
    ctx.check("surplus is stock minus the source's reserve", surplus["iron-plate"] == 5,
      tostring(surplus["iron-plate"]))
    local offer = work.link_export_offer(ra, A, surplus)
    ctx.check("the export offer is clamped to that surplus", offer ~= nil and offer.demands[1]
      and offer.demands[1].count == 5, offer and tostring(offer.demands[1] and offer.demands[1].count))
    ctx.check("the export offer rides the normal request band",
      offer ~= nil and offer.priority == 4 and offer.crate == ra)
    local held = hallA.remove_item{name = "iron-plate", count = 10}
    ctx.check("hall removal worked for the below-reserve case", held == 10, tostring(held))
    A.stock_cache, A.stock_tick = nil, nil
    ctx.check("no export at or below the reserve", work.link_export_offer(ra, A,
      work.link_export_surplus(A, colony.link_crate_list(A))) == nil)
    hallA.insert{name = "iron-plate", count = 65}   -- 100 total again
    A.stock_cache, A.stock_tick = nil, nil

    -- A second export link shares the same surplus: neither link may count it twice.
    local hallC = build("colony-town-hall", {p.x, p.y + 150})
    local C
    for _, c in pairs(storage.colonies) do
      if c.hall and c.hall.valid and c.hall.position.y > p.y + 100 then C = c end
    end
    local ok2 = false
    if C then
      local crateC = build("colony-freight-crate", {p.x + 10, p.y + 150})
      local rc = C.crates[crateC.unit_number]
      if rc then
        crates.set_filter(rc.filters, 1, "iron-plate"); crates.set_count(rc.filters, 1, 10)
        ok2 = colony.bind_link(rc, rb) == false   -- B's import crate is taken; must fail cleanly
        local crateC2 = build("colony-freight-crate", {p.x + 14, p.y + 150})
        local rc2 = C.crates[crateC2.unit_number]
        if rc2 then
          crates.set_filter(rc2.filters, 1, "iron-plate"); crates.set_count(rc2.filters, 1, 10)
          crateC.destroy(); rc = nil
          local ok3, id3 = colony.bind_link(rc2, rb)
          ctx.check("an already-paired destination refuses a second partner", ok2 and ok3 == false,
            "reason=" .. tostring(id3))
        end
      end
    end
    ctx.check("a third colony was available for the refusal test", C ~= nil and hallC ~= nil)

    -- Import side: only filtered items the train unloaded are offered, at the collect band.
    crateB.insert{name = "coal", count = 20}
    crateB.insert{name = "iron-plate", count = 7}     -- unfiltered junk: must not be offered
    B.stock_cache, B.stock_tick = nil, nil
    local imp = work.link_import_offer(rb)
    ctx.check("the import crate offers only filtered contents", imp ~= nil and #imp.demands == 1
      and imp.demands[1].item == "coal" and imp.demands[1].count == 20,
      imp and tostring(imp.demands[1] and imp.demands[1].item))
    ctx.check("the import offer is a collect-band provider", imp ~= nil and imp.kind == "collect"
      and imp.priority == 5 and imp.available["iron-plate"] == nil)

    -- Haulers on both ends: A fills the export crate with surplus; B empties the import crate into its hall.
    for _, t in ipairs({build("colony-housing-tent", {p.x - 110 + 4, p.y - 6}),
                        build("colony-housing-tent", {p.x - 110 + 8, p.y - 6})}) do
      if t and t.valid then t.insert{name = "colony-forage", count = 4} end
    end
    for _, t in ipairs({build("colony-housing-tent", {p.x + 110 - 4, p.y - 6}),
                        build("colony-housing-tent", {p.x + 110 - 8, p.y - 6})}) do
      if t and t.valid then t.insert{name = "colony-forage", count = 4} end
    end
    hallA.insert{name = "colony-forage", count = 200}
    hallB.insert{name = "colony-forage", count = 200}
    for _ = 1, 6 do colony.spawn_colonist(A) end
    for _ = 1, 6 do colony.spawn_colonist(B) end

    ctx.after(1500, function()
      local export_count = crateA.valid and crateA.get_item_count("iron-plate") or 0
      ctx.check("A's haulers filled the export crate from surplus", export_count > 0,
        "export crate=" .. tostring(export_count))
      local stockA = colony.stock_count(A, "iron-plate")
      ctx.check("A's own stock stayed at or above its reserve", stockA >= 40, "stock=" .. tostring(stockA))
      local coal_in = crateB.valid and crateB.get_item_count("coal") or 0
      local coal_hall = hallB.get_item_count("coal")
      ctx.check("B's haulers emptied the import crate into B's stock", coal_in < 20 and coal_hall > 0,
        "crate=" .. tostring(coal_in) .. " hall=" .. tostring(coal_hall))
      local junk = crateB.valid and crateB.get_item_count("iron-plate") or 0
      ctx.check("unfiltered junk was left in the import crate", junk == 7, tostring(junk))

      -- Destruction unlinks the peer through the existing crate-removal path. Factorio fires
      -- on_object_destroyed at the END of the current or next tick (engine docs), so the check lives in a
      -- later deferred step rather than immediately after destroy().
      crateA.destroy()
      ctx.check("the destroyed crate is gone", not crateA.valid)
    end)
    ctx.after(1510, function()
      ctx.check("destroying one half deletes the link record", storage.links[id] == nil)
      ctx.check("the peer is unpaired and inert", rb.link == nil and rb.role == nil
        and work.link_import_offer(rb) == nil)
      local again = build("colony-freight-crate", {p.x - 110 + 28, p.y + 10})
      local ra_again = A.crates[again.unit_number]
      local ok_again, new_id = colony.bind_link(ra_again, rb)
      ctx.check("the freed half can be re-linked", ok_again == true and new_id ~= id,
        "new id=" .. tostring(new_id))
      ctx.finish()
    end)
  end,
})
