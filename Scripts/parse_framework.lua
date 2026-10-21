-- Codec and splice-in-place parser for the JSON-value INI both mod-options frameworks persist:
-- one `key=json_value` pair per line, no sections, with a fixed number of leading `#` comment
-- lines (0 for NativeModOptions, 2 for PalModOptions) that must survive a rewrite byte-for-byte.
local ParseFramework = {}

function ParseFramework.decodeValue(raw)
    if raw == "true" then
        return true, "boolean"
    end
    if raw == "false" then
        return false, "boolean"
    end
    if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' and #raw >= 2 then
        local inner = raw:sub(2, -2)
        inner = inner:gsub('\\(.)', function(escaped)
            if escaped == "n" then return "\n" end
            if escaped == "t" then return "\t" end
            return escaped
        end)
        return inner, "string"
    end
    local number = tonumber(raw)
    if number ~= nil then
        return number, "number"
    end
    return raw, "string"
end

function ParseFramework.encodeValue(value, valueType)
    if valueType == "boolean" then
        return value and "true" or "false"
    end
    if valueType == "number" then
        if math.type(value) == "integer" or value == math.floor(value) then
            return string.format("%d", value)
        end
        local short = string.format("%.14g", value)
        return tonumber(short) == value and short or string.format("%.17g", value)
    end
    local escaped = tostring(value):gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\t", "\\t")
    return '"' .. escaped .. '"'
end

-- Returns an ordered entry list ({ key, type, value, from, to }), or nil and a reason.
function ParseFramework.parse(content, headerLines)
    local entries = {}
    local pos = 1
    local lineIndex = 0
    while pos <= #content do
        local lineEnd = content:find("\n", pos, true)
        local lineStop = lineEnd and lineEnd - 1 or #content
        local line = content:sub(pos, lineStop)
        lineIndex = lineIndex + 1
        local trimmed = line:match("^%s*(.-)%s*$")
        if lineIndex > headerLines and trimmed ~= "" and not trimmed:match("^#") then
            local eq = line:find("=", 1, true)
            if eq ~= nil then
                local key = line:sub(1, eq - 1):match("^%s*(.-)%s*$")
                local valueFrom = pos + eq
                while valueFrom <= lineStop and content:sub(valueFrom, valueFrom):match("%s") do
                    valueFrom = valueFrom + 1
                end
                local valueTo = lineStop
                while valueTo >= valueFrom and content:sub(valueTo, valueTo):match("%s") do
                    valueTo = valueTo - 1
                end
                if key ~= "" and valueFrom <= valueTo then
                    local raw = content:sub(valueFrom, valueTo)
                    local value, valueType = ParseFramework.decodeValue(raw)
                    entries[#entries + 1] = { key = key, type = valueType, value = value,
                        from = valueFrom, to = valueTo }
                end
            end
        end
        pos = lineEnd and lineEnd + 1 or #content + 1
    end
    if #entries == 0 then
        return nil, "no key=value lines found"
    end
    return entries
end

function ParseFramework.rewrite(content, headerLines, edits)
    local entries, err = ParseFramework.parse(content, headerLines)
    if entries == nil then
        return nil, err
    end
    local byKey = {}
    for _, entry in ipairs(entries) do
        byKey[entry.key] = entry
    end
    local splices = {}
    for key, newValue in pairs(edits) do
        local entry = byKey[key]
        if entry == nil then
            return nil, "key not found: " .. key
        end
        local newType = entry.type
        if type(newValue) == "boolean" then newType = "boolean"
        elseif type(newValue) == "number" then newType = "number"
        else newType = "string" end
        splices[#splices + 1] = { from = entry.from, to = entry.to,
            text = ParseFramework.encodeValue(newValue, newType) }
    end
    table.sort(splices, function(a, b) return a.from > b.from end)
    for _, splice in ipairs(splices) do
        content = content:sub(1, splice.from - 1) .. splice.text .. content:sub(splice.to + 1)
    end
    return content
end

return ParseFramework
