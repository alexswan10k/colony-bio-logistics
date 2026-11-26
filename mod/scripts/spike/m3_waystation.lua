-- #56 remainder: Waystations as separate territory nodes. A Watchtower must be inside claimed land and
-- claims 48 tiles; a Waystation may be placed inside OR up to 16 tiles outside the boundary and claims 96.
-- The engine checks here are the ones unit tests cannot make: placement really fires the build handler,
-- the registry survives a real entity lifecycle, and destroying the node really releases the ring.
-- Run: scripts/headless-spike.sh m3_waystation
local core = require("scripts.spike.core")
local colony = require("scripts.colony")
local territory = require("scripts.territory")
local labour = require("scripts.model.labour")
local ws = require("scripts.model.waystation")

core.register("m3_waystation", {
  issue = 56, auto = true,
  desc = "waystation: a separate 96-tile territory node, buildable inside or just outside the boundary",
  usage = "",
  run = function(ctx)
    local s, p = ctx.surface, ctx.position
    ctx.flat_area(180, "grass-1")
    s.always_day, s.freeze_daytime, s.daytime = true, true, 0
    local function build(name, pos)
      return s.create_entity{name = name, position = pos, force = "player", raise_built = true}
    end

    -- ---------- prototypes ----------
    ctx.check("colony-waystation entity exists and is a marker, not a container",
      prototypes.entity["colony-waystation"] ~= nil
        and prototypes.entity["colony-waystation"].type == "simple-entity-with-owner"
        and prototypes.item["colony-waystation"] ~= nil
        and prototypes.recipe["colony-waystation"] ~= nil)
    ctx.check("the preview ring matches the 96-tile claim",
      prototypes.entity["colony-waystation"].radius_visualisation_specification ~= nil
        and prototypes.entity["colony-waystation"].radius_visualisation_specification.distance == ws.RADIUS,
      "expected " .. tostring(ws.RADIUS))
    ctx.check("nobody works a waystation (no labour job)", labour.HUTS["colony-waystation"] == nil)
    local unlocked = false
    for _, e in ipairs(prototypes.technology["colony-logistics"].effects or {}) do
      if e.type == "unlock-recipe" and e.recipe == "colony-waystation" then unlocked = true end
    end
    ctx.check("Colony Logistics unlocks the waystation recipe", unlocked)

    -- ---------- a town with one hall ----------
    local hall = build("colony-town-hall", {p.x, p.y})
    ctx.check("hall built", hall and hall.valid)
    local cid = territory.owner_at(s.index, p)
    local c = storage.colonies[cid]
    ctx.check("hall founded colony " .. tostring(cid), c ~= nil)
    local before = #territory.chunks(c)
    ctx.check("the far point starts outside territory", territory.owner_at(s.index, {x = p.x + 150, y = p.y}) == nil)

    -- ---------- rejection: far outside ----------
    local far = build("colony-waystation", {x = p.x + 160, y = p.y})
    ctx.check("a waystation placed far outside territory is refused", not (far and far.valid))
    ctx.check("the refused waystation was not registered",
      c.waystations == nil or next(c.waystations) == nil)

    -- ---------- acceptance: just outside the boundary ----------
    local station = build("colony-waystation", {x = p.x + 72, y = p.y})
    ctx.check("a waystation 8 tiles outside the hall boundary is built", station and station.valid)
    ctx.check("the waystation joined the nearest colony's registry",
      station and c.waystations and c.waystations[station.unit_number] == station,
      "registry=" .. tostring(c.waystations ~= nil))
    local emitters = territory.emitters(c)
    local found = false
    for _, e in ipairs(emitters) do
      if e.entity == station and e.radius == ws.RADIUS then found = true end
    end
    ctx.check("the live waystation is a 96-tile territory emitter", found, "emitters=" .. tostring(#emitters))
    ctx.check("territory extends 150 tiles from the hall", territory.owner_at(s.index, {x = p.x + 150, y = p.y}) == cid)
    ctx.check("territory stops at the waystation's edge",
      territory.owner_at(s.index, {x = p.x + 170, y = p.y}) == nil)
    ctx.check("the claim grew by more than one chunk", #territory.chunks(c) > before,
      "before=" .. tostring(before) .. " after=" .. tostring(#territory.chunks(c)))

    -- ---------- death releases the ring ----------
    local un = station and station.unit_number
    if station and station.valid then station.destroy() end
    ctx.after(1, function()
      ctx.check("destroying the waystation unregisters it", c.waystations[un] == nil)
      ctx.check("the far point is unowned again", territory.owner_at(s.index, {x = p.x + 150, y = p.y}) == nil)
      ctx.check("the hall's own land is untouched", territory.owner_at(s.index, {x = p.x, y = p.y}) == cid)
      ctx.finish()
    end)
  end,
})
