-- PURE: natural reproduction (#88, complements #65 "Nurseries & natural reproduction").
-- A pair of opposite-sex adults in one house with its critical provisions met and a free bed can have a child.
-- Children count toward occupancy (and desirability), eat half portions, cannot work, and grow into adults
-- after CHILD_TICKS. Rolls are a hash of (house, tick, salt) so a run is deterministic and needs no stored
-- generator, like illness.roll.
local M = {}

M.BREED_P = 0.05          -- chance of a birth per eligible house per evaluation
M.COOLDOWN_TICKS = 12000  -- no second child in the same house before this many ticks pass (10 min)
M.CHILD_TICKS = 25000     -- ticks before a child counts as grown (one in-game day)
M.CHILD_RATE = 0.5        -- food a child eats, relative to an adult

-- A deterministic number in [0, 1) for this house, tick and purpose.
function M.roll(house_un, tick, salt)
  local h = (house_un * 2654435761 + tick * 40503 + (salt or 0) * 97) % 4294967296
  h = (h * 1103515245 + 12345) % 2147483648
  return h / 2147483648
end

-- Sex from unit number: half and half, and no storage needed, so migrants arriving in any order still pair up.
function M.sex_of(un)
  return un % 2 == 0 and "female" or "male"
end

-- members = array of {sex = "male"|"female", stage = "adult"|"child"}. Returns counts.
function M.counts(members)
  local males, females, children = 0, 0, 0
  for _, m in ipairs(members or {}) do
    if m.stage == "child" then
      children = children + 1
    elseif m.sex == "female" then
      females = females + 1
    else
      males = males + 1
    end
  end
  return {males = males, females = females, children = children,
    adults = males + females, total = males + females + children}
end

-- How many adult food portions this house eats. Children count half.
function M.mouths(c)
  return (c and ((c.adults or 0) + (c.children or 0) * M.CHILD_RATE)) or 0
end

-- Eligibility: one adult of each sex, provisions met, a free bed, and no birth in the house too recently.
-- `beds_free` is capacity minus every current occupant (children included).
-- Returns (eligible, counts).
function M.eligible(members, critical_unmet, beds_free, tick, ready_at)
  local c = M.counts(members)
  if c.males < 1 or c.females < 1 then return false, c end
  if critical_unmet then return false, c end
  if (beds_free or 0) < 1 then return false, c end
  if ready_at and tick and tick < ready_at then return false, c end
  return true, c
end

-- Does this house have a baby this evaluation?
function M.roll_birth(house_un, tick, salt, p)
  return M.roll(house_un, tick, salt or 0) < (p or M.BREED_P)
end

return M
