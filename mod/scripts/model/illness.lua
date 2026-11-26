---@diagnostic enable: undefined-field, missing-fields
-- PURE: illness and treatment (#47, decided on #20; design §2.4). Colonists are individual units, so sickness is
-- kept per colonist, but everything is rolled once per colony evaluation, never per tick.
--   * Smoker's Lung: breathing the colony's pollution. Never passes on its own and kills if untreated.
--   * Food Poisoning: a house eating food that is nearly spoiled. Passes on its own after a few evaluations.
--   * Swamp Fever (#70): working on a spore surface (Gleba). Never passes on its own, kills if untreated.
--   * Heat Stroke (#70): working in the open on Vulcanus, away from a pressurized Habitat Dome. Off-world
--     surfaces have no pollutant type, so this is keyed on planet identity, not pollution. Fatal untreated.
-- No contagion (yet). A sick colonist works at half speed. A Clinic's doctors cure patients, one Herbal Medicine
-- each. Rolls are a hash of (unit number, tick, salt) so a run is deterministic and needs no stored generator.
local vulcanus = require("scripts.model.vulcanus")
local M = {}

M.LUNG_RATE = 0.02        -- chance per evaluation at full pollution (scales linearly with the pollution ratio)
M.POISON_RATE = 0.3       -- chance per occupant when the house eats nearly spoiled food
M.SWAMP_RATE = 0.04       -- chance per evaluation at full spore exposure (Gleba; #70)
M.HEAT_RATE = vulcanus.HEAT_RATE  -- chance per evaluation in the Vulcanus open air (#70)
M.ROTTEN = 0.75           -- spoil fraction at which food counts as nearly spoiled
M.CURES_PER_DOCTOR = 2    -- patients one doctor on duty cures per evaluation
M.MEDICINE = "colony-herbal-medicine"
M.STOCK = 10              -- medicine a Clinic keeps on hand

M.DISEASES = {
  lung = {fatal_after = 40},           -- evaluations untreated before it kills
  poison = {recovers_after = 4},       -- evaluations before it passes by itself
  swamp_fever = {fatal_after = 24},    -- evaluations untreated before it kills (Gleba; #70)
  heat_stroke = {fatal_after = vulcanus.FATAL_AFTER},  -- untreated in the Vulcanus heat (#70)
}

-- Only a colonist actually on a job breathes spores at work (#70 review). This is the full on-duty state
-- vocabulary of work.lua (plus the M3 patrol/militia states); children, idle, sleeping, sheltering, travelling
-- and waiting passengers are deliberately excluded, so they cannot catch a fatal occupational disease.
M.ON_DUTY = {working = true, to_site = true, to_hut = true, hunting = true, guarding = true,
  ["militia-fight"] = true, ["militia-hold"] = true, patrolling = true, to_construct = true,
  to_tower = true, to_bin = true, to_hall = true, driving = true, to_pool = true, to_park = true}
function M.on_duty(st)
  return st ~= nil and st.job ~= nil and st.job ~= "child" and M.ON_DUTY[st.state] == true
end

-- A deterministic number in [0, 1) for this colonist, tick and purpose.
function M.roll(un, tick, salt)
  local h = (un * 2654435761 + tick * 40503 + (salt or 0) * 97) % 4294967296
  h = (h * 1103515245 + 12345) % 2147483648
  return h / 2147483648
end

-- Does a colonist catch `kind` this evaluation? `exposure` is 0..1 (pollution ratio, spore exposure,
-- or 1 for a rotten meal). Unknown kinds have no rate: the old fallback handed them POISON_RATE, the
-- most lethal rate in the game, which was a bug.
local RATES = {lung = M.LUNG_RATE, poison = M.POISON_RATE, swamp_fever = M.SWAMP_RATE,
  heat_stroke = M.HEAT_RATE}
function M.catches(kind, exposure, r)
  local rate = RATES[kind] or 0
  return r < rate * math.max(0, math.min(exposure or 0, 1))
end

-- One evaluation of an untreated illness. rec = {kind, age}. Returns "dies", "recovers" or nil.
function M.step(rec)
  rec.age = (rec.age or 0) + 1
  local d = M.DISEASES[rec.kind] or {}
  if d.recovers_after and rec.age >= d.recovers_after then return "recovers" end
  if d.fatal_after and rec.age >= d.fatal_after then return "dies" end
  return nil
end

-- Patients cured this evaluation: limited by the sick, the doctors on duty and the medicine on hand.
function M.treat(patients, doctors, medicine)
  return math.max(0, math.min(patients or 0, (doctors or 0) * M.CURES_PER_DOCTOR, medicine or 0))
end

-- A sick colonist takes twice as long over each job.
function M.work_ticks(base, sick) return sick and base * 2 or base end

-- Medicine a Clinic asks haulers for.
function M.wants(have, inflight)
  local want = M.STOCK - (have or 0) - (inflight or 0)
  if want >= 1 then return {{item = M.MEDICINE, count = want}} end
  return {}
end

return M
