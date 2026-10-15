-- Parses JSON config files into flat entries with byte spans, and splices new values back in
-- place, so formatting and key order survive. Nested objects contribute dotted keys; arrays and
-- null members are parsed past but not surfaced (nothing sensible to edit as a scalar row).
local ParseJson = {}

local function skipWhitespace(content, pos)
    while pos <= #content and content:sub(pos, pos):match("[ \t\r\n]") do
        pos = pos + 1
    end
    return pos
end

-- Returns the byte index just after the string's closing quote, or nil on malformed input.
local function skipString(content, pos)
    pos = pos + 1   -- past the opening quote
    while pos <= #content do
        local c = content:sub(pos, pos)
        if c == "\\" then
            pos = pos + 2
        elseif c == "\"" then
            return pos + 1
        else
            pos = pos + 1
        end
    end
    return nil
end

local function decodeString(raw)
    local inner = raw:sub(2, -2)
    return (inner:gsub("\\u(%x%x%x%x)", function(hex)
        local code = tonumber(hex, 16)
        return code < 128 and string.char(code) or utf8.char(code)
    end):gsub("\\(.)", {
        n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
        ["\""] = "\"", ["\\"] = "\\", ["/"] = "/",
    }))
end

local parseValue

-- Parses one value starting at pos. Emits scalar entries under `prefix`. Returns the index just
-- after the value, or nil and a reason.
parseValue = function(content, pos, prefix, entries)
    pos = skipWhitespace(content, pos)
    local c = content:sub(pos, pos)
    if c == "{" then
        pos = skipWhitespace(content, pos + 1)
        if content:sub(pos, pos) == "}" then
            return pos + 1
        end
        while true do
            pos = skipWhitespace(content, pos)
            if content:sub(pos, pos) ~= "\"" then
                return nil, "expected object key at byte " .. pos
            end
            local keyEnd = skipString(content, pos)
            if keyEnd == nil then
                return nil, "unterminated key at byte " .. pos
            end
            local key = decodeString(content:sub(pos, keyEnd - 1))
            pos = skipWhitespace(content, keyEnd)
            if content:sub(pos, pos) ~= ":" then
                return nil, "expected ':' at byte " .. pos
            end
            local childPrefix = prefix == "" and key or (prefix .. "." .. key)
            local afterValue, err = parseValue(content, pos + 1, childPrefix, entries)
            if afterValue == nil then
                return nil, err
            end
            pos = skipWhitespace(content, afterValue)
            local sep = content:sub(pos, pos)
            if sep == "," then
                pos = pos + 1
            elseif sep == "}" then
                return pos + 1
            else
                return nil, "expected ',' or '}' at byte " .. pos
            end
        end
    elseif c == "[" then
        pos = skipWhitespace(content, pos + 1)
        if content:sub(pos, pos) == "]" then
            return pos + 1
        end
        while true do
            -- Array members are structure to get past, not entries; a throwaway list swallows any
            -- scalars inside.
            local afterValue, err = parseValue(content, pos, prefix .. "[]", {})
            if afterValue == nil then
                return nil, err
            end
            pos = skipWhitespace(content, afterValue)
            local sep = content:sub(pos, pos)
            if sep == "," then
                pos = pos + 1
            elseif sep == "]" then
                return pos + 1
            else
                return nil, "expected ',' or ']' at byte " .. pos
            end
        end
    elseif c == "\"" then
        local from = pos
        local afterString = skipString(content, pos)
        if afterString == nil then
            return nil, "unterminated string at byte " .. pos
        end
        entries[#entries + 1] = { key = prefix, type = "string",
            value = decodeString(content:sub(from, afterString - 1)),
            from = from, to = afterString - 1 }
        return afterString
    elseif content:find("^true", pos) then
        entries[#entries + 1] = { key = prefix, type = "boolean", value = true,
            from = pos, to = pos + 3 }
        return pos + 4
    elseif content:find("^false", pos) then
        entries[#entries + 1] = { key = prefix, type = "boolean", value = false,
            from = pos, to = pos + 4 }
        return pos + 5
    elseif content:find("^null", pos) then
        return pos + 4
    else
        local from, to = content:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if from == nil then
            return nil, "unexpected character at byte " .. pos
        end
        local value = tonumber(content:sub(from, to))
        if value == nil then
            return nil, "bad number at byte " .. pos
        end
        entries[#entries + 1] = { key = prefix, type = "number", value = value,
            from = from, to = to }
        return to + 1
    end
end

-- Returns an ordered entry list ({ key, type, value, from, to }), or nil and a reason. The
-- document must be a JSON object.
function ParseJson.parse(content)
    local start = skipWhitespace(content, 1)
    if content:sub(start, start) ~= "{" then
        return nil, "not a JSON object"
    end
    local entries = {}
    local afterValue, err = parseValue(content, start, "", entries)
    if afterValue == nil then
        return nil, err
    end
    if skipWhitespace(content, afterValue) <= #content then
        return nil, "trailing content after the object"
    end
    return entries
end

local function escapeJsonString(value)
    return value:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n")
        :gsub("\r", "\\r"):gsub("\t", "\\t")
end

function ParseJson.serialize(value, valueType)
    if valueType == "boolean" then
        return value and "true" or "false"
    end
    if valueType == "number" then
        if math.type(value) == "integer" or value == math.floor(value) then
            return string.format("%d", value)
        end
        -- Shortest decimal form that reads back to exactly this double.
        local short = string.format("%.14g", value)
        if tonumber(short) == value then
            return short
        end
        return string.format("%.17g", value)
    end
    return "\"" .. escapeJsonString(tostring(value)) .. "\""
end

function ParseJson.rewrite(content, edits)
    local entries, err = ParseJson.parse(content)
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
        if type(newValue) ~= entry.type and not (entry.type == "number"
            and type(newValue) == "number") then
            return nil, "type mismatch for " .. key
        end
        splices[#splices + 1] = { from = entry.from, to = entry.to,
            text = ParseJson.serialize(newValue, entry.type) }
    end
    table.sort(splices, function(a, b) return a.from > b.from end)
    for _, splice in ipairs(splices) do
        content = content:sub(1, splice.from - 1) .. splice.text .. content:sub(splice.to + 1)
    end
    return content
end

return ParseJson
