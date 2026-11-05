-- PURE: guard duty at a garrisoned Watchtower (#56 first slice, design §7.2).
-- A Watchtower registered as a hut job "guard" holds rifles (the stock room IS the tower); each rifle
-- in it opens one post, exactly like a tooled hut slot (model/labour.lua). Staffed guards stand their
-- post at the tower and engage enemy units inside RANGE, at the cost of the rifles wearing out one step
-- per completed engagement (model/labour.wear - a hunter's trip pays for a kill exactly the same way).
-- Rifles are the price of the garrison: a tower with no rifles posts nobody, and a guard whose rifle
-- breaks keeps fighting empty-handed until reassigned, at which point it cannot be posted again.
local M = {}
M.RANGE = 16          -- tiles; a guard stands at the tower, the colonist's attack (14) reaches its edge
M.CHECK_TICKS = 45    -- idle rescan period while a guard is posted and sees no enemy
M.MAX_ATTEMPTS = 3    -- attack commands re-issued per target before the guard lets it go (same rule as hunts)
M.STRIKE_CLAIM = 3600 -- after this many failures, lose that target for a while (a turret-pinned biter)

-- Weapon choice. A post uses the best weapon the stock room holds, and vanilla firearms need no colony
-- research gate: if the player hauls a gun in, it is used. A rifle carries its own ammunition; a pistol or
-- submachine gun spends a magazine every few engagements; a bow spends an arrow.
M.PREFERENCE = {"colony-rifle", "submachine-gun", "pistol", "colony-bow"}
M.GUNS = {["submachine-gun"] = true, pistol = true}
M.MAGAZINES = {"piercing-rounds-magazine", "firearm-magazine"}
M.AMMO_FOR = {pistol = "firearm-magazine", ["submachine-gun"] = "firearm-magazine", ["colony-bow"] = "colony-arrow"}
M.AMMO_TARGET = {["firearm-magazine"] = 5, ["colony-arrow"] = 20}
M.AMMO_BATCH = {["firearm-magazine"] = 3, ["colony-arrow"] = 10}

-- The best weapon in a stock room, best first (rifle > SMG > pistol > bow), or nil.
function M.best_weapon(counts)
  for _, item in ipairs(M.PREFERENCE) do
    if (counts and counts[item] or 0) > 0 then return item end
  end
  return nil
end

-- What a post can actually shoot with right now, from what the stock room holds: mode ("gun" or "bow"), the
-- weapon item, and the item it spends (nil for a rifle). A gun with no magazine is not usable, so a bow is
-- chosen instead until ammunition arrives.
function M.arm(counts)
  local function c(item) return (counts and counts[item]) or 0 end
  if c("colony-rifle") > 0 then return "gun", "colony-rifle", nil end
  local magazine
  for _, item in ipairs(M.MAGAZINES) do
    if c(item) > 0 then magazine = item; break end
  end
  local gun = c("submachine-gun") > 0 and "submachine-gun" or (c("pistol") > 0 and "pistol" or nil)
  if gun and magazine then return "gun", gun, magazine end
  if c("colony-bow") > 0 then return "bow", "colony-bow", "colony-arrow" end
  return nil
end

-- Ammunition the stock room should ask for, given what it holds and what is already on the way.
-- Returns item, deficit, have, target, batch (nil when it needs none). Deliberately keyed off the weapons
-- present, not off `arm`: a pistol with no magazine must still ask for one or the post never uses its gun.
function M.ammo_wanted(counts, inflight)
  local function c(item) return (counts and counts[item]) or 0 end
  local function f(item) return (inflight and inflight[item]) or 0 end
  local item
  if c("submachine-gun") > 0 or c("pistol") > 0 then item = "firearm-magazine"
  elseif c("colony-bow") > 0 then item = "colony-arrow"
  else return nil end
  local target = M.AMMO_TARGET[item]
  local have = c(item) + f(item)
  local deficit = target - have
  if deficit < 1 then return nil end
  return item, deficit, have, target, M.AMMO_BATCH[item]
end

-- Nearest hostile to the tower's post `pos`; ties by unit_number. `enemies` = array of {unit_number=, position=}.
-- Deterministic: the same world state always picks the same target, so a desync or a test does not re-fight.
function M.nearest(enemies, pos, range)
  local best, best_d, r2 = nil, nil, (range or M.RANGE) ^ 2
  for _, a in ipairs(enemies) do
    local dx, dy = a.position.x - pos.x, a.position.y - pos.y
    local d = dx * dx + dy * dy
    if d <= r2 and (not best_d or d < best_d or (d == best_d and a.unit_number < best.unit_number)) then
      best, best_d = a, d
    end
  end
  return best
end

return M
