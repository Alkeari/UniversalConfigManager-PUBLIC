-- Description requests: the settings whose tooltip is still the community prompt, gathered
-- per mod (or for the whole install) and rendered as a plain text file the player can paste
-- into a Workshop comment or Nexus post. The file stays English whatever the game language:
-- its reader is the catalog's author, and the catalog grows from these requests through
-- tools/catalog. Pure: no widget, no file IO (Store writes the file).
local Entries = require("entries")
local Present = require("present")

local Requests = {}

-- Mods with at least one setting that is undescribed OR whose Possible Entries strip reached
-- the floor (a free-form text box this mod could find no accepted values for), each with that
-- setting list. `onlyMod` narrows the sweep to one mod table (by identity); nil covers the
-- whole model. The entries ladder is resolved here for mods whose page was never opened.
function Requests.collect(model, onlyMod)
    local mods = {}
    for _, mod in ipairs(model and model.mods or {}) do
        if onlyMod == nil or mod == onlyMod then
            local settings = {}
            for _, file in ipairs(mod.files or {}) do
                for _, entry in ipairs(file.entries or {}) do
                    local resolved = Entries.resolve(entry, file, mod, Present.overrides.entries)
                    local needsEntries = resolved.source == "floor"
                        and Entries.couldHaveClosedSet(entry, file)
                    if (entry.undescribed or needsEntries) and not entry.hidden
                        and not entry.perPlayerData then
                        settings[#settings + 1] = { rel = file.rel, key = entry.key,
                            label = entry.label, type = tostring(entry.type or "string"),
                            undescribed = entry.undescribed and true or false,
                            needsEntries = needsEntries }
                    end
                end
            end
            if #settings > 0 then
                mods[#mods + 1] = { name = mod.name, displayName = mod.displayName or mod.name,
                    workshopId = mod.workshopId, settings = settings }
            end
        end
    end
    return mods
end

-- The mods a compiled list actually covers. The default is every mod with something
-- missing; turning the master switch off lets a player exclude individual mods, which is
-- the only way to send one mod's gaps without sending the whole install. `excluded` is a set
-- of mod folder names; nil or empty excludes nothing.
function Requests.filter(mods, includeAll, excluded)
    if includeAll ~= false then
        return mods
    end
    local kept = {}
    for _, mod in ipairs(mods or {}) do
        if not (excluded or {})[mod.name] then
            kept[#kept + 1] = mod
        end
    end
    return kept
end

-- A stable id for exactly which settings are missing something. A compiled list stays offered
-- to the player until this changes; when it does, the old file and its link describe a state
-- that no longer exists and are dropped. Order-independent and cheap: the panel asks for it on
-- every open.
function Requests.fingerprint(mods)
    local keys = {}
    for _, mod in ipairs(mods or {}) do
        for _, setting in ipairs(mod.settings or {}) do
            keys[#keys + 1] = mod.name .. "|" .. setting.rel .. "|" .. setting.key
                .. "|" .. (setting.undescribed and "d" or "") .. (setting.needsEntries and "e" or "")
        end
    end
    table.sort(keys)
    local joined = table.concat(keys, "\n")
    -- FNV-1a over the joined list: a content id, not a security digest.
    local hash = 2166136261
    for index = 1, #joined do
        hash = hash ~ joined:byte(index)
        hash = (hash * 16777619) & 0xFFFFFFFF
    end
    return string.format("%d-%08x", #keys, hash)
end

function Requests.count(mods)
    local total = 0
    for _, mod in ipairs(mods or {}) do
        total = total + #mod.settings
    end
    return total
end

-- Values are deliberately left out: a string setting can hold a name or a path, and the
-- request only needs to say which keys lack a description.
function Requests.render(mods, version)
    local lines = {
        "Universal Config Manager " .. tostring(version or "") .. " - description request",
        "Settings below are missing a description, the values they accept, or both. Each line "
            .. "says which.",
        "Reply with one plain sentence per key, and a comma-separated list where values are asked "
            .. "for.",
        "",
    }
    for _, mod in ipairs(mods or {}) do
        local id = Present.sourceLabel(mod)
        lines[#lines + 1] = "== " .. mod.displayName .. " (" .. mod.name .. ", " .. id .. ")"
        for _, setting in ipairs(mod.settings) do
            local label = setting.label ~= nil and setting.label ~= setting.key
                and ("  [" .. setting.label .. "]") or ""
            -- Which of the two is actually missing. Every line used to read as a missing
            -- description, so eleven settings that had one and only wanted their accepted values
            -- listed asked the reader for the wrong thing (seen in a real request file, 2026-09-05).
            local wanted = "needs its accepted values"
            if setting.undescribed and setting.needsEntries then
                wanted = "needs a description AND its accepted values"
            elseif setting.undescribed then
                wanted = "needs a description"
            end
            lines[#lines + 1] = setting.rel .. " : " .. setting.key .. "  (" .. setting.type .. ")"
                .. label .. "  - " .. wanted
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

-- The list's file name. It says whether the list covers everything or a chosen subset: a file
-- called request-all-mods.txt holding one mod's settings lies about its contents (review,
-- 2026-09-06).
function Requests.fileName(everyMod)
    if everyMod == false then
        return "request-selected-mods.txt"
    end
    return "request-all-mods.txt"
end

return Requests
