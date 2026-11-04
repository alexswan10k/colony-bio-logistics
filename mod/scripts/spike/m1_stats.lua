-- M1 production statistics spike (#89): determine the sign convention of LuaFlowStatistics::on_flow.
-- The counts get merged at the end of the tick, so this spike checks the current-tick samples immediately
-- after the call, and the merged counts after another tick.
-- Run: TICKS=300 scripts/headless-spike.sh m1_stats
local core = require("scripts.spike.core")

core.register("m1_stats", {
  issue = 89, auto = true, desc = "item flow statistics: on_flow sign convention", usage = "",
  run = function(ctx)
    local s = ctx.surface
    local force = game.forces["player"]
    local stats = force.get_item_production_statistics(s)
    local item = "colony-forage"
    local function cur(it)
      local ok, i, o = pcall(function() return stats.get_current_input_sample(it), stats.get_current_output_sample(it) end)
      return ok, i, o
    end
    local i0, o0 = stats.get_input_count(item), stats.get_output_count(item)
    ctx.log(string.format("before: input=%s output=%s", tostring(i0), tostring(o0)))
    local ok, err = pcall(function() stats.on_flow(item, 5) end)
    ctx.check("on_flow(+5) does not error", ok, tostring(err))
    local okc, si, so = cur(item)
    ctx.log(string.format("current-tick samples after +5: ok=%s input=%s output=%s", tostring(okc), tostring(si), tostring(so)))
    -- the merge happens at the end of this tick; another tick later the counts must have moved
    ctx.after(2, function()
      local i1, o1 = stats.get_input_count(item), stats.get_output_count(item)
      ctx.log(string.format("counts next tick: input=%s output=%s (delta in=%s out=%s)", tostring(i1), tostring(o1), tostring(i1 - i0), tostring(o1 - o0)))
      ctx.check("on_flow(+5) eventually moves exactly one counter by 5",
        (i1 - i0 == 5) ~= (o1 - o0 == 5), string.format("input %+d output %+d", i1 - i0, o1 - o0))
      ctx.log(i1 - i0 == 5 and "POSITIVE on_flow -> input statistics (production side)"
        or (o1 - o0 == 5 and "POSITIVE on_flow -> output statistics (consumption side)" or "no movement: on_flow is a no-op for mod items?"))
      -- undo: same sign moves it back
      local sign = i1 - i0 == 5 and -1 or (o1 - o0 == 5 and -1 or 0)
      if sign ~= 0 then pcall(function() stats.on_flow(item, sign * 5) end) end
      ctx.finish()
    end)
  end,
})
