-- Tiny dependency-free test runner. Usage: luajit tests/runner.lua [pattern]
package.path = "./?.lua;./mod/?.lua;" .. package.path
local pattern = arg and arg[1]
local passed, failed, failures = 0, 0, {}

function _G.describe(name, fn) _G.__suite = name; fn() end
function _G.it(name, fn)
  local full = (_G.__suite or "") .. " :: " .. name
  if pattern and not full:find(pattern, 1, true) then return end
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; failures[#failures + 1] = full .. "\n    " .. tostring(err) end
end
function _G.eq(a, b, msg) if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end
function _G.truthy(v, msg) if not v then error((msg or "expected truthy") .. " (got " .. tostring(v) .. ")", 2) end end
function _G.near(a, b, eps, msg) if math.abs(a - b) > (eps or 1e-6) then error((msg or "near") .. ": " .. a .. " vs " .. b, 2) end end

local handle = io.popen("ls tests/*_test.lua")
for file in handle:lines() do dofile(file) end
handle:close()

print(string.format("%d passed, %d failed", passed, failed))
for _, f in ipairs(failures) do print("FAIL " .. f) end
os.exit(failed == 0 and 0 or 1)
