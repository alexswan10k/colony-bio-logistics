---@diagnostic enable: undefined-field, missing-fields
-- PURE: colony-to-colony freight links (#52). A link is one plain-data record in `storage.links` holding two
-- slots (a = export, b = import), each keyed by colony id + crate unit number. Nothing here reads the engine:
-- the adapter hands in scalar summaries and plain tables, so every rule is testable offline and no hot path
-- scans the world. The train and the track belong to the player; this module only decides what a colonist
-- may load into an export crate and what a destination colonist may take out of an import crate.
local crates = require("scripts.model.crates")
local M = {}

M.EXPORT, M.IMPORT = "export", "import"
M.MAX_LINKS = 32                 -- guard unbounded registry growth (bind returns a reason key when exceeded)

local function by_item(a, b) return a.item < b.item end

-- Tag payloads are untrusted (a stale blueprint or another mod), so both validators are shared with tags.decode.
function M.validate_id(v)
  local n = tonumber(v)
  if not n or n < 1 or n ~= math.floor(n) then return nil end
  return n
end

function M.validate_role(v)
  if v == M.EXPORT or v == M.IMPORT then return v end
  return nil
end

-- The opposite slot of a link, by unit number. No scan: both slots are direct fields of the record.
function M.peer(link, self_un)
  if not (link and self_un) then return nil end
  if link.a and link.a.un == self_un then return link.b end
  if link.b and link.b.un == self_un then return link.a end
  return nil
end

function M.slot(link, role)
  if not link then return nil end
  if role == M.EXPORT then return link.a end
  if role == M.IMPORT then return link.b end
  return nil
end

-- Both slots are plain summaries {colony_id, un, role, kind, alive}; force_ok / surface_ok / kind_ok are
-- computed by the adapter from the *live* entities, so a stale slot cannot pass. Self-links are refused here.
function M.valid_pair(a, b, force_ok, surface_ok, kind_ok)
  if not (a and b) then return false end
  if not (M.validate_id(a.colony_id) and M.validate_id(b.colony_id)) then return false end
  if not (M.validate_id(a.un) and M.validate_id(b.un)) then return false end
  if a.colony_id == b.colony_id then return false end
  if a.role ~= M.EXPORT or b.role ~= M.IMPORT then return false end
  if a.alive == false or b.alive == false then return false end
  return force_ok == true and surface_ok == true and kind_ok == true
end

-- Export trust boundary. `surplus[item]` is what the adapter computed as
--   stock(A, item) - quota_target(A, item) - sum(inflight over A's export crates)
-- so a crate never ships stock the source colony still needs, and two crates/links cannot count the same
-- surplus twice. `contents` is what already sits in this crate waiting for the player's inserters; a row's
-- count is the per-row cap. Hysteresis is crates.demands' 50%/10 rule, so a half-full crate does not cause a
-- trickle of one-item trips. Output is sorted by item name for deterministic offers.
function M.export_wants(filters, contents, inflight, surplus)
  local out = {}
  for i = 1, crates.FILTER_ROWS do
    local f = filters and filters[i]
    if f and f.item then
      local target = tonumber(f.count) or crates.DEFAULT_COUNT
      local have = (contents and contents[f.item] or 0) + (inflight and inflight[f.item] or 0)
      local want = target - have
      local avail = math.max(0, math.floor(surplus and surplus[f.item] or 0))
      local threshold = math.max(0, math.floor(target * 0.5))
      if want >= 1 and avail >= 1 and (have <= threshold or want >= 10) then
        out[#out + 1] = {item = f.item, count = math.min(want, avail)}
      end
    end
  end
  table.sort(out, by_item)
  return out
end

-- Destination B: an import crate is a provider. Only filtered items are offered, so a crate with no filters
-- accepts nothing and random junk dropped into it is never swept into B's stock. `cap` is an optional
-- per-offer ceiling (the caller passes the haul cap when it wants one). Returns (demands, available) in the
-- same shape as crates.supply / a supply crate's contents.
function M.import_wants(filters, contents, cap)
  local out, available = {}, {}
  for i = 1, crates.FILTER_ROWS do
    local f = filters and filters[i]
    if f and f.item then
      local n = math.max(0, math.floor((contents and contents[f.item]) or 0))
      if cap then n = math.min(n, cap) end
      if n > 0 then
        out[#out + 1] = {item = f.item, count = n}
        available[f.item] = (available[f.item] or 0) + n
      end
    end
  end
  table.sort(out, by_item)
  return out, available
end

-- A deep copy for writing the same filter list to the peer: the two registries must never share row tables.
function M.mirror(filters)
  local out = {}
  for i = 1, crates.FILTER_ROWS do
    local f = filters and filters[i]
    if f and f.item then out[i] = {item = f.item, count = f.count} end
  end
  return out
end

-- GUI candidate list. `entries` are plain summaries of every freight crate on the surface, collected by the
-- adapter; only unpaired crates in another colony on the same force and surface are linkable. Sorted so the
-- drop-down is stable regardless of storage iteration order.
function M.candidates(entries, self_colony_id, force_name, surface_index)
  local out = {}
  for _, e in ipairs(entries or {}) do
    if e.colony_id ~= self_colony_id and e.force == force_name and e.surface == surface_index
      and e.kind == crates.LINK and M.validate_id(e.un) and not M.validate_id(e.link) then
      out[#out + 1] = {colony_id = e.colony_id, un = e.un, label = e.label or ("Colony " .. e.colony_id .. " #" .. e.un)}
    end
  end
  table.sort(out, function(a, b)
    if a.colony_id ~= b.colony_id then return a.colony_id < b.colony_id end
    return a.un < b.un
  end)
  return out
end

return M
