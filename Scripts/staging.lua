-- The edit registry: originals from the scan, staged pending values from the open panel, and the
-- commit path that writes files. UI-independent so the panel can be torn down while a confirmed
-- Apply still commits (the prompt is answered while the screen is already closing).
local Scanner = require("scanner")
local Store = require("store")
local log = require("logger")

local Staging = {}

local entries = {}   -- [id] = { id, modName, file, entry }
local order = {}     -- ids in display order
local pending = {}   -- [id] = staged value

-- Fired once per stage call whose value diverges from the original; the screen owner uses it to
-- raise vanilla's "something changed" flag.
Staging.onChanged = nil

function Staging.idFor(modName, rel, key)
    return Store.recordId(modName, rel, key)
end

-- Seeds from a scan model. Pending edits are dropped: a new begin means a fresh panel open.
function Staging.begin(model)
    entries = {}
    order = {}
    pending = {}
    for _, mod in ipairs(model.mods) do
        for _, file in ipairs(mod.files) do
            for _, entry in ipairs(file.entries) do
                local id = Staging.idFor(mod.name, file.rel, entry.key)
                entries[id] = { id = id, modName = mod.name, file = file, entry = entry }
                order[#order + 1] = id
            end
        end
    end
end

function Staging.get(id)
    return entries[id]
end

-- The value a row should show: staged if present, else the file's.
function Staging.valueOf(id)
    if pending[id] ~= nil then
        return pending[id]
    end
    local record = entries[id]
    return record ~= nil and record.entry.value or nil
end

function Staging.stage(id, value)
    local record = entries[id]
    if record == nil then
        return
    end
    if record.entry.type == "number" then
        value = tonumber(value)
        if value == nil then
            return
        end
        -- A slider hands back floats; a key that was an integer stays one.
        if math.type(record.entry.value) == "integer"
            or record.entry.value == math.floor(record.entry.value) then
            value = math.floor(value + 0.5)
        end
    end
    pending[id] = value
    if value ~= record.entry.value and Staging.onChanged ~= nil then
        pcall(Staging.onChanged, id, value)
    end
end

-- Pure: returns { [id] = { type, value } } for every template entry whose type matches the live
-- entry's type. Used by Restore to Default when a mod has a template sibling.
function Staging.templateValues(model)
    local result = {}
    for _, mod in ipairs(model.mods) do
        for _, file in ipairs(mod.files) do
            if file.templateEntries ~= nil then
                for _, templateEntry in ipairs(file.templateEntries) do
                    local id = Staging.idFor(mod.name, file.rel, templateEntry.key)
                    local liveRecord = entries[id]
                    if liveRecord ~= nil and liveRecord.entry.type == templateEntry.type then
                        result[id] = { type = templateEntry.type, value = templateEntry.value }
                    end
                end
            end
            -- A format that states the author's default alongside the current value needs no
            -- template sibling and no baseline guess: DekModConfigMenu writes `init` next to
            -- `live` for every setting, which is the real default rather than the closest
            -- observable thing to one. A template sibling still wins, being the same claim
            -- made by a whole file.
            for _, entry in ipairs(file.entries) do
                local id = Staging.idFor(mod.name, file.rel, entry.key)
                local liveRecord = entries[id]
                if entry.default ~= nil and result[id] == nil and liveRecord ~= nil
                    and type(entry.default) == type(liveRecord.entry.value) then
                    result[id] = { type = entry.type, value = entry.default }
                end
            end
        end
    end
    return result
end

-- Restore to Default: stages each entry's template value (from a template sibling, if present and type-matching),
-- else the BASELINE (the value first observed for it, the closest observable thing to the author's default),
-- falling back to the file's open-time value where neither exists. Staged only - Apply still commits.
function Staging.resetAll(baselines, templateValues)
    baselines = baselines or {}
    templateValues = templateValues or {}
    for id, record in pairs(entries) do
        local target = record.entry.value
        local template = templateValues[id]
        if template ~= nil then
            target = template.value
        else
            local baseline = baselines[id]
            if baseline ~= nil and baseline.type == record.entry.type then
                target = baseline.value
            end
        end
        Staging.stage(id, target)
    end
end

-- `modName` nil means every mod; naming one restricts the operation to that mod's entries. The
-- scoped forms exist because the panel offers Save and Revert per mod as well as for the whole
-- screen, and a per-mod Revert must not touch another mod's pending edits.
local function inScope(record, modName)
    return record ~= nil and (modName == nil or record.modName == modName)
end

function Staging.discardAll(modName)
    if modName == nil then
        pending = {}
        return
    end
    for id in pairs(pending) do
        if inScope(entries[id], modName) then
            pending[id] = nil
        end
    end
end

-- True when any staged value diverges from its file, within `modName` when one is given.
function Staging.hasChanges(modName)
    for id, value in pairs(pending) do
        local record = entries[id]
        if inScope(record, modName) and value ~= record.entry.value then
            return true
        end
    end
    return false
end

-- Every mod with at least one diverging staged value, sorted, so a caller can ask what the
-- pending set actually covers without reaching into the registry.
function Staging.pendingModNames()
    local seen, names = {}, {}
    for id, value in pairs(pending) do
        local record = entries[id]
        if record ~= nil and value ~= record.entry.value and not seen[record.modName] then
            seen[record.modName] = true
            names[#names + 1] = record.modName
        end
    end
    table.sort(names)
    return names
end

-- The ids whose staged value diverges, within `modName` when one is given, sorted so a caller
-- reaffirming rows does so in a predictable order.
function Staging.pendingIds(modName)
    local ids = {}
    for id, value in pairs(pending) do
        local record = entries[id]
        if inScope(record, modName) and value ~= record.entry.value then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

-- Commits every diverging staged value, or only `modName`'s when one is given: groups by file,
-- splices, verifies, writes, journals. Returns the number of files written and the number of
-- failures (each already logged).
function Staging.applyAll(modName)
    local byFile = {}   -- [file path] = { file, edits = { key -> value }, ids = {} }
    for id, value in pairs(pending) do
        local record = entries[id]
        if inScope(record, modName) and value ~= record.entry.value then
            local group = byFile[record.file.path]
            if group == nil then
                group = { file = record.file, modName = record.modName,
                    edits = {}, records = {} }
                byFile[record.file.path] = group
            end
            group.edits[record.entry.key] = value
            group.records[#group.records + 1] = record
            pending[id] = nil
        end
    end
    -- A value nudged and put back is staged but not diverging; clearing it here keeps a mod from
    -- looking dirty after its own Save, without disturbing another mod's edits.
    for id, value in pairs(pending) do
        local record = entries[id]
        if inScope(record, modName) and value == record.entry.value then
            pending[id] = nil
        end
    end

    local written, failed = 0, 0
    local journal = nil
    for path, group in pairs(byFile) do
        local ok, err = Scanner.writeEdits(group.file, group.edits)
        if ok then
            written = written + 1
            journal = journal or Store.load()
            for _, record in ipairs(group.records) do
                local newValue = group.edits[record.entry.key]
                record.entry.value = newValue
                journal[record.id] = { modName = record.modName, rel = record.file.rel,
                    key = record.entry.key, type = record.entry.type, value = newValue }
            end
            local keys = {}
            for key in pairs(group.edits) do
                keys[#keys + 1] = key
            end
            table.sort(keys)
            log.info("wrote " .. group.modName .. "\\" .. group.file.rel .. " ("
                .. table.concat(keys, ", ") .. ") - the change applies when that mod next loads")
        else
            failed = failed + 1
            log.error("could not write " .. group.modName .. "\\" .. group.file.rel .. ": "
                .. tostring(err))
        end
    end
    if journal ~= nil then
        Store.save(journal)
    end
    return written, failed
end

-- Boot-time reapply: the journal is AUTHORITATIVE for every value the user set through this
-- mod, superseding the earlier adopt-the-file behavior. For every journaled value the file no
-- longer holds - a Workshop update reinstalling defaults, or a hand edit - the journaled value
-- is written back, with one log line naming both values. Keys that vanished from the file (or
-- changed type) are dropped from the journal: a key the mod no longer reads must not be
-- resurrected. Keys newly added by a mod update are untouched: the scan is
-- file-driven, so they appear as fresh rows with the file's own value.
--
-- The escape hatch from a reapply the user no longer wants is setting the value in the panel
-- (which re-journals it) - or deleting values.tsv, which forgets everything.
function Staging.reapplyJournal(model)
    local journal = Store.load()
    if next(journal) == nil then
        return
    end
    local entriesById = {}
    local filesById = {}
    for _, mod in ipairs(model.mods) do
        for _, file in ipairs(mod.files) do
            for _, entry in ipairs(file.entries) do
                local id = Staging.idFor(mod.name, file.rel, entry.key)
                entriesById[id] = entry
                filesById[id] = file
            end
        end
    end
    local dirty = false
    local byFile = {}   -- [file path] = { file, edits, ids }
    for id, record in pairs(journal) do
        local entry = entriesById[id]
        if entry == nil then
            log.warn("journaled setting no longer exists: " .. id .. " (dropping the record)")
            journal[id] = nil
            dirty = true
        elseif entry.type ~= record.type then
            log.warn("journaled setting changed type: " .. id .. " (" .. record.type .. " -> "
                .. entry.type .. "; dropping the record, keeping the file's value)")
            journal[id] = nil
            dirty = true
        elseif entry.value ~= record.value then
            local file = filesById[id]
            local group = byFile[file.path]
            if group == nil then
                group = { file = file, edits = {}, records = {} }
                byFile[file.path] = group
            end
            group.edits[record.key] = record.value
            group.records[#group.records + 1] = { id = id, record = record, entry = entry }
        end
    end
    for _, group in pairs(byFile) do
        local ok, err = Scanner.writeEdits(group.file, group.edits)
        if ok then
            for _, item in ipairs(group.records) do
                log.info("reapplied " .. item.record.modName .. "\\" .. item.record.rel .. " '"
                    .. item.record.key .. "' = " .. tostring(item.record.value)
                    .. " (the file had been changed to " .. tostring(item.entry.value)
                    .. " outside Universal Config Manager)")
                item.entry.value = item.record.value
            end
        else
            log.error("could not reapply values to " .. group.file.path .. ": "
                .. tostring(err) .. " (will retry next boot)")
        end
    end
    if dirty then
        Store.save(journal)
    end
end

return Staging
