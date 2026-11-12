---@diagnostic enable: undefined-field, missing-fields
-- PURE: what a Colony Ledger publishes onto the circuit network (#92).
--
-- The ledger already aggregates the colony's whole inventory (model/ledger.lua: hall + warehouses + hut
-- chests + hauler carries). This file decides which of those numbers become circuit signals and how they
-- are ordered, with no engine access so the rules can be tested offline.
--
-- Two modes, because a factory asks two different questions:
--   "stock"  - how much of each item the colony holds right now (a belt condition: iron plate < 500).
--   "want"   - how much more the town still wants (quota target - stock, zero dropped), so a wire reads
--              the shortfall directly and a condition is `iron-plate > 0` instead of a hand-copied threshold.
--
-- Ordering is magnitude first (the biggest number is the one a factory is most likely to act on), with the
-- hall ledger's own category order as the tie-break so the same stock always produces the same list.
local ledger = require("scripts.model.ledger")
local M = {}

M.MAX_SIGNALS = 20          -- filter rows per section (a constant combinator section takes far more, 20 stays readable)
M.MAX_SECTIONS = 2          -- sections the ledger fills, so a mature town (more than 20 tracked items) fits
M.MODES = {"stock", "want"}
M.DEFAULT_MODE = "stock"
M.MAX_VALUE = 2147483647    -- the engine rejects an out-of-range signal value, so clamp before publishing

---@param mode string|nil
---@return string
function M.mode(mode)
  return (mode == "want") and "want" or M.DEFAULT_MODE
end

-- One item's signal value in the given mode. 0 means "do not publish it" (the slot is better spent on
-- something a factory can act on, and a missing signal already reads as 0 on the network).
---@param total integer|nil
---@param mode string|nil
---@param target integer|nil
---@return integer
function M.value(total, mode, target)
  total = math.max(0, math.floor(tonumber(total) or 0))
  if M.mode(mode) == "want" then
    local want = math.max(0, math.floor(tonumber(target) or 0))
    return math.max(0, want - total)
  end
  return math.min(total, M.MAX_VALUE)
end

-- rows: array of {item = string, total = integer, target = integer|nil}
-- -> the published list, an array of {item = string, count = integer}, biggest first.
---@param rows table[]|nil
---@param mode string|nil
---@param limit integer|nil
---@return table[]
function M.publish(rows, mode, limit)
  mode = M.mode(mode)
  local max = math.max(0, math.floor(tonumber(limit) or (M.MAX_SIGNALS * M.MAX_SECTIONS)))
  local out, seen = {}, {}
  for _, row in ipairs(rows or {}) do
    local item = type(row) == "table" and row.item or nil
    if type(item) == "string" and item ~= "" and not seen[item] then
      local count = M.value(row.total, mode, row.target)
      if count > 0 then
        seen[item] = true
        out[#out + 1] = {item = item, count = count}
      end
    end
  end
  table.sort(out, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    local ka, kb = ledger.sort_key(a.item), ledger.sort_key(b.item)
    if ka ~= kb then return ka < kb end
    return a.item < b.item
  end)
  while #out > max do out[#out] = nil end
  return out
end

-- Split a published list into one filter array per section (the last section may be short). Always at
-- least one section: an empty list still has to clear whatever the ledger published last time.
---@param list table[]|nil
---@param size integer|nil
---@return table[]
function M.chunk(list, size)
  local n = math.max(1, math.floor(tonumber(size) or M.MAX_SIGNALS))
  local out = {[1] = {}}
  for i, row in ipairs(list or {}) do
    local at = math.floor((i - 1) / n) + 1
    out[at] = out[at] or {}
    out[at][#out[at] + 1] = row
  end
  return out
end

-- A human line for the panel and the entity tooltip, e.g. "stock" -> "24 signals: 1234 iron-plate, ...".
-- Kept here so the wording is testable and the GUI stays a thin renderer.
---@param list table[]|nil
---@param max_names integer|nil
---@return string
function M.summary(list, max_names)
  local n = 0
  for _ in ipairs(list or {}) do n = n + 1 end
  if n == 0 then return "no signals (nothing in stock)" end
  local names = {}
  for i, row in ipairs(list) do
    if i > (max_names or 3) then break end
    names[#names + 1] = tostring(row.count) .. " " .. row.item
  end
  local text = n .. (n == 1 and " signal: " or " signals: ") .. table.concat(names, ", ")
  if n > (max_names or 3) then text = text .. ", ..." end
  return text
end

return M
