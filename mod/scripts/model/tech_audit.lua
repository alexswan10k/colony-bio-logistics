---@diagnostic enable: undefined-field, missing-fields
-- PURE: static audit of the technology graph. The adapter (`scripts/spike/m1_tech.lua`) turns the game's
-- prototypes into the plain `graph` below; this module only reasons about it, so the rules are unit-testable
-- without Factorio. It guards the seam between the colony tree and the vanilla tree: a colony technology
-- must be reachable, must have a lab that can research it, and must not offer a recipe whose vanilla
-- ingredients cannot be made yet.
--
-- graph = {
--   techs   = {[name] = {prerequisites = {name...}, effects = {{type=, recipe=}...},
--                        packs = {item...}, trigger = bool}},
--   recipes = {[name] = {enabled = bool, ingredients = {{type=, name=}...},
--                        results = {{type=, name=}...}}},
--   items   = {[name] = true},
--   fluids  = {[name] = true},
--   raw     = {[name] = true}, -- gathered resources (ore, stone, wood) that no technology can gate
--   labs    = {{name=, inputs={item...}, unlocked_by=tech or nil}},
-- }
-- `scope` is the prototype-name prefix that is ours (e.g. "colony-"), and `exclude` is an optional set of
-- spike-only technology names that must not be judged as shipped content.
local M = {}

-- ---@param graph table
-- ---@param scope string
-- ---@param exclude table<string, boolean>|nil
-- ---@return table[] problems
function M.audit(graph, scope, exclude)
  local techs = graph.techs or {}
  local recipes = graph.recipes or {}
  local items = graph.items or {}
  local fluids = graph.fluids or {}
  local raw = graph.raw or {}
  local labs = graph.labs or {}
  exclude = exclude or {}

  local problems = {}
  local function add(kind, message, tech, recipe)
    problems[#problems + 1] = {kind = kind, message = message, tech = tech, recipe = recipe}
  end
  local function ours(name) return type(name) == "string" and name:sub(1, #scope) == scope end
  local function ours_tech(name) return ours(name) and not exclude[name] end
  -- Space Age generates `<thing>-recycling` recipes for almost every item, including ours. They are item -> item
  -- loops, not a supply chain, so they must never count as the way to make an ingredient.
  local function is_recycling(recipe)
    for _, category in ipairs(recipe.categories or {}) do
      if category == "recycling" then return true end
    end
    return false
  end

  -- Derived indexes: who unlocks what, who produces what, and the prerequisite edges.
  local unlockers = {}
  local producers = {}
  local children = {}
  for name, t in pairs(techs) do
    for _, e in ipairs(t.effects or {}) do
      if e.type == "unlock-recipe" and e.recipe then
        unlockers[e.recipe] = unlockers[e.recipe] or {}
        table.insert(unlockers[e.recipe], name)
      end
    end
  end
  for name, r in pairs(recipes) do
    if not is_recycling(r) then
      for _, res in ipairs(r.results or {}) do
        if res.type == "item" and res.name then
          producers[res.name] = producers[res.name] or {}
          table.insert(producers[res.name], name)
        end
      end
    end
  end
  for name, t in pairs(techs) do
    children[name] = children[name] or {}
    for _, p in ipairs(t.prerequisites or {}) do
      children[p] = children[p] or {}
      table.insert(children[p], name)
    end
  end

  -- 1. Every prerequisite must exist, otherwise the tech is silently unreachable.
  for name, t in pairs(techs) do
    if ours_tech(name) then
      for _, p in ipairs(t.prerequisites or {}) do
        if not techs[p] then
          add("missing-prerequisite", name .. " requires missing technology " .. p, name)
        end
      end
    end
  end

  -- 2. Reachability: walk down from the technologies that have no prerequisites (the trigger techs).
  local reached = {}
  local queue = {}
  for name, t in pairs(techs) do
    if #(t.prerequisites or {}) == 0 then
      reached[name] = true
      queue[#queue + 1] = name
    end
  end
  local head = 1
  while head <= #queue do
    local name = queue[head]
    head = head + 1
    for _, child in ipairs(children[name] or {}) do
      if not reached[child] then
        reached[child] = true
        queue[#queue + 1] = child
      end
    end
  end
  for name in pairs(techs) do
    if ours_tech(name) and not reached[name] then
      add("unreachable", name .. " is not reachable from any starting technology", name)
    end
  end

  -- 3. Every unlock effect must name a real recipe, and no recipe should be unlocked twice. Only our own
  -- technologies are compared: Space Age's `recycling` technology gains an effect for every recyclable recipe.
  for name, t in pairs(techs) do
    if ours_tech(name) then
      for _, e in ipairs(t.effects or {}) do
        if e.type == "unlock-recipe" and e.recipe and not recipes[e.recipe] then
          add("missing-recipe", name .. " unlocks missing recipe " .. e.recipe, name, e.recipe)
        end
      end
    end
  end
  for recipe, list in pairs(unlockers) do
    if ours(recipe) then
      local mine = {}
      for _, tech_name in ipairs(list) do
        if ours_tech(tech_name) then mine[#mine + 1] = tech_name end
      end
      if #mine > 1 then
        table.sort(mine)
        add("duplicate-unlock", recipe .. " is unlocked by " .. table.concat(mine, ", "), nil, recipe)
      end
    end
  end

  -- 4. Every disabled colony recipe needs a home. A disabled recipe nobody unlocks can never be used.
  for name, r in pairs(recipes) do
    if ours(name) and r.enabled == false and not unlockers[name] then
      add("orphan-recipe", name .. " is disabled and no technology unlocks it", nil, name)
    end
  end

  -- 5. Lab coverage: the pack list of a technology must be accepted by a lab that is available at that point.
  local function closure(tech_name)
    local seen = {}
    local function walk(n)
      if seen[n] or not techs[n] then return end
      seen[n] = true
      for _, p in ipairs(techs[n].prerequisites or {}) do walk(p) end
    end
    walk(tech_name)
    return seen
  end
  local function lab_available(lab, closed)
    return lab.unlocked_by == nil or closed[lab.unlocked_by] == true
  end
  for name, t in pairs(techs) do
    if ours_tech(name) and #(t.packs or {}) > 0 then
      local closed = closure(name)
      local found = false
      for _, lab in ipairs(labs) do
        local accepts = lab_available(lab, closed)
        for _, pack in ipairs(t.packs) do
          local has = false
          for _, input in ipairs(lab.inputs or {}) do if input == pack then has = true; break end end
          if not has then accepts = false; break end
        end
        if accepts then found = true; break end
      end
      if not found then
        add("no-lab", name .. " needs packs no available lab accepts (" ..
          table.concat(t.packs, ", ") .. ")", name)
      end
    end
  end

  -- 6. Recipe ingredients must be makeable at the point the technology unlocks the recipe. Raw resources and
  -- colony-made goods are exempt: the first has no recipe, the second is the colony's own supply chain.
  local function recipe_available(recipe_name, closed)
    local r = recipes[recipe_name]
    if not r then return false end
    if r.enabled == true then return true end
    for _, tech_name in ipairs(unlockers[recipe_name] or {}) do
      if closed[tech_name] then return true end
    end
    return false
  end
  for name, t in pairs(techs) do
    if ours_tech(name) then
      local closed = closure(name)
      for _, e in ipairs(t.effects or {}) do
        if e.type == "unlock-recipe" and recipes[e.recipe] then
          for _, ing in ipairs(recipes[e.recipe].ingredients or {}) do
            if ing.type == "fluid" then
              if not fluids[ing.name] then
                add("missing-fluid", e.recipe .. " needs missing fluid " .. ing.name, name, e.recipe)
              end
            elseif ing.type == "item" and not ours(ing.name) and not raw[ing.name] then
              if not items[ing.name] then
                add("missing-item", e.recipe .. " needs missing item " .. ing.name, name, e.recipe)
              else
                local made = producers[ing.name] or {}
                if #made > 0 then
                  local ok = false
                  for _, rname in ipairs(made) do
                    if recipe_available(rname, closed) then ok = true; break end
                  end
                  if not ok then
                    add("unmakeable-ingredient", e.recipe .. " needs " .. ing.name ..
                      ", whose recipe is behind a technology this one does not require", name, e.recipe)
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  table.sort(problems, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    return (a.tech or "") < (b.tech or "")
  end)
  return problems
end

-- Group problems by kind: {[kind] = {messages...}}. Handy for a spike that wants one check per rule.
-- ---@param problems table[]
-- ---@return table<string, string[]>
function M.by_kind(problems)
  local out = {}
  for _, p in ipairs(problems) do
    out[p.kind] = out[p.kind] or {}
    table.insert(out[p.kind], p.message)
  end
  return out
end

return M
