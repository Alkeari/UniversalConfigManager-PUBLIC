-- Reads each mod-options framework's own broadcast schema for a consumer mod, over UE4SS's
-- cross-VM shared-variable channel. Read-only; never writes a shared variable. Every failure
-- (missing key, malformed JSON, unrecognized shape) returns nil plus a reason, never raises -
-- callers fall back to file-only heuristic classification for that mod.
local Config = require("config")

local Frameworks = {}

local VALID_TYPES = { boolean = true, number = true, enum = true, keybind = true,
    string = true }

-- Minimal JSON decoder, private to this module. parse_json.lua's public surface only splices
-- flat config-file values in place; a framework schema manifest is a nested document with
-- arrays that have to be walked, so it needs a real decode. Kept small: objects, arrays,
-- strings with backslash escapes, numbers, true/false/null.
local decodeValue

local function skipWs(s, pos)
    while pos <= #s and s:sub(pos, pos):match("[ \t\r\n]") do
        pos = pos + 1
    end
    return pos
end

local function decodeString(s, pos)
    -- pos is at the opening quote.
    local out = {}
    pos = pos + 1
    while pos <= #s do
        local c = s:sub(pos, pos)
        if c == "\"" then
            return table.concat(out), pos + 1
        elseif c == "\\" then
            local escaped = s:sub(pos + 1, pos + 1)
            if escaped == "n" then out[#out + 1] = "\n"
            elseif escaped == "t" then out[#out + 1] = "\t"
            elseif escaped == "r" then out[#out + 1] = "\r"
            elseif escaped == "\"" then out[#out + 1] = "\""
            elseif escaped == "\\" then out[#out + 1] = "\\"
            elseif escaped == "/" then out[#out + 1] = "/"
            elseif escaped == "u" then
                local hex = s:sub(pos + 2, pos + 5)
                local code = tonumber(hex, 16)
                if code == nil then
                    return nil, "bad \\u escape at byte " .. pos
                end
                out[#out + 1] = code < 128 and string.char(code) or utf8.char(code)
                pos = pos + 4
            else
                return nil, "bad escape at byte " .. pos
            end
            pos = pos + 2
        else
            out[#out + 1] = c
            pos = pos + 1
        end
    end
    return nil, "unterminated string"
end

decodeValue = function(s, pos)
    pos = skipWs(s, pos)
    local c = s:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skipWs(s, pos + 1)
        if s:sub(pos, pos) == "}" then
            return obj, pos + 1
        end
        while true do
            pos = skipWs(s, pos)
            if s:sub(pos, pos) ~= "\"" then
                return nil, nil, "expected object key at byte " .. pos
            end
            local key, afterKey = decodeString(s, pos)
            if key == nil then
                return nil, nil, afterKey
            end
            pos = skipWs(s, afterKey)
            if s:sub(pos, pos) ~= ":" then
                return nil, nil, "expected ':' at byte " .. pos
            end
            local value, afterValue, err = decodeValue(s, pos + 1)
            if err ~= nil then
                return nil, nil, err
            end
            obj[key] = value
            pos = skipWs(s, afterValue)
            local sep = s:sub(pos, pos)
            if sep == "," then
                pos = pos + 1
            elseif sep == "}" then
                return obj, pos + 1
            else
                return nil, nil, "expected ',' or '}' at byte " .. pos
            end
        end
    elseif c == "[" then
        local arr = {}
        pos = skipWs(s, pos + 1)
        if s:sub(pos, pos) == "]" then
            return arr, pos + 1
        end
        while true do
            local value, afterValue, err = decodeValue(s, pos)
            if err ~= nil then
                return nil, nil, err
            end
            arr[#arr + 1] = value
            pos = skipWs(s, afterValue)
            local sep = s:sub(pos, pos)
            if sep == "," then
                pos = pos + 1
            elseif sep == "]" then
                return arr, pos + 1
            else
                return nil, nil, "expected ',' or ']' at byte " .. pos
            end
        end
    elseif c == "\"" then
        local value, afterValue = decodeString(s, pos)
        if value == nil then
            return nil, nil, afterValue
        end
        return value, afterValue
    elseif s:find("^true", pos) then
        return true, pos + 4
    elseif s:find("^false", pos) then
        return false, pos + 5
    elseif s:find("^null", pos) then
        return nil, pos + 4
    else
        local from, to = s:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if from == nil then
            return nil, nil, "unexpected character at byte " .. pos
        end
        local number = tonumber(s:sub(from, to))
        if number == nil then
            return nil, nil, "bad number at byte " .. pos
        end
        return number, to + 1
    end
end

local function jsonDecode(raw)
    if type(raw) ~= "string" then
        return nil, "not a string"
    end
    local pos = skipWs(raw, 1)
    local value, afterValue, err = decodeValue(raw, pos)
    if err ~= nil then
        return nil, err
    end
    pos = skipWs(raw, afterValue)
    if pos <= #raw then
        return nil, "trailing content after the value"
    end
    return value
end

local function nativeModOptionsSchema(modId, getter)
    local key = "NativeModOptions.V1.PendingManifest." .. modId
    local raw = getter(key)
    if raw == nil then
        return nil, "no shared variable at " .. key
    end
    local decoded, err = jsonDecode(raw)
    if decoded == nil then
        return nil, "malformed schema JSON: " .. tostring(err)
    end
    local options = {}
    for _, option in ipairs(decoded.options or {}) do
        if option.key ~= nil and VALID_TYPES[option.type] then
            options[option.key] = { type = option.type, label = option.label,
                min = option.min, max = option.max, choices = option.choices }
        end
    end
    return { title = decoded.title, options = options }
end

-- Maps a normalize_schema option "type" (Config.frameworks.palModOptions.optionShape) onto the
-- five normalized types this module produces. "section" is a label-only divider row with no
-- value and is dropped, never surfaced as an option.
local PMO_TYPE_MAP = { boolean = "boolean", integer = "number", number = "number",
    text = "string", enum = "enum", keybind = "keybind" }

local function palModOptionsSchema(modId, getter)
    local layout = Config.frameworks.palModOptions
    if layout == nil then
        return nil, "PalModOptions schema layout not recorded"
    end
    local prefix = layout.prefix
    local keys = layout.sharedKeys
    local session = getter(prefix .. keys.session)
    if session == nil or session == "" then
        return nil, "no PalModOptions session (framework not booted or no getter response)"
    end
    local registry = getter(prefix .. keys.registryPrefix .. session)
    if registry == nil then
        return nil, "no PalModOptions registry for session " .. tostring(session)
    end
    local registered = false
    for id in registry:gmatch("[^\n]+") do
        if id == modId then
            registered = true
            break
        end
    end
    if not registered then
        return nil, modId .. " is not registered in PalModOptions session " .. tostring(session)
    end
    local manifestKey = prefix .. keys.manifestPrefix .. session .. "." .. modId
    local raw = getter(manifestKey)
    if raw == nil then
        return nil, "no shared variable at " .. manifestKey
    end
    local decoded, err = jsonDecode(raw)
    if decoded == nil then
        return nil, "malformed schema JSON: " .. tostring(err)
    end
    local options = {}
    for _, option in ipairs(decoded.options or {}) do
        local normalizedType = PMO_TYPE_MAP[option.type]
        if option.key ~= nil and normalizedType ~= nil then
            options[option.key] = { type = normalizedType, label = option.label,
                min = option.minimum, max = option.maximum, choices = option.choices }
        end
    end
    return { title = decoded.title, options = options }
end

local READERS = { nativemodoptions = nativeModOptionsSchema,
    palmodoptions = palModOptionsSchema }

-- Shared with Frameworks.registeredConsumers below: reads a UE4SS shared variable, pcall-guarded
-- so an absent ModRef (offline tests, or a session before the framework has booted) degrades to
-- nil rather than raising.
local function defaultGetter(key)
    local ok, value = pcall(function() return ModRef:GetSharedVariable(key) end)
    return ok and value or nil
end

function Frameworks.schemaFor(frameworkName, modId, getter)
    getter = getter or defaultGetter
    local reader = READERS[frameworkName]
    if reader == nil then
        return nil, "unknown framework: " .. tostring(frameworkName)
    end
    local ok, schema, err = pcall(reader, modId, getter)
    if not ok then
        return nil, "schema read raised: " .. tostring(schema)
    end
    return schema, err
end

-- Reads a framework's live consumer registry: the ids of mods currently registered with it this
-- session, over the same cross-VM shared-variable channel schemaFor reads schemas from. Unlike a
-- saved-value FILE (which a consumer only gets after the player changes a setting through the
-- framework's own UI - PalModOptions writes nothing to disk until then), the registry is written
-- the moment a consumer completes the registration handshake, so it is the only signal that can
-- ever be "complete" on an install where nobody has touched a framework's own settings panel yet.
--
-- PalModOptions' registry value (Config.frameworks.palModOptions.sharedKeys.registryPrefix,
-- verified against that config's own comment and against palModOptionsSchema above, which already
-- reads the same two keys) is a newline-joined list of ids, not JSON - schemaFor's JSON decoder
-- applies to the per-consumer MANIFEST/PendingManifest values, never to the registry list itself.
--
-- Returns a list of ids, or nil plus a reason (no session yet, no registry for that session, or
-- an empty registry) - never raises.
local function palModOptionsRegisteredConsumers(getter)
    local layout = Config.frameworks.palModOptions
    if layout == nil then
        return nil, "PalModOptions schema layout not recorded"
    end
    local prefix = layout.prefix
    local keys = layout.sharedKeys
    local session = getter(prefix .. keys.session)
    if session == nil or session == "" then
        return nil, "no PalModOptions session (framework not booted or no getter response)"
    end
    local raw = getter(prefix .. keys.registryPrefix .. session)
    if raw == nil or raw == "" then
        return nil, "no PalModOptions registry for session " .. tostring(session)
    end
    local ids = {}
    for id in raw:gmatch("[^\n]+") do
        ids[#ids + 1] = id
    end
    if #ids == 0 then
        return nil, "PalModOptions registry for session " .. tostring(session) .. " is empty"
    end
    return ids
end

local REGISTRY_READERS = { palmodoptions = palModOptionsRegisteredConsumers }

function Frameworks.registeredConsumers(frameworkName, getter)
    getter = getter or defaultGetter
    local reader = REGISTRY_READERS[frameworkName]
    if reader == nil then
        return nil, "unknown or unsupported framework registry: " .. tostring(frameworkName)
    end
    local ok, ids, err = pcall(reader, getter)
    if not ok then
        return nil, "registry read raised: " .. tostring(ids)
    end
    return ids, err
end

return Frameworks
