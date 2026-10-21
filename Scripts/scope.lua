-- Decides, per file in a mod folder, whether it is something the mod's user is meant to edit.
-- Classes, decided by evidence in this order:
--   template  - a *.default.* / *.example.* / *.template.* / *.sample.* file, or one whose name
--               minus that token matches a sibling. Never edited; its values are defaults.
--   user      - any non-Lua parseable format with at least one entry. Filename is not evidence.
--   puredata  - a .lua file that is comments plus literal data only (ParseLua.isPureData).
--   advanced  - any other .lua with at least one literal entry: code, shown in Advanced Mode
--               only, minus keys the mod's real config already exposes.
--   ignored   - everything else.
local Config = require("config")
local ParseLua = require("parse_lua")

local Scope = {}

-- Returns the sibling file name a template belongs to, or nil when `fileName` is not a
-- template of any sibling in `fileNames` (and carries no template token at all).
function Scope.templateSibling(fileNames, fileName)
    local lowered = fileName:lower()
    for _, token in ipairs(Config.templateTokens) do
        local at = lowered:find(token, 1, true)
        if at ~= nil then
            local candidate = fileName:sub(1, at - 1) .. fileName:sub(at + #token - 1)
            for _, sibling in ipairs(fileNames) do
                if sibling:lower() == candidate:lower() then
                    return sibling
                end
            end
            return candidate
        end
    end
    return nil
end

local function hasTemplateToken(fileName)
    local lowered = fileName:lower()
    for _, token in ipairs(Config.templateTokens) do
        if lowered:find(token, 1, true) then
            return true
        end
    end
    return false
end

function Scope.classify(fileName, rel, format, content, entryCount, siblingNames)
    if format == nil then
        return "ignored"
    end
    if Config.excludedFileNames[fileName:lower()] then
        return "ignored"
    end
    if hasTemplateToken(fileName) then
        return "template"
    end
    if entryCount ~= nil and entryCount > Config.maxSettingsPerFile then
        return "ignored"
    end
    if entryCount == nil or entryCount < 1 then
        return "ignored"
    end
    if format ~= "lua" then
        if Scope.isRecordLibrary(format, content) then
            return "ignored"
        end
        return "user"
    end
    local pure = ParseLua.isPureData(content or "")
    if pure then
        return "puredata"
    end
    return "advanced"
end

-- A file named by a language tag (en, ja, zh-Hans, es-MX, pt_BR) whose every entry is a string
-- is a translation table, not settings, whatever folder it sits in: the reference install's
-- sweep (2026-09-02) surfaced 17-language sets from three mods (PalpediaEnhancer's
-- Assets\lang\*.ini, BaseRenamingUtility's Scripts\Localization\*.lua, InstantHaul's
-- Scripts\lang\*.lua) as 1,500 "settings". Both halves are required: a settings file called
-- de.ini would carry at least one number or boolean, and a string table under any other name
-- keeps qualifying by content like every other file.
local function isLanguageTag(stem)
    local lowered = stem:lower()
    return lowered:match("^%a%a$") ~= nil or lowered:match("^%a%a[-_]%a%a%a?%a?$") ~= nil
end

-- A key=value file that assigns the SAME key more than once holds several records, not one set
-- of settings: a preset library, a profile list, a log of saved states. Editing "the" value of
-- a key that appears five times is meaningless, and every one of its keys duplicates the mod's
-- real settings file (found live 2026-09-03: MapCollectablesNative's `Presets.ini` repeats all
-- 100 `Toggle.*` keys once per saved preset, doubling every row of its `Settings.ini`). The
-- section prefix is part of the key, so `[A] x=1` and `[B] x=1` are two keys and stay settings.
-- Only key=value formats: a Lua or JSON table cannot repeat a key at one level, and nesting
-- makes a repeat legitimate.
function Scope.isRecordLibrary(format, content)
    if format ~= "ini" or content == nil then
        return false
    end
    local seen = {}
    local section = ""
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^[#;]") then
            local heading = trimmed:match("^%[(.-)%]$")
            if heading ~= nil then
                section = heading
            else
                local key = trimmed:match("^([^=]-)%s*=")
                if key ~= nil and key ~= "" then
                    local fullKey = (section == "" and key or (section .. "." .. key)):lower()
                    if seen[fullKey] then
                        return true
                    end
                    seen[fullKey] = true
                end
            end
        end
    end
    return false
end

-- A module whose every value is a type's own default (false, 0, "") and whose keys carry no
-- comments holds a program's starting state, not settings a player chose: there is nothing to
-- restore and nothing to explain (audit, 2026-09-03: a `runtime_state.lua` of eight such keys
-- was listed as eight settings). A real config has at least one deliberate value or one comment.
function Scope.isRuntimeState(content, entries)
    if entries == nil or #entries < 2 then
        return false
    end
    for _, entry in ipairs(entries) do
        local value = entry.value
        local isDefault = value == false or value == 0 or value == ""
        if not isDefault then
            return false
        end
    end
    -- A comment anywhere in the file is an author explaining a setting; state files carry none.
    if content ~= nil and content:find("%-%-") ~= nil then
        return false
    end
    return true
end

-- A parseable file whose settings are a rounding error in its own size is a data store that
-- happens to contain a literal or two: a save file, a cache, a captured table. Real configs on
-- the reference install run from 38 to 7,432 bytes per setting (audit, 2026-09-03: a 113 KB
-- save file yielded one entry). Only applies above `minBytes`, so a small file is never judged.
function Scope.isSparseData(content, entryCount, minBytes, bytesPerEntry)
    if content == nil or entryCount == nil or entryCount < 1 then
        return false
    end
    minBytes = minBytes or 8192
    bytesPerEntry = bytesPerEntry or 16384
    return #content >= minBytes and (#content / entryCount) > bytesPerEntry
end

function Scope.isTranslationTable(fileName, entries)
    if entries == nil or #entries == 0 then
        return false
    end
    local stem = fileName:match("^(.*)%.[^%.]+$") or fileName
    if not isLanguageTag(stem) then
        return false
    end
    for _, entry in ipairs(entries) do
        if entry.type ~= "string" then
            return false
        end
    end
    return true
end

-- A file whose every entry is a string naming the mod itself (name, version, author, package
-- name, description, homepage) is the mod's identity record, not settings: SmartPalFeeding's
-- Scripts\Core\Metadata.lua on the reference install (2026-09-02). One non-identity key or one
-- non-string value and the file qualifies like any other.
local METADATA_KEYS = { name = true, mod_name = true, modname = true, package_name = true,
    packagename = true, version = true, author = true, authors = true, description = true,
    id = true, mod_id = true, modid = true, url = true, homepage = true, license = true,
    credits = true, title = true, tested_game_build_id = true, tested_game_release = true,
    game_version = true, gameversion = true, build = true }

function Scope.isMetadataTable(entries)
    if entries == nil or #entries == 0 then
        return false
    end
    for _, entry in ipairs(entries) do
        if entry.type ~= "string" or not METADATA_KEYS[Scope.lastSegment(entry.key):lower()] then
            return false
        end
    end
    return true
end

function Scope.lastSegment(key)
    return key:match("([^%.]+)$") or key
end

-- Two dedupe passes, in precedence order (found live, AntiPhatPalResizing: `settings.ini`
-- (user) and `config.lua` (puredata) exposed the same 14 setting names, 2026-09-04):
--   1. A `user` file (ini/json - a genuine settings file) strips any `puredata` file's entry of
--      the same setting name (last dotted segment, lowercased): a `.lua` table of comments plus
--      literal defaults duplicating what an ini already exposes editably is noise, not a second
--      setting.
--   2. Whatever `user`/`puredata` still expose after pass 1 strips `advanced` (real-code `.lua`)
--      entries, as before.
-- Two files at the SAME tier never dedupe against each other: a mod's `Presets.ini` sharing key
-- names with its own `Settings.ini` is a preset library, not a duplicate of the active settings
-- (found live, MapCollectablesNative). Returns the total entries removed across both passes.
function Scope.dedupeExposed(files)
    local removed = 0

    local userKeys = {}
    for _, file in ipairs(files) do
        if file.class == "user" then
            for _, entry in ipairs(file.entries) do
                userKeys[Scope.lastSegment(entry.key):lower()] = true
            end
        end
    end
    for _, file in ipairs(files) do
        if file.class == "puredata" then
            local kept = {}
            for _, entry in ipairs(file.entries) do
                if userKeys[Scope.lastSegment(entry.key):lower()] then
                    removed = removed + 1
                else
                    kept[#kept + 1] = entry
                end
            end
            file.entries = kept
        end
    end

    local exposed = {}
    for _, file in ipairs(files) do
        if file.class == "user" or file.class == "puredata" then
            for _, entry in ipairs(file.entries) do
                exposed[Scope.lastSegment(entry.key):lower()] = true
            end
        end
    end
    for _, file in ipairs(files) do
        if file.class == "advanced" then
            local kept = {}
            for _, entry in ipairs(file.entries) do
                if exposed[Scope.lastSegment(entry.key):lower()] then
                    removed = removed + 1
                else
                    kept[#kept + 1] = entry
                end
            end
            file.entries = kept
        end
    end
    return removed
end

-- A lookup table of unique labels, not settings: PerfProbe ships accessory_names.lua mapping each
-- accessory id to its English display name, and every one of those 141 rows reached the request
-- file asking a player to list "the accepted values" of a free-form label (first player request,
-- 2026-09-06). The shape is specific enough to name: many rows, every value a string, the values
-- almost all distinct, and the keys sharing one leading token, which is what a generated id-to-name
-- table looks like and what a hand-written settings file does not.
Scope.NAME_TABLE_MIN_ENTRIES = 20

function Scope.isNameTable(entries)
    if entries == nil or #entries < Scope.NAME_TABLE_MIN_ENTRIES then
        return false
    end
    local seen, distinct, prefixes = {}, 0, {}
    for _, entry in ipairs(entries) do
        if entry.type ~= "string" then
            return false
        end
        local value = tostring(entry.value or "")
        if not seen[value] then
            seen[value] = true
            distinct = distinct + 1
        end
        local segment = Scope.lastSegment(entry.key)
        local token = segment:match("^([%a]+)[_%.]") or segment:match("^(%u%l+)%u")
        prefixes[token or ""] = (prefixes[token or ""] or 0) + 1
    end
    if distinct < math.floor(#entries * 0.8) then
        return false
    end
    local best = 0
    for token, count in pairs(prefixes) do
        if token ~= "" and count > best then
            best = count
        end
    end
    return best >= math.floor(#entries * 0.8)
end


return Scope
