---@diagnostic enable: undefined-field, missing-fields
-- PURE: Motor Pool rules (#60). A pool holds vanilla cars and fuel; a hauler checks a car out as a truck when a
-- load is too big for one pair of hands, drives it until the fuel runs out or there is nothing big left to move,
-- then parks it again.
local yields = require("scripts.model.yields")

local M = {}

M.CAR = "car"
M.CAPACITY = yields.CARRY_CAP * 5   -- a truck carries five colonists' worth
M.MIN_LOAD = yields.CARRY_CAP + 1   -- below this a hauler on foot carries it, and the car stays parked
M.CARS = 4                          -- cars the pool asks haulers to bring it from colony stock
M.FUEL_STOCK = 10                   -- fuel items the pool keeps on hand
-- Trips one fuel item buys, best first: a pool burns the richest fuel it holds (roughly 2 MJ per trip).
M.FUELS = {{item = "solid-fuel", trips = 6}, {item = "coal", trips = 2}, {item = "wood", trips = 1}}

local function fuel_items()
  local out = {}
  for _, f in ipairs(M.FUELS) do out[#out + 1] = f.item end
  return out
end
M.FUEL_ITEMS = fuel_items()

-- Items a pool holds on purpose: haulers must never treat these as output to be carted back to the hall.
M.KEEP = {[M.CAR] = true}
for _, f in ipairs(M.FUELS) do M.KEEP[f.item] = true end

-- Is this load worth a truck? A hauler on foot already carries CARRY_CAP, so a truck only goes out for more.
function M.worth_truck(load_total) return (load_total or 0) >= M.MIN_LOAD end

-- The fuel to burn from `contents` {item -> n}, and how many trips it buys; nil when the pool is dry.
function M.refuel(contents)
  for _, f in ipairs(M.FUELS) do
    if (contents[f.item] or 0) > 0 then return f.item, f.trips end
  end
  return nil
end

function M.fuel_count(contents)
  local n = 0
  for _, f in ipairs(M.FUELS) do n = n + (contents[f.item] or 0) end
  return n
end

-- Can a car leave right now? Needs a car on the floor and something to burn.
function M.can_dispatch(contents)
  return (contents[M.CAR] or 0) > 0 and M.fuel_count(contents) > 0
end

-- What to haul to a pool: fuel (any of the fuels, whichever the colony has) up to FUEL_STOCK, and cars from colony
-- stock up to CARS. Cars are only asked for while the colony actually holds one, so the request never sits open.
-- contents/inflight/stock: {item -> n}. `out` (cars currently driving) count against the car target.
function M.wants(contents, inflight, stock, out)
  local demands = {}
  local fuel = M.fuel_count(contents)
  for _, item in ipairs(M.FUEL_ITEMS) do fuel = fuel + (inflight[item] or 0) end
  if fuel < M.FUEL_STOCK then demands[#demands + 1] = {items = M.FUEL_ITEMS, count = M.FUEL_STOCK - fuel} end
  local cars = (contents[M.CAR] or 0) + (inflight[M.CAR] or 0) + (out or 0)
  if cars < M.CARS and (stock[M.CAR] or 0) > 0 then
    demands[#demands + 1] = {item = M.CAR, count = M.CARS - cars}
  end
  return demands
end

return M
