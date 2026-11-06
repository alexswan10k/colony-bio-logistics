-- EmmyLua domain types for the colony (typesafety layer, #54).
-- This file is checked by LuaLS but never required at runtime: it only declares shapes the
-- pure models read and adapters write. Field typos (hut.weear vs hut.wear) are caught by
-- `scripts/typecheck.sh` only when the consuming file opts in via
-- `---@diagnostic enable: undefined-field, missing-fields` (pure models do).
-- Shapes mirror `scripts/store.lua:SCHEMA` and the hut/collect tables in `scripts/work.lua`.

---@class ItemCount
---@field [string] integer

---@class HaulDemand
---@field item string|nil
---@field items string[]|nil
---@field count integer
---@field need integer|nil

---@class HaulLoad
---@field item string
---@field count integer
---@field need integer|nil

---@class HutDef
---@field job string
---@field tool string|nil
---@field tools string[]|nil
---@field capacity integer
---@field keep string[]|nil
---@field inputs HaulDemand[]|nil

---@class HaulOffer
---@field priority integer
---@field building_priority integer|nil
---@field demands HaulDemand[]|nil
---@field available ItemCount|nil
---@field key integer|nil
---@field deficit integer|nil
---@field mat_rank integer|nil
---@field pos {x: number, y: number}|nil
---@field entity table|nil

---@class HaulCandidate
---@field kind string
---@field priority integer
---@field building_priority integer|nil
---@field is_direct boolean|nil
---@field source table|nil
---@field target table|nil
---@field load HaulLoad[]|nil
---@field demands HaulDemand[]|nil
---@field deficit integer|nil
---@field key integer|nil
---@field dist number|nil
---@field mat_rank integer|nil
---@field house table|nil
---@field machine table|nil
---@field crate table|nil
---@field hut table|nil
---@field bin table|nil

---@class RankCtx
---@field ratings table|nil
---@field demand ItemCount|nil

---@class HutSlot
---@field job string
---@field allowed integer
---@field workers integer
---@field id integer|nil
---@field priority integer|nil
---@field hut table|nil

---@class ChooseState
---@field counts table|nil
---@field slots table|nil
---@field capacity table|nil
---@field hut_count table|nil
---@field pop integer|nil
---@field priority table|nil
---@field targets table|nil
---@field haul boolean|nil
---@field backlog integer|nil
---@field cursor integer|nil
---@field food_ratio number|nil
---@field missing table|nil
---@field overflow_slots table|nil

---@class RecipeDef
---@field name string
---@field products table[]|nil
---@field ingredients table[]|nil

---@class RecipeGraphEntry
---@field ingredients table[]
---@field yield number

---@class LedgerHut
---@field name string|nil
---@field contents ItemCount|nil

---@class LedgerData
---@field stock ItemCount|nil
---@field huts LedgerHut[]|nil
---@field transit table[]|nil
---@field include_zero table|nil

---@class LedgerEntry
---@field item string
---@field stock integer
---@field huts integer
---@field transit integer
---@field total integer
---@field hut_details table

---@class GapFacts
---@field toolsmith boolean|nil
---@field unlocked boolean|nil
---@field missing ItemCount|nil

local M = {}
return M
