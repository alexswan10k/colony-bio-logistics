-- Locale audit: every caption key written literally in the mod must exist in mod/locale/en/locale.cfg.
-- A typo here is invisible offline - in game the player just sees the raw key ("colony-gui.crate-emptty")
-- instead of a sentence - so this test reads the sources and the locale file and compares them.
--
-- Only literal keys are checked: `{"colony-status." .. r.key}` is built at runtime, and the vocabulary those
-- concatenations draw from is covered by the advice tests in model_test.lua. Candidates ending in "-" are
-- concatenation stems (e.g. {"colony-advice.factor-", ...}), not keys.
local function read(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local s = f:read("*a")
  f:close()
  return s
end

-- [section] -> {key -> text}
local function parse_locale(text)
  local sections, current = {}, nil
  for line in text:gmatch("[^\n]+") do
    local header = line:match("^%[([^%]]+)%]")
    if header then
      current = {}
      sections[header] = current
    elseif current then
      local key, value = line:match("^([%w_%-%.]+)=(.*)$")
      if key then current[key] = value end
    end
  end
  return sections
end

local LOCALE = "mod/locale/en/locale.cfg"

describe("locale", function()
  local sections = parse_locale(read(LOCALE))
  local function exists(full)
    local section, key = full:match("^(colony[a-z%-]*)%.(.+)$")
    if not (section and key) then return false end
    local s = sections[section]
    return (s and s[key] ~= nil) and true or false
  end

  it("parses the sections the panels use", function()
    for _, section in ipairs({"colony-gui", "colony-gui-hut", "colony-gui-info", "colony-gui-crate",
        "colony-advice", "colony-status", "colony-message", "colony-milestone", "colony-death"}) do
      truthy(sections[section], "missing locale section [" .. section .. "]")
    end
  end)

  it("every literal caption key in the mod exists in the locale", function()
    local missing, seen = {}, {}
    local function scan(path)
      local text = read(path)
      for key in text:gmatch('{"(colony[a-z%-]*%.[%w_%-%.]+)"') do
        if not seen[key] and not key:match("%-$") then
          seen[key] = true
          if not exists(key) then missing[#missing + 1] = key end
        end
      end
    end
    for file in io.popen("find mod/scripts mod/prototypes mod/data.lua -name '*.lua' 2>/dev/null"):lines() do
      scan(file)
    end
    -- Guard against a silent pass if the scan ever stops finding anything.
    truthy(next(seen) ~= nil, "found no literal caption keys at all")
    table.sort(missing)
    eq(table.concat(missing, ", "), "", "caption keys missing from " .. LOCALE)
  end)

  it("the advice vocabulary the panels build at runtime is present", function()
    -- model/advice.lua returns these key names; feedback.lua prefixes them, so they are not literal captions
    -- and the scan above cannot see them. Listed here on purpose: adding a case to advice.lua without a string
    -- is exactly the bug this catches.
    local advice_keys = {
      "haul-off", "no-food", "no-houses", "no-beds", "no-tool", "no-haulers", "under-attack", "no-issues", "title",
      "hut-paused", "hut-quota-met", "hut-nothing-to-do", "hut-tool-coming", "hut-no-tool-in-hall",
      "hut-tool-waiting", "hut-tool-crafting", "hut-tool-ingredients", "hut-haul-off", "hut-no-inputs",
      "hut-no-sites", "hut-no-workers",
      "req-stocked", "req-delivering", "req-no-stock", "req-haul-off", "req-queued",
      "factor-food", "factor-housing", "factor-leisure", "factor-recreation", "factor-scenic", "factor-pollution",
      "factor-deaths",
    }
    local status_keys = {
      "house-empty", "house-ok", "house-ok-inspired", "house-starving", "house-lacking", "hut-working",
      "growth-ok", "growth-no-beds", "growth-no-houses", "growth-closed", "growth-low", "growth-leaving",
      "pool-out", "pool-ready", "pool-no-cars", "pool-no-fuel",
      "station-ready", "station-out", "station-worn", "station-no-trailers",
      "collector-filling", "collector-producing", "collector-full",
      "tavern-serving", "tavern-idle", "tavern-dry",
      "canteen-serving", "canteen-idle", "canteen-full", "canteen-empty",
      "cemetery-room", "cemetery-full",
      "clinic-treating", "clinic-no-medicine", "clinic-idle", "clinic-no-doctor",
      "platform-waiting", "platform-idle", "platform-no-stop",
    }
    local missing = {}
    for _, k in ipairs(advice_keys) do
      if not exists("colony-advice." .. k) then missing[#missing + 1] = "colony-advice." .. k end
    end
    for _, k in ipairs(status_keys) do
      if not exists("colony-status." .. k) then missing[#missing + 1] = "colony-status." .. k end
    end
    eq(table.concat(missing, ", "), "", "advice/status keys missing from " .. LOCALE)
  end)

  it("status lines keep their placeholders in step with the arguments passed", function()
    -- set_status gets a caption plus up to three args; a caption that names __4__ would silently print the
    -- raw token in game.
    for _, section in ipairs({"colony-advice", "colony-status"}) do
      for key, text in pairs(sections[section]) do
        local highest = 0
        for n in text:gmatch("__(%d+)__") do highest = math.max(highest, tonumber(n)) end
        truthy(highest <= 3, section .. "." .. key .. " uses __" .. highest .. "__ but labels pass at most three")
      end
    end
  end)
end)
