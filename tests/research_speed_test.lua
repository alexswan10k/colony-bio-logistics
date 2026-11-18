-- Adapter tests for the force-wide laboratory speed modifier (#48 slice A). Mocks encode API *beliefs*
-- (LuaForce.laboratory_speed_modifier is RW; on_technology_effects_reset carries `force`); the engine facts
-- are pinned headlessly by s20_inspired_research.
describe("research_speed adapter (#48 slice A)", function()
  local mock = require("tests.mock_factorio")

  local function force_with(name, value)
    return {name = name, valid = true, laboratory_speed_modifier = value}
  end

  local function setup()
    local env = mock.install(); env = env.reset()
    local rs = require("scripts.research_speed")
    local force = force_with("player", 0)
    storage.colonies = {
      [1] = {hall = {valid = true, force = force}, inspiration = {share = 1, quality = 1.25}},
    }
    return env, rs, force
  end

  it("writes the pure bonus to the force modifier at evaluation time", function()
    local _, rs, force = setup()
    eq(rs.apply(force), 0.25)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)   -- idempotent
  end)

  it("scales by inspired-scholar share and by quality", function()
    local _, rs, force = setup()
    storage.colonies[1].inspiration = {share = 0.5, quality = 1.25}
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.125, 1e-12)
    storage.colonies[1].inspiration = {share = 1, quality = 1.5}
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.5, 1e-12)
  end)

  it("two colonies on one force combine by max, never by sum", function()
    local _, rs, force = setup()
    storage.colonies[2] = {hall = {valid = true, force = force},
      inspiration = {share = 1, quality = 1.5}}
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.5, 1e-12)
  end)

  it("a colony on another force is ignored", function()
    local _, rs, force = setup()
    local other = force_with("enemy", 0)
    storage.colonies[2] = {hall = {valid = true, force = other},
      inspiration = {share = 1, quality = 1.5}}
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
    eq(other.laboratory_speed_modifier, 0)
  end)

  it("a foreign write between evaluations is preserved as the new base", function()
    local _, rs, force = setup()
    rs.apply(force)
    force.laboratory_speed_modifier = 0.75           -- another mod (or a tech) adds +0.5
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.75, 1e-12)
  end)

  it("reset_technology_effects wipes the bonus and the event self-heals it", function()
    local env, rs, force = setup()
    rs.apply(force)
    force.laboratory_speed_modifier = 0              -- engine discards script modifiers
    env.fire(defines.events.on_technology_effects_reset, {force = force})
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
  end)

  it("a fresh load does not double-add the saved modifier (module-local cache is empty)", function()
    local _, rs, force = setup()
    rs.apply(force)
    force.laboratory_speed_modifier = 0.25            -- engine saved our bonus in the force state
    rs.forget_cache()                                -- new Lua state: applied[] is empty again
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
  end)

  it("a town with no inspiration writes 0 and leaves a foreign modifier alone", function()
    local _, rs, force = setup()
    storage.colonies[1].inspiration = {share = 0, quality = 0}
    rs.apply(force)
    eq(force.laboratory_speed_modifier, 0)
    force.laboratory_speed_modifier = 0.4
    rs.apply(force)
    eq(force.laboratory_speed_modifier, 0.4)
  end)
end)
