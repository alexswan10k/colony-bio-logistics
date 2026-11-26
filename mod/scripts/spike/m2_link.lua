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

    -- Copy-paste onto a bound half must not disturb its identity (#52 re-review finding).
    local src_supply = build("colony-supply-crate", {p.x - 110 + 44, p.y + 10})
    colony.copy_settings(src_supply, crateA)
    ctx.check("copy-paste from another crate leaves the pair intact",
      ra.link == id and ra.role == links.EXPORT and rb.link == id and rb.role == links.IMPORT
        and colony.link_peer(ra) == rec.b)
    local src_unpaired = build("colony-freight-crate", {p.x - 110 + 28, p.y + 10})
    local rsu = A.crates[src_unpaired.unit_number]
    colony.copy_settings(src_unpaired, crateA)
    ctx.check("copy-paste from an unpaired freight crate leaves the pair intact",
      ra.link == id and ra.role == links.EXPORT and colony.link_peer(ra) == rec.b
        and storage.links[id] ~= nil)
    -- The same payload the crate already carries must also be a no-op.
    colony.apply_tags(A, crateA, colony.entity_tags(crateA))
    ctx.check("apply_tags round-trip on a linked crate leaves the pair intact",
      ra.link == id and ra.role == links.EXPORT and colony.link_peer(ra) == rec.b)
    colony.apply_tags(A, crateA, tags.dictionary({crate = true, filters = {}}))
    ctx.check("a tag payload with no link leaves a linked crate intact",
      ra.link == id and rb.link == id and colony.link_peer(rb) == rec.a)
    -- A crate whose un is already claimed by a record must not be bindable again, even if its own fields
    -- were cleared (the half-unlink state that used to allow a double-claim).
    local saved_link, saved_role = ra.link, ra.role
    ra.link, ra.role = nil, nil
    local ok_claimed, why_claimed = colony.bind_link(ra, rsu)
    ra.link, ra.role = saved_link, saved_role
    ctx.check("a unit number already claimed by a link cannot be bound again",
      ok_claimed == false and why_claimed == "link-taken" and storage.links[id] ~= nil,
      tostring(why_claimed))
    src_supply.destroy(); src_unpaired.destroy()

    -- Tag round-trip: the pair identity rides the one namespaced key alongside dense filter rows.
    crates.set_filter(ra.filters, 1, "iron-plate"); crates.set_count(ra.filters, 1, 10)
    crates.set_filter(rb.filters, 1, "coal"); crates.set_count(rb.filters, 1, 20)
    colony.invalidate_demand(B)
    ctx.check("a paired import crate's filters seed B's #90 demand",
      colony.resource_demand(B, "coal") >= 20, tostring(colony.resource_demand(B, "coal")))
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
    ctx.check("a duplicate paste is fully unpaired", rdup ~= nil and rdup.link == nil and rdup.role == nil)
    ctx.check("the original pair is untouched by the paste", ra.link == id and rb.link == id
      and storage.links[id] ~= nil)
    ctx.check("an unpaired crate emits no offer", work.link_export_offer(rdup, A, {}) == nil
      and work.link_import_offer(rdup) == nil)
    -- An unpaired import-role crate must not inflate demand (#52 review finding 6).
    rdup.role, rdup.filters = links.IMPORT, {{item = "coal", count = 500}}
    colony.invalidate_demand(A)
    ctx.check("an unpaired import-role paste does not seed demand",
      colony.resource_demand(A, "coal") == 0, tostring(colony.resource_demand(A, "coal")))
    dup.destroy(); if ghost and ghost.valid then ghost.destroy() end

    -- Blueprint rebind must use bind_link's guards (#52 review finding 3). Fault-inject a stale record whose
    -- one dead slot is in the SAME colony as the pasted crate; a direct slot mutation would create a self-link.
    local fault_id = 9991
    local orphan = build("colony-freight-crate", {p.x - 110 + 36, p.y + 10})
    storage.links[fault_id] = {id = fault_id,
      a = {colony_id = A.id, un = crateA.unit_number, role = links.EXPORT},
      b = {colony_id = A.id, un = orphan.unit_number, role = links.IMPORT}}
    local forged = build("colony-freight-crate", {p.x - 110 + 40, p.y + 10})
    colony.apply_tags(A, forged, tags.dictionary({crate = true, filters = {},
      link = {id = fault_id, role = links.EXPORT}}))
    local rf = A.crates[forged.unit_number]
    ctx.check("blueprint rebind refuses a same-colony pair", rf and rf.link == nil and rf.role == nil
      and storage.links[fault_id].b.un == orphan.unit_number)
    storage.links[fault_id] = nil
    forged.destroy(); orphan.destroy()

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

    -- A sibling machine sink raises the reserve through the #90 demand graph: the same stock now has less
    -- exportable surplus, and the row cap is the only ceiling once stock clears the raised reserve.
    local sink = build("stone-furnace", {p.x - 110 + 18, p.y + 10})
    local sm = colony.set_machine(A, sink, true)
    if sm then sm.requests = {{item = "iron-plate", count = 30}} end
    colony.invalidate_demand(A); A.stock_cache, A.stock_tick = nil, nil
    local raised = colony.quota_target(A, "iron-plate")
    local with_sink = work.link_export_surplus(A, colony.link_crate_list(A))
    ctx.check("a machine sink raises the export reserve", raised == 70, tostring(raised))
    ctx.check("the raised reserve shrinks export surplus", with_sink["iron-plate"] == 30,
      tostring(with_sink["iron-plate"]))
    ctx.check("the row cap still bounds a surplus above the raised reserve",
      work.link_export_offer(ra, A, with_sink).demands[1].count == 10)
    -- Drop the sink again so the physical hauling check below uses the plain quota-40 reserve.
    colony.set_machine(A, sink, false); colony.invalidate_demand(A)
    A.stock_cache, A.stock_tick = nil, nil

    -- quota_target = 0 is the player's explicit "unlimited" opt-out: surplus is all stock and only the
    -- per-row count caps a trip (#52 review finding 5).
    colony.set_quota(A, "iron-plate", 0); A.stock_cache, A.stock_tick = nil, nil
    local unlimited = work.link_export_surplus(A, colony.link_crate_list(A))
    ctx.check("quota_target 0 makes surplus the whole stock", unlimited["iron-plate"] == 100,
      tostring(unlimited["iron-plate"]))
    ctx.check("quota_target 0 is capped by the row count only",
      work.link_export_offer(ra, A, unlimited).demands[1].count == 10)
    colony.set_quota(A, "iron-plate", 40); A.stock_cache, A.stock_tick = nil, nil

    -- A second export link shares the same surplus: neither link may count it twice.
    local hallC = build("colony-town-hall", {p.x, p.y + 150})
    local C
    for _, c in pairs(storage.colonies) do
      if c.hall and c.hall.valid and c.hall.position.y > p.y + 100 then C = c end
    end
    local ok2
    local double_peer = nil
    if C then
      local crateC = build("colony-freight-crate", {p.x + 10, p.y + 150})
      local rc = C.crates[crateC.unit_number]
      if rc then
        crates.set_filter(rc.filters, 1, "iron-plate"); crates.set_count(rc.filters, 1, 10)
        ok2 = colony.bind_link(rc, rb) == false   -- B's import crate is taken; must fail cleanly
        local crateC2 = build("colony-freight-crate", {p.x + 14, p.y + 150})
        double_peer = C.crates[crateC2.unit_number]
        if double_peer then
          crates.set_filter(double_peer.filters, 1, "iron-plate")
          crates.set_count(double_peer.filters, 1, 10)
          crateC.destroy()
          local ok3, id3 = colony.bind_link(double_peer, rb)
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
      -- later deferred step. Force the race: prune the crate record BEFORE the event fires, exactly what an
      -- active colony's find_haul_task does (#52 review finding 2).
      local doomed_un = crateA.unit_number
      -- Fault-inject a stale double-claim: a second record claims the same export unit number with a peer
      -- in colony C. Mining the crate must clean BOTH records deterministically, stranding neither peer.
      local twin_id = 7777
      if double_peer then
        double_peer.link, double_peer.role = twin_id, links.IMPORT
        storage.links[twin_id] = {id = twin_id,
          a = {colony_id = A.id, un = doomed_un, role = links.EXPORT},
          b = {colony_id = C.id, un = double_peer.entity.unit_number, role = links.IMPORT}}
      end
      crateA.destroy()
      colony.crate_list(A)   -- opportunistic prune while the entity is already invalid
      ctx.check("the destroyed crate is gone and its record was pruned",
        not crateA.valid and A.crates[doomed_un] == nil)
    end)
    ctx.after(1510, function()
      ctx.check("destruction unlinks even when the crate record was pruned first", storage.links[id] == nil)
      ctx.check("a stale double-claim is cleaned from every record", storage.links[7777] == nil)
      ctx.check("the peer is unpaired and inert", rb.link == nil and rb.role == nil
        and work.link_import_offer(rb) == nil)
      ctx.check("the double-claimed peer is also freed",
        double_peer == nil or (double_peer.link == nil and double_peer.role == nil))

      -- Stale blueprint repro: the saved tag still carries the now-deleted id 1. A live paste must come back
      -- fully unpaired, and Unlink must still clear a dangling id (#52 review finding 1).
      local stale = build("colony-freight-crate", {p.x - 110 + 32, p.y + 10})
      colony.apply_tags(A, stale, dict)
      local rstale = A.crates[stale.unit_number]
      ctx.check("a stale blueprint id leaves a live crate fully unpaired",
        rstale ~= nil and rstale.link == nil and rstale.role == nil,
        "link=" .. tostring(rstale and rstale.link))
      rstale.link, rstale.role = 999, links.EXPORT   -- fault-inject a dangling id on an older save
      local unlinked = colony.unbind_link(stale.unit_number)
      ctx.check("unlink always clears a dangling id", unlinked == true
        and rstale.link == nil and rstale.role == nil)
      local ok_again, new_id = colony.bind_link(rstale, rb)
      ctx.check("the freed half can be re-linked", ok_again == true and new_id ~= id,
        "new id=" .. tostring(new_id))
      ctx.finish()
    end)
  end,
})
