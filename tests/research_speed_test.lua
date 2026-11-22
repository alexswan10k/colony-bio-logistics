-- Adapter tests for the durable, force-wide laboratory speed modifier (#48 slice A). Mocks encode API
-- *beliefs* (LuaForce.laboratory_speed_modifier is RW; on_technology_effects_reset carries `force`); the
-- engine facts are pinned headlessly by s20_inspired_research. The storage record is the regression guard:
-- a cold Lua state keeps `storage` but loses every module-local variable.
describe("research_speed adapter (#48 slice A)", function()
  local mock = require("tests.mock_factorio")

  local function setup()
    local env = mock.install(); env = env.reset()
    local rs = require("scripts.research_speed")
    local force = {name = "player", valid = true, laboratory_speed_modifier = 0}
    game.forces["player"] = force
    storage.colonies = {
      [1] = {hall = {valid = true, force = force}, inspiration = {share = 1, quality = 1.25}},
    }
    storage.research_speed = {}
    return env, rs, force
  end

  -- Simulate a new Lua state after a save/load: package.loaded is cleared but `storage` is the saved one.
  local function cold_load()
    package.loaded["scripts.research_speed"] = nil
    return require("scripts.research_speed")
  end

  it("writes the pure bonus to the force modifier at evaluation time", function()
    local _, rs, force = setup()
    eq(rs.apply(force), 0.25)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
    eq(storage.research_speed.player.base, 0)
    eq(storage.research_speed.player.applied, 0.25)
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
    storage.colonies[2].inspiration = {share = 0, quality = 0}
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
  end)

  it("a colony on another force is ignored and leaves no record", function()
    local _, rs, force = setup()
    local other = {name = "enemy", valid = true, laboratory_speed_modifier = 0}
    game.forces["enemy"] = other
    storage.colonies[2] = {hall = {valid = true, force = other},
      inspiration = {share = 1, quality = 1.5}}
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
    eq(other.laboratory_speed_modifier, 0)
    eq(storage.research_speed.enemy, nil)
  end)

  it("a foreign write between evaluations is preserved as the new base", function()
    local _, rs, force = setup()
    rs.apply(force)
    force.laboratory_speed_modifier = 0.75           -- another mod (or a tech) adds +0.5
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.75, 1e-12)
    eq(storage.research_speed.player.base, 0.5)
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

  -- C1: the whole point of the durable record. Load with the SAVED bonus still in the engine modifier but
  -- inspiration already changed (night, or the ale removed before the first evaluation): the cold path must
  -- use the saved applied value, not the new target, or +0.25 stays forever.
  it("CRITICAL: cold load with the target dropped to zero clears the saved bonus", function()
    local _, rs, force = setup()
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
    force.laboratory_speed_modifier = 0.25            -- engine saved our bonus
    storage.colonies[1].inspiration = {share = 0, quality = 0}
    local cold = cold_load()
    cold.apply(force)
    near(force.laboratory_speed_modifier, 0, 1e-12)
    cold.apply(force)
    near(force.laboratory_speed_modifier, 0, 1e-12)
  end)

  it("CRITICAL: cold load with a lower target writes the saved base plus the NEW bonus", function()
    local _, rs, force = setup()
    rs.apply(force)
    force.laboratory_speed_modifier = 0.25
    storage.colonies[1].inspiration = {share = 0.5, quality = 1.25}   -- 0.125 now
    cold_load().apply(force)
    near(force.laboratory_speed_modifier, 0.125, 1e-12)
  end)

  it("CRITICAL: cold load keeps a foreign base when inspiration disappears", function()
    local _, rs, force = setup()
    storage.research_speed.player = {base = 0.4, applied = 0.25}
    force.laboratory_speed_modifier = 0.65            -- 0.4 foreign + our 0.25
    storage.colonies[1].inspiration = {share = 0, quality = 0}
    cold_load().apply(force)
    near(force.laboratory_speed_modifier, 0.4, 1e-12)
  end)

  -- M1: no saved record means we have never written this modifier; a foreign 0.4 must stay the base, with
  -- our bonus added on top. The rejected version produced 0.4 here forever.
  it("MAJOR: cold start with a foreign non-zero base still gets the Inspired bonus", function()
    local _, rs, force = setup()
    force.laboratory_speed_modifier = 0.4
    cold_load().apply(force)
    near(force.laboratory_speed_modifier, 0.65, 1e-12)
    eq(storage.research_speed.player.base, 0.4)
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.65, 1e-12)
  end)

  -- M2: the last hall is gone, so no colony can justify the bonus; the dormant evaluate() path calls
  -- apply_all(), which must zero the modifier even though the colony's hall can no longer name its force.
  it("MAJOR: losing the last hall drops the force bonus via apply_all", function()
    local _, rs, force = setup()
    rs.apply(force)
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
    storage.colonies[1].hall.valid = false
    storage.colonies[1].inspiration = {share = 0, quality = 0}
    rs.apply_all()
    near(force.laboratory_speed_modifier, 0, 1e-12)
  end)

  it("apply_all leaves forces we never touched alone", function()
    local _, rs, force = setup()
    rs.apply(force)
    local other = {name = "enemy", valid = true, laboratory_speed_modifier = 0.7}
    game.forces["enemy"] = other
    rs.apply_all()
    near(force.laboratory_speed_modifier, 0.25, 1e-12)
    eq(other.laboratory_speed_modifier, 0.7)
  end)

  it("MAJOR: the real dormant evaluate() path clears the bonus when the hall dies", function()
    local env = mock.install(); env = env.reset()
    require("scripts.store").init()
    local colony_mod = require("scripts.colony")   -- loads the real evaluate() early-return
    local force = {name = "player", valid = true, laboratory_speed_modifier = 0.25}
    game.forces["player"] = force
    storage.research_speed = {player = {base = 0, applied = 0.25}}
    storage.colonies = {[1] = {id = 1, hall = {valid = false}}}
    colony_mod.evaluate({colony_id = 1})
    near(force.laboratory_speed_modifier, 0, 1e-12)
  end)

  it("sheltered and exposed scholars are excluded from the inspired share", function()
    local env = mock.install(); env = env.reset()
    local colony_mod = require("scripts.colony")
    local hall = {valid = true, surface = {daytime = 0.1, freeze_daytime = false}}
    local c = {hall = hall, colonists = {[1] = {valid = true}, [2] = {valid = true}}}
    local houses = {{inspiration_quality = 1.25}}
    local split = {{1, 2}}
    storage.unit_state = {
      [1] = {job = "research", hut = {entity = {valid = true}}, state = "working"},
      [2] = {job = "research", hut = {entity = {valid = true}}, state = "sheltered"},
    }
    local insp = colony_mod.compute_inspiration(c, split, houses)
    near(insp.share, 1, 1e-12); near(insp.quality, 1.25, 1e-12)
    storage.unit_state[1].state = "to_shelter"
    storage.unit_state[2].state = "exposed"
    insp = colony_mod.compute_inspiration(c, split, houses)
    eq(insp.share, 0); eq(insp.quality, 0)
  end)

  it("mixed tavern and theatre scholars average their quality, not take the max", function()
    local env = mock.install(); env = env.reset()
    local colony_mod = require("scripts.colony")
    local inspiration = require("scripts.model.inspiration")
    local c = {hall = {valid = true, surface = {daytime = 0.1, freeze_daytime = false}},
      colonists = {[1] = {valid = true}, [2] = {valid = true}, [3] = {valid = true}, [4] = {valid = true}}}
    -- Two scholars in Tavern houses (1.25) and two in Theatre houses (1.5).
    local houses = {{inspiration_quality = 1.25}, {inspiration_quality = 1.5}}
    local split = {{1, 2}, {3, 4}}
    storage.unit_state = {}
    for i = 1, 4 do storage.unit_state[i] = {job = "research", hut = {entity = {valid = true}}, state = "working"} end
    local insp = colony_mod.compute_inspiration(c, split, houses)
    near(insp.share, 1, 1e-12)
    near(insp.quality, 1.375, 1e-12)
    -- research_bonus(share, quality) must equal the mean of the four scholars' individual bonuses.
    near(inspiration.research_bonus(insp.share, insp.quality), 0.375, 1e-12)
  end)

  it("a town with no inspiration writes 0 and leaves a foreign modifier alone", function()
    local _, rs, force = setup()
    storage.colonies[1].inspiration = {share = 0, quality = 0}
    rs.apply(force)
    eq(force.laboratory_speed_modifier, 0)
    eq(storage.research_speed.player, nil)   -- nothing to track: keeps Tavern-less towns identical
    force.laboratory_speed_modifier = 0.4
    rs.apply(force)
    eq(force.laboratory_speed_modifier, 0.4)
  end)
end)
