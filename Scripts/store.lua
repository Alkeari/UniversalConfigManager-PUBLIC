-- The journal of values this mod last wrote: one record per file+key, kept at the MOD ROOT
-- (never under Scripts\ - UE4SS's auto-reload watches that folder). Used at boot to detect a
-- config file changed outside this mod (hand edit, or a Workshop update reinstalling defaults):
-- v1 adopts the file as truth and logs the divergence; it never silently rewrites.
local FsUtil = require("fsutil")
local Config = require("config")
local log = require("logger")

local Store = {}

local FILE_NAME = "values.tsv"
-- The first value ever observed per key: the closest observable thing to the author's default,
-- used by Restore to Default. Written once per key, never updated.
local BASELINES_FILE_NAME = "baselines.tsv"

local function storePath(fileName)
    local scripts = FsUtil.scriptDirectory()
    local modRoot = FsUtil.parent(scripts) or scripts
    return modRoot .. "\\" .. fileName
end

local function journalPath()
    return storePath(FILE_NAME)
end

local function escapeField(text)
    return (tostring(text):gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\n", "\\n")
        :gsub("\r", "\\r"))
end

local function unescapeField(text)
    return (text:gsub("\\(.)", { t = "\t", n = "\n", r = "\r", ["\\"] = "\\" }))
end

local function recordId(modName, rel, key)
    return modName .. "|" .. rel .. "|" .. key
end
Store.recordId = recordId

-- Returns { [id] = { modName, rel, key, type, value } }; an unreadable or absent journal is an
-- empty one.
local function loadFrom(path)
    local records = {}
    local content = FsUtil.readFile(path)
    if content == nil then
        return records
    end
    for line in content:gmatch("[^\n]+") do
        line = line:gsub("\r$", "")
        local fields = {}
        for field in (line .. "\t"):gmatch("(.-)\t") do
            fields[#fields + 1] = unescapeField(field)
        end
        if #fields == 5 then
            local modName, rel, key, valueType, raw = table.unpack(fields)
            local value
            if valueType == "boolean" then
                value = raw == "true"
            elseif valueType == "number" then
                value = tonumber(raw)
            else
                value = raw
            end
            if value ~= nil then
                records[recordId(modName, rel, key)] = { modName = modName, rel = rel,
                    key = key, type = valueType, value = value }
            end
        end
    end
    return records
end

local function saveTo(path, records)
    local ids = {}
    for id in pairs(records) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local lines = {}
    for _, id in ipairs(ids) do
        local record = records[id]
        lines[#lines + 1] = table.concat({
            escapeField(record.modName), escapeField(record.rel), escapeField(record.key),
            tostring(record.type or "string"), escapeField(tostring(record.value)),
        }, "\t")
    end
    return FsUtil.writeFile(path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

function Store.load()
    return loadFrom(journalPath())
end

function Store.save(records)
    return saveTo(journalPath(), records)
end

function Store.loadBaselines()
    return loadFrom(storePath(BASELINES_FILE_NAME))
end

function Store.saveBaselines(records)
    return saveTo(storePath(BASELINES_FILE_NAME), records)
end

-- Records a baseline for every scanned entry that does not have one yet. Existing baselines
-- are never touched: the first observed value stays the "default" for the life of the install.
function Store.recordBaselines(model)
    local baselines = Store.loadBaselines()
    local added = false
    for _, mod in ipairs(model.mods) do
        for _, file in ipairs(mod.files) do
            for _, entry in ipairs(file.entries) do
                local id = recordId(mod.name, file.rel, entry.key)
                if baselines[id] == nil then
                    baselines[id] = { modName = mod.name, rel = file.rel, key = entry.key,
                        type = entry.type, value = entry.value }
                    added = true
                end
            end
        end
    end
    if added then
        Store.saveBaselines(baselines)
    end
    return baselines
end

local OPTIONS_FILE_NAME = "options.tsv"
-- `requestAllMods` is the master switch on the Request Support page; `requestExcluded` is
-- the comma-separated mod folders switched off while it is off. A preference, so it
-- survives a restart and is NOT cleared when a list is recompiled.
local OPTION_DEFAULTS = { advancedMode = false, requestAllMods = true,
    requestExcluded = "" }

-- This mod's own switches (Advanced Mode), one key<TAB>value line each. Absent or unreadable
-- means defaults; unknown keys are ignored so an older build never chokes on a newer file.
function Store.loadOptions()
    local options = {}
    for key, value in pairs(OPTION_DEFAULTS) do
        options[key] = value
    end
    local content = FsUtil.readFile(storePath(OPTIONS_FILE_NAME))
    if content == nil then
        return options
    end
    for line in content:gmatch("[^\n]+") do
        local key, raw = line:gsub("\r$", ""):match("^([^\t]+)\t(.*)$")
        if key ~= nil and OPTION_DEFAULTS[key] ~= nil then
            if type(OPTION_DEFAULTS[key]) == "boolean" then
                options[key] = raw == "true"
            else
                options[key] = raw
            end
        end
    end
    return options
end

function Store.saveOptions(options)
    local keys = {}
    for key in pairs(OPTION_DEFAULTS) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    local lines = {}
    for _, key in ipairs(keys) do
        local value = options[key]
        if value == nil then
            value = OPTION_DEFAULTS[key]
        end
        lines[#lines + 1] = key .. "\t" .. tostring(value)
    end
    return FsUtil.writeFile(storePath(OPTIONS_FILE_NAME), table.concat(lines, "\n") .. "\n")
end

-- ============================== the last compiled request ==============================

-- What the player last compiled, so they can come back for it. A player who compiles a list,
-- gets a link and then closes the screen before pasting it has otherwise lost both. Kept until
-- `fingerprint` stops matching the settings that are actually missing: past that the file
-- describes a state that no longer exists.
local REQUEST_RECORD_FILE = "request.tsv"
local RECORD_FIELDS = { "fingerprint", "path", "url", "count" }

function Store.loadRequestRecord()
    local content = FsUtil.readFile(storePath(REQUEST_RECORD_FILE))
    if content == nil then
        return nil
    end
    local record = {}
    for line in content:gmatch("[^\n]+") do
        local key, raw = line:gsub("\r$", ""):match("^([^\t]+)\t(.*)$")
        if key ~= nil then
            record[key] = raw
        end
    end
    if record.fingerprint == nil or record.fingerprint == "" then
        return nil
    end
    record.count = tonumber(record.count) or 0
    return record
end

function Store.saveRequestRecord(record)
    if type(record) ~= "table" or record.fingerprint == nil then
        return false
    end
    local lines = {}
    for _, key in ipairs(RECORD_FIELDS) do
        local value = record[key]
        if value ~= nil and value ~= "" then
            lines[#lines + 1] = key .. "\t" .. tostring(value)
        end
    end
    return FsUtil.writeFile(storePath(REQUEST_RECORD_FILE), table.concat(lines, "\n") .. "\n")
end

function Store.clearRequestRecord()
    return FsUtil.writeFile(storePath(REQUEST_RECORD_FILE), "")
end

-- ============================== preset files ==============================

function Store.presetsDirectory()
    local scripts = FsUtil.scriptDirectory()
    local modRoot = FsUtil.parent(scripts) or scripts
    return modRoot .. "\\presets"
end

function Store.isValidPresetName(name)
    if name == nil or name == "" then
        return false
    end
    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == nil or trimmed == "" or #trimmed > 40 then
        return false
    end
    -- Only a plain space counts as whitespace here: tab, newline and carriage return would
    -- corrupt the tab-separated preset record format, so they are rejected explicitly even
    -- though %s would otherwise accept them.
    if trimmed:find("[\t\n\r]") ~= nil then
        return false
    end
    return trimmed:match("^[%w%s%-_]+$") ~= nil
end

-- The permissive gate for reading an EXISTING preset file (Load, Delete, and what listPresets
-- itself returns): unlike Store.isValidPresetName, which governs what THIS mod will ever WRITE
-- (letters, digits, space, hyphen, underscore only), a preset dropped into the folder from
-- another install for sharing can carry any filename-safe name - "My Preset (v2)" included -
-- and must still be loadable and deletable. Refuses only what would escape the presets folder
-- or collide with a directory entry: empty after trim, over 80 characters, a path separator,
-- "." or "..", or a control character.
function Store.isSafePresetFileName(name)
    if name == nil then
        return false
    end
    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == nil or trimmed == "" or #trimmed > 80 then
        return false
    end
    if trimmed:find("[/\\]") ~= nil then
        return false
    end
    if trimmed == "." or trimmed == ".." then
        return false
    end
    for i = 1, #trimmed do
        if trimmed:byte(i) < 32 then
            return false
        end
    end
    return true
end

local function parseRecordLine(line)
    local fields = {}
    for field in (line .. "\t"):gmatch("(.-)\t") do
        fields[#fields + 1] = unescapeField(field)
    end
    if #fields >= 5 then
        local modName, rel, key, valueType, raw = fields[1], fields[2], fields[3], fields[4], fields[5]
        local value
        if valueType == "boolean" then
            value = raw == "true"
        elseif valueType == "number" then
            value = tonumber(raw)
        else
            value = raw
        end
        if value ~= nil then
            return { modName = modName, rel = rel, key = key, type = valueType, value = value }
        end
    end
    return nil
end

function Store.loadPreset(name)
    if not Store.isSafePresetFileName(name) then
        return nil, "invalid preset name"
    end
    local presetsDir = Store.presetsDirectory()
    local path = presetsDir .. "\\" .. name .. ".tsv"
    local sizeFile = io.open(path, "rb")
    if sizeFile == nil then
        return nil, "preset file not found"
    end
    local size = sizeFile:seek("end")
    sizeFile:close()
    if size ~= nil and size > Config.presetMaxBytes then
        return nil, "preset file too large"
    end
    local content = FsUtil.readFile(path)
    if content == nil then
        return nil, "preset file not found"
    end
    local records = {}
    for line in content:gmatch("[^\n]+") do
        line = line:gsub("\r$", "")
        if line:sub(1, 3) == "\239\187\191" then
            line = line:sub(4)
        end
        local record = parseRecordLine(line)
        if record ~= nil then
            records[#records + 1] = record
        end
    end
    if #records == 0 then
        return nil, "no valid records found"
    end
    return records
end

function Store.savePreset(name, records)
    if not Store.isValidPresetName(name) then
        return false, "invalid preset name"
    end
    local trimmedName = name:match("^%s*(.-)%s*$")
    local presetsDir = Store.presetsDirectory()
    if not FsUtil.directoryExists(presetsDir) then
        os.execute('mkdir "' .. presetsDir .. '"')
    end
    local lines = {}
    for _, record in ipairs(records) do
        lines[#lines + 1] = table.concat({
            escapeField(record.modName), escapeField(record.rel), escapeField(record.key),
            tostring(record.type or "string"), escapeField(tostring(record.value)),
        }, "\t")
    end
    local content = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
    local ok, err = FsUtil.writeFile(presetsDir .. "\\" .. trimmedName .. ".tsv", content)
    if ok then
        log.info("saved preset " .. trimmedName .. ": " .. #records .. " settings")
    end
    return ok, err
end

function Store.listPresets()
    local presetsDir = Store.presetsDirectory()
    local tsvFiles = FsUtil.listFilesRecursive(presetsDir)
    if tsvFiles == nil then
        tsvFiles = {}
    end
    local names = {}
    for _, file in ipairs(tsvFiles) do
        if file:sub(-4) == ".tsv" then
            local parentDir = file:match("^(.*)[/\\][^/\\]+$")
            if parentDir ~= nil then
                local normParent = parentDir:gsub("/", "\\"):lower()
                local normPresetsDir = presetsDir:gsub("/", "\\"):lower()
                if normParent == normPresetsDir then
                    local base = file:match("([^\\]+)%.tsv$")
                    -- Every listed name must be one Store.loadPreset and Store.deletePreset
                    -- will actually accept: the same gate, so "listed" and "usable" never
                    -- disagree.
                    if base ~= nil and Store.isSafePresetFileName(base) then
                        names[#names + 1] = base
                    end
                end
            end
        end
    end
    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)
    return names
end

-- ============================== description request files ==============================

function Store.requestsDirectory()
    local scripts = FsUtil.scriptDirectory()
    local modRoot = FsUtil.parent(scripts) or scripts
    return modRoot .. "\\requests"
end

-- Writes `text` as `fileName` in the requests folder and returns the full path. The folder is
-- created on first use only (os.execute flashes a console window, so never per launch).
function Store.saveRequest(fileName, text)
    if fileName == nil or fileName == "" or fileName:find("[/\\]") ~= nil then
        return nil, "invalid request file name"
    end
    local dir = Store.requestsDirectory()
    if not FsUtil.directoryExists(dir) then
        os.execute('mkdir "' .. dir .. '"')
    end
    local path = dir .. "\\" .. fileName
    local ok, err = FsUtil.writeFile(path, text)
    if not ok then
        return nil, err
    end
    log.info("wrote description request " .. path)
    return path
end

function Store.deletePreset(name)
    if not Store.isSafePresetFileName(name) then
        return false, "invalid preset name"
    end
    local presetsDir = Store.presetsDirectory()
    local path = presetsDir .. "\\" .. name .. ".tsv"
    local ok, err = os.remove(path)
    if ok then
        log.info("deleted preset " .. name)
        return true
    end
    return false, err or "could not delete file"
end

return Store
