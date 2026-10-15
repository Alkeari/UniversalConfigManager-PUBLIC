-- Presets: every setting's committed value captured under a name, and a load plan that stages
-- only what this install still has (a preset from another install skips the rest silently).
local Staging = require("staging")

local Presets = {}

function Presets.capture(model)
    local records = {}
    for _, mod in ipairs(model.mods or {}) do
        for _, file in ipairs(mod.files or {}) do
            for _, entry in ipairs(file.entries or {}) do
                records[#records + 1] = { modName = mod.name, rel = file.rel, key = entry.key,
                    type = tostring(entry.type or "string"), value = entry.value }
            end
        end
    end
    return records
end

local function entryIndex(model)
    local index = {}
    for _, mod in ipairs(model.mods or {}) do
        for _, file in ipairs(mod.files or {}) do
            for _, entry in ipairs(file.entries or {}) do
                if entry.key ~= nil then
                    index[Staging.idFor(mod.name, file.rel, entry.key)] = entry
                end
            end
        end
    end
    return index
end

function Presets.plan(records, model)
    local index = entryIndex(model)
    local plan = { stage = {}, skipped = 0 }
    for _, record in ipairs(records or {}) do
        if record.modName == nil or record.rel == nil or record.key == nil or record.type == nil then
            plan.skipped = plan.skipped + 1
        else
            local id = Staging.idFor(record.modName, record.rel, record.key)
            local entry = index[id]
            if entry ~= nil and entry.type == record.type then
                plan.stage[#plan.stage + 1] = { id = id, value = record.value }
            else
                plan.skipped = plan.skipped + 1
            end
        end
    end
    return plan
end

function Presets.apply(plan)
    local staged = 0
    for _, item in ipairs(plan.stage) do
        Staging.stage(item.id, item.value)
        staged = staged + 1
    end
    return staged
end

return Presets
