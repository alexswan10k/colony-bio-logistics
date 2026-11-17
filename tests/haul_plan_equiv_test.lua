-- Equivalence proof for the #54 UPS refactor: the hoisted-distance `haul_plan.match` must make exactly
-- the same decision as the pre-refactor comparator. `reference_match` below is a verbatim copy of the old
-- `M.match` (only the two sort comparators differ from the shipped code); the helper `hp.dist`/`hp.load`/
-- `hp.deficit`/`hp.storage_accepts` it calls are unchanged by the refactor. The grid deliberately includes
-- exact distance ties (key tie-break), near-equal distances (last-bit float decisions), nil hauler_pos,
-- `.entity.position` fallbacks, origin fallbacks, storage_priority interactions and rank tie-breaks.
local hp = require("scripts.model.haul_plan")
local material_priority = require("scripts.model.material_priority")

local function demand_items(d) return d.items or {d.item} end

local function item_names(list)
  local out = {}
  for _, entry in ipairs(list or {}) do
    if entry.item then out[#out + 1] = entry.item
    elseif entry.items then for _, name in ipairs(entry.items) do out[#out + 1] = name end
    elseif type(entry) == "string" then out[#out + 1] = entry end
  end
  return out
end

local function has_any_demanded(available, demands)
  for _, d in ipairs(demands) do
    for _, item in ipairs(demand_items(d)) do
      if (available[item] or 0) > 0 then return true end
    end
  end
  return false
end

-- The OLD implementation (pre-#54-UPS). Do not "clean up": it is the oracle.
local function reference_match(requesters, providers, storages, compost_offers, cap, hauler_pos, rank_ctx)
  cap = cap or hp.DEFAULT_CAP
  requesters = requesters or {}
  providers = providers or {}
  storages = storages or {}
  compost_offers = compost_offers or {}

  local candidates = {}

  for _, r in ipairs(requesters) do
    local r_pos = r.pos or (r.entity and r.entity.position) or {x = 0, y = 0}
    local matched_direct = false

    local direct_providers = {}
    for _, p in ipairs(providers) do
      if has_any_demanded(p.available or {}, r.demands or {}) then
        direct_providers[#direct_providers + 1] = p
      end
    end
    if #direct_providers > 0 then
      table.sort(direct_providers, function(a, b)
        local pa = a.pos or (a.entity and a.entity.position) or {x = 0, y = 0}
        local pb = b.pos or (b.entity and b.entity.position) or {x = 0, y = 0}
        local da = hp.dist(hauler_pos or pa, pa) + hp.dist(pa, r_pos)
        local db = hp.dist(hauler_pos or pb, pb) + hp.dist(pb, r_pos)
        if da ~= db then return da < db end
        return (a.key or 0) < (b.key or 0)
      end)
      for _, p in ipairs(direct_providers) do
        local load = hp.load(r.demands, p.available or {}, cap)
        if #load > 0 then
          local p_pos = p.pos or (p.entity and p.entity.position) or {x = 0, y = 0}
          local d = hp.dist(hauler_pos or p_pos, p_pos) + hp.dist(p_pos, r_pos)
          candidates[#candidates + 1] = {
            kind = "direct", priority = math.min(r.priority, p.priority),
            building_priority = math.min(r.building_priority or 3, p.building_priority or 3),
            is_direct = true, source = p, target = r, load = load, demands = r.demands,
            deficit = hp.deficit(r), key = r.key, dist = d, house = r.house, machine = r.machine or p.machine,
            crate = r.crate or p.crate, pool = r.pool, tavern = r.tavern, canteen = r.canteen,
            hut = r.hut or p.hut, bin = r.bin or p.bin, pan = p.pan, well = p.well,
          }
          matched_direct = true
          break
        end
      end
    end

    local avail_storages = {}
    for _, s in ipairs(storages) do
      if not (r.entity and s.entity == r.entity) and has_any_demanded(s.available or {}, r.demands or {}) then
        avail_storages[#avail_storages + 1] = s
      end
    end
    if #avail_storages > 0 then
      table.sort(avail_storages, function(a, b)
        local spa = a.storage_priority or 3
        local spb = b.storage_priority or 3
        if spa ~= spb then return spa < spb end
        local sa = a.pos or (a.entity and a.entity.position) or {x = 0, y = 0}
        local sb = b.pos or (b.entity and b.entity.position) or {x = 0, y = 0}
        local da = hp.dist(hauler_pos or sa, sa) + hp.dist(sa, r_pos)
        local db = hp.dist(hauler_pos or sb, sb) + hp.dist(sb, r_pos)
        if da ~= db then return da < db end
        return (a.key or 0) < (b.key or 0)
      end)
      for _, s in ipairs(avail_storages) do
        local load = hp.load(r.demands, s.available or {}, cap)
        if #load > 0 then
          local s_pos = s.pos or (s.entity and s.entity.position) or {x = 0, y = 0}
          local d = hp.dist(hauler_pos or s_pos, s_pos) + hp.dist(s_pos, r_pos)
          candidates[#candidates + 1] = {
            kind = "supply", priority = r.priority, building_priority = r.building_priority or 3,
            is_direct = false, source = s, target = r, load = load, demands = r.demands,
            deficit = hp.deficit(r), key = r.key, dist = d, house = r.house, machine = r.machine,
            crate = r.crate, pool = r.pool, tavern = r.tavern, canteen = r.canteen, hut = r.hut,
          }
          break
        end
      end
    end
  end

  for _, p in ipairs(providers) do
    local p_pos = p.pos or (p.entity and p.entity.position) or {x = 0, y = 0}
    local p_items = {}
    for item, count in pairs(p.available or {}) do if count > 0 then p_items[#p_items + 1] = item end end
    if #p_items > 0 then
      local open_storages = {}
      for _, s in ipairs(storages) do
        if s.has_space ~= false then
          local accepts_any = false
          for _, item in ipairs(p_items) do
            if hp.storage_accepts(s, item) then accepts_any = true; break end
          end
          if accepts_any then open_storages[#open_storages + 1] = s end
        end
      end
      if #open_storages > 0 then
        table.sort(open_storages, function(a, b)
          local spa = a.storage_priority or 3; local spb = b.storage_priority or 3
          if spa ~= spb then return spa < spb end
          local sa = a.pos or (a.entity and a.entity.position) or {x = 0, y = 0}
          local sb = b.pos or (b.entity and b.entity.position) or {x = 0, y = 0}
          local da, db = hp.dist2(sa, p_pos), hp.dist2(sb, p_pos)
          if da ~= db then return da < db end
          return (a.key or 0) < (b.key or 0)
        end)
        local best_s = open_storages[1]
        local s_pos = best_s.pos or (best_s.entity and best_s.entity.position) or {x = 0, y = 0}
        local demands = {}
        for item, count in pairs(p.available or {}) do
          if count > 0 and hp.storage_accepts(best_s, item) then demands[#demands + 1] = {item = item, count = count} end
        end
        table.sort(demands, function(a, b) return a.item < b.item end)
        if #demands > 0 then
          local load = hp.load(demands, p.available or {}, cap)
          if #load > 0 then
            local d = hp.dist(hauler_pos or p_pos, p_pos) + hp.dist(p_pos, s_pos)
            candidates[#candidates + 1] = {
              kind = "collect", priority = p.priority, building_priority = p.building_priority or 3,
              is_direct = false, source = p, target = best_s, load = load, demands = demands,
              deficit = hp.deficit(p), key = p.key, dist = d, machine = p.machine, crate = p.crate,
              hut = p.hut, bin = p.bin, pan = p.pan, well = p.well,
            }
          end
        end
      end
    end
  end

  for _, c in ipairs(compost_offers) do
    local src_pos = c.pos or (c.source and (c.source.pos or (c.source.entity and c.source.entity.position))) or {x = 0, y = 0}
    local bin_pos = (c.bin and (c.bin.pos or (c.bin.entity and c.bin.entity.position))) or {x = 0, y = 0}
    local d = hp.dist(hauler_pos or src_pos, src_pos) + hp.dist(src_pos, bin_pos)
    local n = math.min(c.spoil or cap, cap)
    if n > 0 then
      candidates[#candidates + 1] = {
        kind = "compost", priority = c.priority, building_priority = c.building_priority or 3,
        is_direct = false, source = c.source or c.storage, target = c.bin, bin = c.bin,
        load = {{item = c.item or "spoilage", count = n}}, demands = {{item = c.item or "spoilage", count = n}},
        deficit = c.spoil or cap, key = c.key, dist = d,
      }
    end
  end

  local backlog = 0
  for _, r in ipairs(requesters) do if r.priority < hp.PRIORITY.buffer then backlog = backlog + 1 end end
  for _, p in ipairs(providers) do if p.priority < hp.PRIORITY.buffer then backlog = backlog + 1 end end
  for _, c in ipairs(compost_offers) do if c.priority < hp.PRIORITY.buffer then backlog = backlog + 1 end end

  if #candidates == 0 then return nil, backlog end

  local function mat_rank(cand)
    if cand.mat_rank ~= nil then return cand.mat_rank end
    if not rank_ctx then return material_priority.DEFAULT end
    local r = material_priority.best(item_names(cand.load or cand.demands), rank_ctx.ratings, rank_ctx.demand)
    cand.mat_rank = r
    return r
  end
  table.sort(candidates, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    local bpa = a.building_priority or 3; local bpb = b.building_priority or 3
    if bpa ~= bpb then return bpa < bpb end
    local ra, rb = mat_rank(a), mat_rank(b)
    if ra ~= rb then return ra < rb end
    if a.is_direct ~= b.is_direct then return a.is_direct end
    if a.deficit ~= b.deficit then return a.deficit > b.deficit end
    if a.dist ~= b.dist then return a.dist < b.dist end
    return (a.key or 0) < (b.key or 0)
  end)
  return candidates[1], backlog
end

local function sig(task, backlog)
  if not task then return "nil|" .. tostring(backlog) end
  local load = {}
  for _, s in ipairs(task.load or {}) do load[#load + 1] = tostring(s.item) .. "=" .. tostring(s.count) end
  local src = task.source and task.source.key
  local tgt = task.target and task.target.key
  return table.concat({tostring(task.kind), tostring(src), tostring(tgt), tostring(task.priority),
    tostring(task.building_priority), tostring(task.is_direct), tostring(task.dist), tostring(task.key),
    table.concat(load, ",")}, "|") .. "|" .. tostring(backlog)
end

local function compare(label, req, prov, stor, comp, cap, hauler, rank_ctx)
  local a, ab = reference_match(req, prov, stor, comp, cap, hauler, rank_ctx)
  local b, bb = hp.match(req, prov, stor, comp, cap, hauler, rank_ctx)
  eq(sig(b, bb), sig(a, ab), label .. ": ref=" .. sig(a, ab) .. " got=" .. sig(b, bb))
end

describe("haul_plan comparator equivalence (#54 UPS)", function()
  local R = hp.PRIORITY.request

  it("direct providers: exact distance ties fall through to the key tie-break", function()
    -- three geometrically different providers, all at route distance exactly 10 from hauler (0,0) to house (10,0)
    local req = {{key = "house", priority = R, pos = {x = 10, y = 0}, demands = {{item = "iron-ore", count = 3}}}}
    local prov = {
      {key = "z", priority = hp.PRIORITY.hut_output, pos = {x = 0, y = 0}, available = {["iron-ore"] = 10}},
      {key = "a", priority = hp.PRIORITY.hut_output, pos = {x = 10, y = 0}, available = {["iron-ore"] = 10}},
      {key = "m", priority = hp.PRIORITY.hut_output, pos = {x = 5, y = 0}, available = {["iron-ore"] = 10}},
    }
    compare("tie", req, prov, {}, {}, 20, {x = 0, y = 0})
    -- reverse insertion order: table.sort is not stable, so the key tie-break must still win
    local rev = {prov[3], prov[1], prov[2]}
    compare("tie reversed", req, rev, {}, {}, 20, {x = 0, y = 0})
  end)

  it("direct providers: near-equal distances differing in the last bits are preserved", function()
    local req = {{key = "house", priority = R, pos = {x = 10, y = 0}, demands = {{item = "iron-ore", count = 3}}}}
    local prov = {
      {key = "near", priority = hp.PRIORITY.hut_output, pos = {x = 5, y = 0.0000001}, available = {["iron-ore"] = 10}},
      {key = "exact", priority = hp.PRIORITY.hut_output, pos = {x = 5, y = 0}, available = {["iron-ore"] = 10}},
      {key = "eps2", priority = hp.PRIORITY.hut_output, pos = {x = 5, y = -0.0000001}, available = {["iron-ore"] = 10}},
    }
    compare("near-equal", req, prov, {}, {}, 20, {x = 0, y = 0})
  end)

  it("direct providers: nil hauler_pos uses the provider as its own start (zero hauler leg)", function()
    local req = {{key = "house", priority = R, pos = {x = 10, y = 0}, demands = {{item = "iron-ore", count = 3}}}}
    local prov = {
      {key = "far", priority = hp.PRIORITY.hut_output, pos = {x = 100, y = 0}, available = {["iron-ore"] = 10}},
      {key = "near", priority = hp.PRIORITY.hut_output, pos = {x = 9, y = 0}, available = {["iron-ore"] = 10}},
    }
    compare("nil hauler", req, prov, {}, {}, 20, nil)
  end)

  it("direct providers: .entity.position and origin fallbacks behave identically", function()
    local req = {{key = "house", priority = R, entity = {position = {x = 10, y = 0}}, demands = {{item = "iron-ore", count = 3}}}}
    local prov = {
      {key = "ent", priority = hp.PRIORITY.hut_output, entity = {position = {x = 5, y = 0}}, available = {["iron-ore"] = 10}},
      {key = "origin", priority = hp.PRIORITY.hut_output, available = {["iron-ore"] = 10}},
      {key = "pos", priority = hp.PRIORITY.hut_output, pos = {x = 4, y = 0}, available = {["iron-ore"] = 10}},
    }
    compare("fallbacks", req, prov, {}, {}, 20, {x = 0, y = 0})
  end)

  it("storages: storage_priority dominates, distance breaks ties, key breaks exact ties", function()
    local req = {{key = "house", priority = R, pos = {x = 10, y = 0}, demands = {{item = "iron-ore", count = 3}}}}
    local stor = {
      {key = "s_low_near", pos = {x = 9, y = 0}, available = {["iron-ore"] = 10}, storage_priority = 4, has_space = true},
      {key = "s_high_tie_a", pos = {x = 0, y = 0}, available = {["iron-ore"] = 10}, storage_priority = 2, has_space = true},
      {key = "b_high_tie", pos = {x = 10, y = 0}, available = {["iron-ore"] = 10}, storage_priority = 2, has_space = true},
      {key = "a_high_near", pos = {x = 5, y = 0}, available = {["iron-ore"] = 10}, storage_priority = 2, has_space = true},
    }
    compare("storage ties", req, {}, stor, {}, 20, {x = 0, y = 0})
    compare("storage ties nil hauler", req, {}, stor, {}, 20, nil)
  end)

  it("storages: near-equal distances between storages choose the same source", function()
    local req = {{key = "house", priority = R, pos = {x = 10, y = 0}, demands = {{item = "iron-ore", count = 3}}}}
    local stor = {
      {key = "eps_plus", pos = {x = 5, y = 0.0000001}, available = {["iron-ore"] = 10}, storage_priority = 2, has_space = true},
      {key = "exact", pos = {x = 5, y = 0}, available = {["iron-ore"] = 10}, storage_priority = 2, has_space = true},
      {key = "eps_minus", pos = {x = 5, y = -0.0000001}, available = {["iron-ore"] = 10}, storage_priority = 2, has_space = true},
    }
    compare("storage near-equal", req, {}, stor, {}, 20, {x = 0, y = 0})
  end)

  it("a provider that is also a storage, and a requester that is its own source", function()
    local shared = {key = "shared", priority = hp.PRIORITY.hut_output, pos = {x = 3, y = 0}, available = {["iron-ore"] = 10}, storage_priority = 2, has_space = true}
    local req = {{key = "house", priority = R, entity = shared, pos = {x = 10, y = 0},
      demands = {{item = "iron-ore", count = 3}}}}
    -- r.entity == s.entity excludes the shared storage as its own source
    compare("self source", req, {}, {shared, {key = "other", pos = {x = 9, y = 0}, available = {["iron-ore"] = 10}}}, {}, 20, {x = 0, y = 0})
    -- same table in both arrays for a requester without an entity: both comparators see it
    local req2 = {{key = "house2", priority = R, pos = {x = 10, y = 0}, demands = {{item = "iron-ore", count = 3}}}}
    compare("dual role", req2, {shared}, {shared}, {}, 20, {x = 0, y = 0})
  end)

  it("rank_ctx tie-break and collect/compost candidates are unchanged", function()
    local rctx = {ratings = {["iron-ore"] = {rank = 1, enabled = true}, ["copper-ore"] = {rank = 5, enabled = true}}, demand = {}}
    local req = {{key = "house", priority = R, pos = {x = 10, y = 0}, demands = {{need = "ore", items = {"iron-ore", "copper-ore"}, count = 3}}}}
    local stor = {
      {key = "copper", pos = {x = 9, y = 0}, available = {["copper-ore"] = 10}, storage_priority = 2, has_space = true},
      {key = "iron", pos = {x = 8.9, y = 0}, available = {["iron-ore"] = 10}, storage_priority = 2, has_space = true},
    }
    compare("rank ctx", req, {}, stor, {}, 20, {x = 0, y = 0}, rctx)
    local comp = {{key = "bin", priority = hp.PRIORITY.compost, pos = {x = 2, y = 0}, bin = {pos = {x = 5, y = 0}}, spoil = 10}}
    compare("compost", {}, {}, {}, comp, 20, {x = 0, y = 0})
  end)

  it("multiple requesters and providers: the global candidate sort still picks the same winner", function()
    local req = {
      {key = "h1", priority = R, pos = {x = 10, y = 0}, demands = {{item = "iron-ore", count = 3}}},
      {key = "h2", priority = hp.PRIORITY.critical, pos = {x = -10, y = 0}, demands = {{item = "iron-ore", count = 5}}},
      {key = "h3", priority = R, pos = {x = 0, y = 10}, demands = {{item = "wood", count = 2}}},
    }
    local prov = {
      {key = "p1", priority = hp.PRIORITY.hut_output, pos = {x = 5, y = 0}, available = {["iron-ore"] = 10}},
      {key = "p2", priority = hp.PRIORITY.hut_output, pos = {x = -5, y = 0}, available = {["iron-ore"] = 10}},
      {key = "p3", priority = hp.PRIORITY.hut_output, pos = {x = 0, y = 5}, available = {wood = 10}},
    }
    local stor = {
      {key = "s1", pos = {x = 1, y = 1}, available = {["iron-ore"] = 20, wood = 20}, has_space = true},
    }
    compare("multi", req, prov, stor, {}, 20, {x = 0, y = 0})
    compare("multi nil hauler", req, prov, stor, {}, 20, nil)
  end)
end)
