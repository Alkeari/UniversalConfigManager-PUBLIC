-- Parses INI config files (flat `key=value` and `[Section]`ed) into flat entries, and splices new
-- values back in place, line by line, so comments and layout survive.
--
-- Value typing is by shape: true/false (case-insensitive) is boolean, tonumber-able is number,
-- everything else is string. Sectioned keys become `Section.key`.
local ParseIni = {}

-- Returns an ordered entry list ({ key, type, value, from, to }), or nil and a reason.
-- from/to are byte positions of the value text within `content`.
function ParseIni.parse(content)
    local entries = {}
    local section = ""
    local pos = 1
    local sawAnyLine = false
    while pos <= #content do
        local lineEnd = content:find("\n", pos, true)
        local lineStop = lineEnd and lineEnd - 1 or #content
        local line = content:sub(pos, lineStop)
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^[;#]") then
            sawAnyLine = true
            local sectionName = trimmed:match("^%[([^%]]*)%]$")
            if sectionName ~= nil then
                section = sectionName
            else
                local eq = line:find("=", 1, true)
                if eq ~= nil then
                    local key = line:sub(1, eq - 1):match("^%s*(.-)%s*$")
                    if key ~= "" and not key:find("[%[%]]") then
                        -- The value span excludes leading whitespace after `=` but keeps internal
                        -- and trailing text up to an end-of-line comment-free boundary: INI values
                        -- run to end of line.
                        local valueFrom = pos + eq
                        while valueFrom <= lineStop
                            and content:sub(valueFrom, valueFrom):match("%s") do
                            valueFrom = valueFrom + 1
                        end
                        local valueTo = lineStop
                        while valueTo >= valueFrom
                            and content:sub(valueTo, valueTo):match("%s") do
                            valueTo = valueTo - 1
                        end
                        local raw = valueFrom <= valueTo
                            and content:sub(valueFrom, valueTo) or ""
                        local value, valueType
                        local lowered = raw:lower()
                        if lowered == "true" or lowered == "false" then
                            value, valueType = lowered == "true", "boolean"
                        elseif tonumber(raw) ~= nil then
                            value, valueType = tonumber(raw), "number"
                        else
                            value, valueType = raw, "string"
                        end
                        local fullKey = section == "" and key or (section .. "." .. key)
                        -- An empty value still gets a span so a rewrite can fill it: from points
                        -- one past where the value would start.
                        entries[#entries + 1] = { key = fullKey, type = valueType, value = value,
                            from = valueFrom, to = valueTo }
                    end
                end
            end
        end
        pos = lineEnd and lineEnd + 1 or #content + 1
    end
    if #entries == 0 and not sawAnyLine then
        return nil, "empty file"
    end
    -- Duplicate keys keep the last occurrence (what most INI readers do).
    local byKey = {}
    local deduped = {}
    for _, entry in ipairs(entries) do
        if byKey[entry.key] ~= nil then
            deduped[byKey[entry.key]] = entry
        else
            deduped[#deduped + 1] = entry
            byKey[entry.key] = #deduped
        end
    end
    table.sort(deduped, function(a, b) return a.from < b.from end)
    return deduped
end

function ParseIni.serialize(value, valueType)
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
    return tostring(value)
end

function ParseIni.rewrite(content, edits)
    local entries, err = ParseIni.parse(content)
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
            text = ParseIni.serialize(newValue, entry.type) }
    end
    table.sort(splices, function(a, b) return a.from > b.from end)
    for _, splice in ipairs(splices) do
        if splice.from > splice.to then
            -- Empty value: insert at the from position.
            content = content:sub(1, splice.from - 1) .. splice.text
                .. content:sub(splice.from)
        else
            content = content:sub(1, splice.from - 1) .. splice.text
                .. content:sub(splice.to + 1)
        end
    end
    return content
end

return ParseIni
