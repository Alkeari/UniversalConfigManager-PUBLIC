-- Parses a Lua config module (a literal table, returned directly or built on a local), or a
-- script's top-level literal locals when it returns nothing, into flat entries, and splices new
-- values back in place so author comments and layout survive.
--
-- Only literal scalars are editable: true/false, numbers, quoted strings. A value that is anything
-- else (identifier, call, deep nesting) is skipped, never guessed at. Nested literal tables one
-- level deep contribute dotted keys.
local ParseLua = {}

local KEYWORDS = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
    ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true,
    ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
    ["until"] = true, ["while"] = true,
}

-- ============================== string escapes ==============================

-- Lua's own string escapes, decoded on read and re-encoded on write, because a config value is
-- whatever LUA sees after loading the file - not the characters between the quotes.
--
-- `\u{XXXX}` is the one that mattered: PalBoxQoL stores its button glyphs as "\u{2605}", which
-- Lua turns into a star. Reading it literally showed the player the escape instead of the glyph,
-- and writing it back through the old escaper doubled the backslash into "\\u{2605}", so a mod
-- that had a star would have rendered ten characters of text. Nothing here is specific to that
-- mod or to this machine (a standing rule): any config on any install that writes a codepoint
-- this way now round-trips, and so do \xHH and the decimal \ddd form.
--
-- Encoded by hand rather than through utf8.char, so the codec does not depend on which Lua
-- UE4SS was built with.
local function utf8Encode(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local SIMPLE_ESCAPES = {
    a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
    ["\\"] = "\\", ["\""] = "\"", ["'"] = "'",
}

-- Walked once by hand, never gsub: a replacement must never be re-scanned as an escape of its
-- own, and an unrecognized escape has to survive byte for byte rather than being swallowed.
function ParseLua.unescapeString(raw)
    local out, i, len = {}, 1, #raw
    while i <= len do
        local ch = raw:sub(i, i)
        if ch ~= "\\" or i == len then
            out[#out + 1] = ch
            i = i + 1
        else
            local next = raw:sub(i + 1, i + 1)
            local simple = SIMPLE_ESCAPES[next]
            local hex = next == "u" and raw:match("^\\u{(%x+)}", i)
            local byte = next == "x" and raw:match("^\\x(%x%x)", i)
            local decimal = raw:match("^\\(%d%d?%d?)", i)
            if hex then
                out[#out + 1] = utf8Encode(tonumber(hex, 16))
                i = i + 4 + #hex
            elseif byte then
                out[#out + 1] = string.char(tonumber(byte, 16))
                i = i + 4
            elseif simple then
                out[#out + 1] = simple
                i = i + 2
            elseif decimal and tonumber(decimal) < 256 then
                out[#out + 1] = string.char(tonumber(decimal))
                i = i + 1 + #decimal
            else
                -- Not an escape this parser knows: keep both bytes exactly as written.
                out[#out + 1] = ch
                i = i + 1
            end
        end
    end
    return table.concat(out)
end

-- The codepoints in `text`, as { char = "*", code = 0x2605 } in order. Used to write a value
-- back in the \u{} form its file already used, and by the Possible Entries strip to show a
-- glyph next to the code that produces it.
function ParseLua.codepoints(text)
    local points, i, len = {}, 1, #text
    while i <= len do
        local first = text:byte(i)
        local width = 1
        if first >= 0xF0 then width = 4
        elseif first >= 0xE0 then width = 3
        elseif first >= 0xC0 then width = 2 end
        local char = text:sub(i, i + width - 1)
        local code = first
        if width > 1 and #char == width then
            code = first % (2 ^ (7 - width))
            for at = 2, width do
                code = code * 0x40 + (char:byte(at) % 0x40)
            end
        end
        points[#points + 1] = { char = char, code = math.floor(code) }
        i = i + width
    end
    return points
end

-- Token stream with byte positions. Kinds: name, keyword, number, string, op.
local function tokenize(content)
    local tokens = {}
    local pos = 1
    local len = #content
    while pos <= len do
        local c = content:sub(pos, pos)
        if c == " " or c == "\t" or c == "\r" or c == "\n" then
            pos = pos + 1
        elseif content:sub(pos, pos + 1) == "--" then
            local longFrom, longTo = content:find("^%-%-%[(=*)%[", pos)
            if longFrom then
                local equals = content:match("^%-%-%[(=*)%[", pos)
                local closeFrom, closeTo = content:find("%]" .. equals .. "%]", longTo + 1, false)
                if not closeFrom then
                    return nil, "unterminated long comment at byte " .. pos
                end
                pos = closeTo + 1
            else
                local lineEnd = content:find("\n", pos, true)
                pos = lineEnd and lineEnd + 1 or len + 1
            end
        elseif c == "\"" or c == "'" then
            local from = pos
            pos = pos + 1
            while pos <= len do
                local ch = content:sub(pos, pos)
                if ch == "\\" then
                    pos = pos + 2
                elseif ch == c then
                    break
                elseif ch == "\n" then
                    return nil, "unterminated string at byte " .. from
                else
                    pos = pos + 1
                end
            end
            if pos > len then
                return nil, "unterminated string at byte " .. from
            end
            tokens[#tokens + 1] = { kind = "string", from = from, to = pos,
                text = content:sub(from, pos) }
            pos = pos + 1
        elseif content:find("^%[=*%[", pos) then
            local equals = content:match("^%[(=*)%[", pos)
            local from = pos
            local closeFrom, closeTo = content:find("%]" .. equals .. "%]", pos, false)
            if not closeFrom then
                return nil, "unterminated long string at byte " .. pos
            end
            tokens[#tokens + 1] = { kind = "longstring", from = from, to = closeTo,
                text = content:sub(from, closeTo) }
            pos = closeTo + 1
        elseif c:match("%d") or (c == "." and content:sub(pos + 1, pos + 1):match("%d")) then
            local from = pos
            local numEnd = pos
            if content:find("^0[xX]", pos) then
                numEnd = select(2, content:find("^0[xX][%da-fA-F]+", pos)) or pos
            else
                numEnd = select(2, content:find("^%d*%.?%d*", pos)) or pos
                local expFrom, expTo = content:find("^[eE][%+%-]?%d+", numEnd + 1)
                if expFrom then
                    numEnd = expTo
                end
            end
            tokens[#tokens + 1] = { kind = "number", from = from, to = numEnd,
                text = content:sub(from, numEnd) }
            pos = numEnd + 1
        elseif c:match("[%a_]") then
            local from, to = content:find("^[%w_]+", pos)
            local word = content:sub(from, to)
            tokens[#tokens + 1] = { kind = KEYWORDS[word] and "keyword" or "name",
                from = from, to = to, text = word }
            pos = to + 1
        else
            -- Multi-character operators do not matter here; single chars are enough to track
            -- structure and assignment.
            tokens[#tokens + 1] = { kind = "op", from = pos, to = pos, text = c }
            pos = pos + 1
        end
    end
    return tokens
end

local OPEN = { ["{"] = "}", ["("] = ")", ["["] = "]" }

-- Advances past one balanced value expression starting at index i; returns the index after it.
-- Used for values this parser does not edit (calls, deep tables, expressions).
local function skipValue(tokens, i)
    local depth = 0
    while i <= #tokens do
        local t = tokens[i]
        if t.kind == "op" then
            if OPEN[t.text] then
                depth = depth + 1
            elseif t.text == "}" or t.text == ")" or t.text == "]" then
                if depth == 0 then
                    return i   -- closer belongs to the enclosing table
                end
                depth = depth - 1
            elseif depth == 0 and (t.text == "," or t.text == ";") then
                return i
            end
        elseif t.kind == "keyword" and depth == 0
            and (t.text == "function") then
            -- function ... end: track end matching. Functions as values only appear in files this
            -- parser mostly skips; a conservative end-scan is enough.
            local fnDepth = 1
            i = i + 1
            while i <= #tokens and fnDepth > 0 do
                local w = tokens[i]
                if w.kind == "keyword" then
                    if w.text == "function" or w.text == "do" or w.text == "if"
                        or w.text == "for" or w.text == "while" or w.text == "repeat" then
                        fnDepth = fnDepth + 1
                    elseif w.text == "end" or w.text == "until" then
                        fnDepth = fnDepth - 1
                    end
                end
                i = i + 1
            end
            return i
        end
        i = i + 1
    end
    return i
end

-- Reads one scalar literal at index i. Returns entryValue, entryType, fromByte, toByte, nextIndex,
-- or nil when the value is not an editable literal.
local function readScalar(tokens, i)
    local t = tokens[i]
    if t == nil then
        return nil
    end
    if t.kind == "keyword" and (t.text == "true" or t.text == "false") then
        return t.text == "true", "boolean", t.from, t.to, i + 1
    end
    if t.kind == "number" then
        local value = tonumber(t.text)
        if value ~= nil then
            return value, "number", t.from, t.to, i + 1
        end
        return nil
    end
    if t.kind == "op" and t.text == "-" and tokens[i + 1] ~= nil
        and tokens[i + 1].kind == "number" then
        local value = tonumber(tokens[i + 1].text)
        if value ~= nil then
            return -value, "number", t.from, tokens[i + 1].to, i + 2
        end
        return nil
    end
    if t.kind == "string" then
        return ParseLua.unescapeString(t.text:sub(2, -2)), "string", t.from, t.to, i + 1
    end
    return nil
end

-- The value must be the whole expression: `x = 1 + 2` has a literal 1 at the value position but is
-- not editable as a literal. True when the next token ends the expression.
local function terminatesValue(tokens, i)
    local t = tokens[i]
    if t == nil then
        return true
    end
    if t.kind == "op" and (t.text == "," or t.text == ";" or t.text == "}") then
        return true
    end
    -- A new statement (name/keyword on a fresh assignment) also terminates in statement position;
    -- callers in table position only ever see , ; }.
    if t.kind == "keyword" and (t.text == "return" or t.text == "local" or t.text == "function") then
        return true
    end
    if t.kind == "name" then
        return true
    end
    return false
end

-- Parses `{ key = value, ... }` starting at the `{` token. Emits entries with dotted prefixes,
-- descending only maxDepth levels. Returns the index just after the closing `}`.
local function parseTableLiteral(tokens, i, prefix, depth, maxDepth, entries)
    i = i + 1   -- past `{`
    while i <= #tokens do
        local t = tokens[i]
        if t.kind == "op" and t.text == "}" then
            return i + 1
        end
        if t.kind == "op" and (t.text == "," or t.text == ";") then
            i = i + 1
        else
            local key = nil
            local valueAt = nil
            if t.kind == "name" and tokens[i + 1] ~= nil and tokens[i + 1].kind == "op"
                and tokens[i + 1].text == "=" then
                key = t.text
                valueAt = i + 2
            elseif t.kind == "op" and t.text == "[" and tokens[i + 1] ~= nil
                and tokens[i + 1].kind == "string"
                and tokens[i + 2] ~= nil and tokens[i + 2].kind == "op"
                and tokens[i + 2].text == "]"
                and tokens[i + 3] ~= nil and tokens[i + 3].kind == "op"
                and tokens[i + 3].text == "=" then
                key = tokens[i + 1].text:sub(2, -2)
                valueAt = i + 4
            end
            if key ~= nil then
                local fullKey = prefix == "" and key or (prefix .. "." .. key)
                local vt = tokens[valueAt]
                if vt ~= nil and vt.kind == "op" and vt.text == "{" and depth < maxDepth then
                    i = parseTableLiteral(tokens, valueAt, fullKey, depth + 1, maxDepth, entries)
                else
                    local value, valueType, from, to, nextI = readScalar(tokens, valueAt)
                    if value ~= nil and terminatesValue(tokens, nextI) then
                        entries[#entries + 1] = { key = fullKey, type = valueType,
                            value = value, from = from, to = to }
                        i = nextI
                    else
                        i = skipValue(tokens, valueAt)
                    end
                end
            else
                -- Array item or something unrecognized: skip its balanced extent.
                i = skipValue(tokens, i)
            end
        end
    end
    return i
end

-- Finds what the module returns: the index of `{` for `return {`, or the returned name for
-- `return NAME`. Only a `return` at the file's outermost block is the module's: one inside a
-- function body returns from that function.
local function findModuleReturn(tokens)
    local topLevel = {}
    local blockDepth = 0
    for i, t in ipairs(tokens) do
        if t.kind == "keyword" then
            if t.text == "function" or t.text == "do" or t.text == "if" or t.text == "repeat" then
                blockDepth = blockDepth + 1
            elseif t.text == "end" or t.text == "until" then
                blockDepth = blockDepth - 1
            elseif t.text == "return" and blockDepth == 0 then
                topLevel[i] = true
            end
        end
    end
    for i = #tokens, 1, -1 do
        local t = tokens[i]
        if topLevel[i] then
            local nextT = tokens[i + 1]
            if nextT ~= nil and nextT.kind == "op" and nextT.text == "{" then
                return i + 1, nil
            end
            if nextT ~= nil and nextT.kind == "name"
                and (tokens[i + 2] == nil or tokens[i + 2].kind ~= "op"
                     or (tokens[i + 2].text ~= "." and tokens[i + 2].text ~= "(")) then
                return nil, nextT.text
            end
        end
    end
    return nil, nil
end

-- Collects `NAME = { ... }` (local or not) and `NAME.key = literal` / `NAME.key = { ... }`
-- statements for the returned name. Statement recognition is positional: the pattern must start
-- right after a statement boundary, which for these files means the token before it is not `.`
-- or part of an expression.
local function parseBuiltTable(tokens, name, maxDepth, entries)
    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        if t.kind == "name" and t.text == name then
            local prev = tokens[i - 1]
            local prevOk = prev == nil
                or (prev.kind == "keyword" and (prev.text == "local" or prev.text == "end"
                    or prev.text == "then" or prev.text == "do"))
                or (prev.kind == "op" and (prev.text == "," or prev.text == ";"
                    or prev.text == "}" or prev.text == ")"))
                or (prev.kind == "string" or prev.kind == "number")
            -- Reject `foo.NAME` and `function NAME...` contexts.
            if prev ~= nil and prev.kind == "op" and (prev.text == "." or prev.text == ":") then
                prevOk = false
            end
            if prev ~= nil and prev.kind == "keyword" and prev.text == "function" then
                prevOk = false
            end
            if prevOk then
                local n1, n2 = tokens[i + 1], tokens[i + 2]
                if n1 ~= nil and n1.kind == "op" and n1.text == "="
                    and n2 ~= nil and n2.kind == "op" and n2.text == "{" then
                    i = parseTableLiteral(tokens, i + 2, "", 1, maxDepth, entries)
                elseif n1 ~= nil and n1.kind == "op" and n1.text == "." and n2 ~= nil
                    and n2.kind == "name" then
                    -- NAME.key(.sub)* = value
                    local path = { n2.text }
                    local j = i + 3
                    while tokens[j] ~= nil and tokens[j].kind == "op" and tokens[j].text == "."
                        and tokens[j + 1] ~= nil and tokens[j + 1].kind == "name" do
                        path[#path + 1] = tokens[j + 1].text
                        j = j + 2
                    end
                    if tokens[j] ~= nil and tokens[j].kind == "op" and tokens[j].text == "=" then
                        local keyPath = table.concat(path, ".")
                        local vt = tokens[j + 1]
                        if vt ~= nil and vt.kind == "op" and vt.text == "{" then
                            if #path < maxDepth then
                                i = parseTableLiteral(tokens, j + 1, keyPath, #path + 1,
                                    maxDepth, entries)
                            else
                                i = skipValue(tokens, j + 1)
                            end
                        else
                            local value, valueType, from, to, nextI = readScalar(tokens, j + 1)
                            if value ~= nil and terminatesValue(tokens, nextI) then
                                entries[#entries + 1] = { key = keyPath, type = valueType,
                                    value = value, from = from, to = to }
                                i = nextI
                            else
                                i = skipValue(tokens, j + 1)
                            end
                        end
                    else
                        i = i + 1
                    end
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

local BLOCK_OPENERS = { ["function"] = true, ["do"] = true, ["if"] = true, ["repeat"] = true }
local BLOCK_CLOSERS = { ["end"] = true, ["until"] = true }

-- Every assignment target the file writes outside a `local` declaration and outside a table
-- constructor, as dotted paths (`count`, `State.enabled`). A name the code itself assigns is
-- runtime state, whatever its starting literal, so it is never offered as a setting.
local function assignedPaths(tokens)
    local assigned = {}
    local braceDepth = 0
    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        if t.kind == "op" and t.text == "{" then
            braceDepth = braceDepth + 1
            i = i + 1
        elseif t.kind == "op" and t.text == "}" then
            braceDepth = braceDepth - 1
            i = i + 1
        elseif t.kind == "name" and braceDepth == 0 then
            local prev = tokens[i - 1]
            local declared = prev ~= nil and ((prev.kind == "keyword" and prev.text == "local")
                or (prev.kind == "op" and (prev.text == "." or prev.text == ":")))
            local path = { t.text }
            local j = i + 1
            while tokens[j] ~= nil and tokens[j].kind == "op" and tokens[j].text == "."
                and tokens[j + 1] ~= nil and tokens[j + 1].kind == "name" do
                path[#path + 1] = tokens[j + 1].text
                j = j + 2
            end
            local eq, after = tokens[j], tokens[j + 1]
            if not declared and eq ~= nil and eq.kind == "op" and eq.text == "="
                and not (after ~= nil and after.kind == "op" and after.text == "=") then
                assigned[table.concat(path, ".")] = true
            end
            i = j
        else
            i = i + 1
        end
    end
    return assigned
end

-- A script with no module return still declares its settings, as top-level `local NAME = literal`
-- constants or a `local Config = { ... }` table the rest of the file reads (BetterExpShare,
-- AoEHarvesting). Only statements at the file's outermost block count, keyed by the local's
-- name (a table's fields as `Config.field`), and anything the code later assigns is dropped.
local function parseTopLevelLocals(tokens, maxDepth, entries)
    local found = {}
    local blockDepth, bracketDepth = 0, 0
    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        if t.kind == "keyword" and BLOCK_OPENERS[t.text] then
            blockDepth = blockDepth + 1
            i = i + 1
        elseif t.kind == "keyword" and BLOCK_CLOSERS[t.text] then
            blockDepth = blockDepth - 1
            i = i + 1
        elseif t.kind == "op" and OPEN[t.text] then
            bracketDepth = bracketDepth + 1
            i = i + 1
        elseif t.kind == "op" and (t.text == "}" or t.text == ")" or t.text == "]") then
            bracketDepth = bracketDepth - 1
            i = i + 1
        elseif t.kind == "keyword" and t.text == "local" and blockDepth == 0
            and bracketDepth == 0 then
            local nameT, eq, vt = tokens[i + 1], tokens[i + 2], tokens[i + 3]
            if nameT ~= nil and nameT.kind == "name" and eq ~= nil and eq.kind == "op"
                and eq.text == "=" and vt ~= nil then
                if vt.kind == "op" and vt.text == "{" then
                    -- The braces are consumed here, so the bracket depth stays balanced.
                    i = parseTableLiteral(tokens, i + 3, nameT.text, 1, maxDepth, found)
                else
                    local value, valueType, from, to, nextI = readScalar(tokens, i + 3)
                    if value ~= nil and terminatesValue(tokens, nextI) then
                        found[#found + 1] = { key = nameT.text, type = valueType,
                            value = value, from = from, to = to }
                        i = nextI
                    else
                        i = i + 3
                    end
                end
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    local assigned = assignedPaths(tokens)
    for _, entry in ipairs(found) do
        if not assigned[entry.key] then
            entries[#entries + 1] = entry
        end
    end
end

-- Returns an ordered entry list ({ key, type, value, from, to }), or nil and a reason. An empty
-- list means the file parsed but holds no editable literals; callers skip it.
function ParseLua.parse(content)
    local tokens, err = tokenize(content)
    if tokens == nil then
        return nil, err
    end
    local entries = {}
    -- Three levels, not two: a mod that groups its settings under one module table and then by
    -- feature puts every real setting at depth three, and at two this mod saw only its runtime
    -- scratch (audit, 2026-09-03: HUDLocator's whole config was invisible). Deeper than three is
    -- data, not settings, and Config.maxSettingsPerFile still caps a file that disagrees.
    local maxDepth = 3
    local returnBrace, returnName = findModuleReturn(tokens)
    if returnBrace ~= nil then
        parseTableLiteral(tokens, returnBrace, "", 1, maxDepth, entries)
        -- `local NAME = {...} ... return NAME` files that ALSO assign NAME.key are handled below;
        -- a direct `return {` cannot be extended that way.
    elseif returnName ~= nil then
        parseBuiltTable(tokens, returnName, maxDepth, entries)
    end
    -- A returned table of no literals is an export list (`return { Config = Config }`,
    -- AoEHarvesting), so the settings are the locals it names, read the same way as a script
    -- that returns nothing.
    if returnName == nil and #entries == 0 then
        parseTopLevelLocals(tokens, maxDepth, entries)
        if #entries == 0 and returnBrace == nil then
            return nil, "no module return and no top-level literal settings found"
        end
    end
    -- Duplicate keys (a key assigned twice) keep the LAST occurrence, matching Lua semantics.
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

local PURE_DATA_KEYWORDS = { ["local"] = true, ["return"] = true, ["true"] = true,
    ["false"] = true, ["nil"] = true }
local PURE_DATA_OPS = { ["="] = true, ["{"] = true, ["}"] = true, [","] = true, [";"] = true,
    ["."] = true, ["["] = true, ["]"] = true, ["-"] = true }
local LITERAL_START_KEYWORDS = { ["true"] = true, ["false"] = true, ["nil"] = true }

-- True when the file is a pure data module: comments, `local name = {`, `name = literal`,
-- `name.field = literal`, `["key"] = literal`, nested literal tables, and a final `return`.
-- Any call, operator, control flow, `require`, concatenation, or identifier used as a value
-- fails the gate. Decided on the token stream, so a rejected file is never guessed at.
function ParseLua.isPureData(content)
    if content == nil or content:match("^%s*$") then
        return false, "empty file"
    end
    local tokens, err = tokenize(content)
    if tokens == nil then
        return false, err
    end
    if #tokens == 0 then
        return false, "no code"
    end
    for i, token in ipairs(tokens) do
        if token.kind == "keyword" and not PURE_DATA_KEYWORDS[token.text] then
            return false, "keyword '" .. token.text .. "' at byte " .. token.from
        end
        if token.kind == "op" then
            if not PURE_DATA_OPS[token.text] then
                return false, "operator '" .. token.text .. "' at byte " .. token.from
            end
            local nextToken = tokens[i + 1]
            if token.text == "." and nextToken ~= nil and nextToken.kind == "op"
                and nextToken.text == "." and nextToken.from == token.to + 1 then
                return false, "concatenation at byte " .. token.from
            end
            if token.text == "=" then
                if nextToken == nil then
                    return false, "dangling assignment at byte " .. token.from
                end
                if nextToken.kind == "op" and nextToken.text == "=" then
                    return false, "comparison at byte " .. token.from
                end
                local literalStart = nextToken.kind == "string" or nextToken.kind == "longstring"
                    or nextToken.kind == "number"
                    or (nextToken.kind == "keyword" and LITERAL_START_KEYWORDS[nextToken.text])
                    or (nextToken.kind == "op" and (nextToken.text == "{" or nextToken.text == "-"))
                if not literalStart then
                    return false, "non-literal value at byte " .. nextToken.from
                end
            end
            if token.text == "-" then
                if nextToken == nil or nextToken.kind ~= "number" then
                    return false, "operator '-' at byte " .. token.from
                end
            end
        end
        if token.kind == "name" then
            local nextToken = tokens[i + 1]
            local prevToken = i > 1 and tokens[i - 1] or nil
            -- Allowed patterns for name tokens:
            -- 1. Next token is =, ., or [ (assignment target or table path)
            local nextIsAssignOrPath = nextToken and (nextToken.text == "=" or nextToken.text == "." or nextToken.text == "[")
            -- 2. Previous token is . (field name)
            local prevIsDot = prevToken and prevToken.kind == "op" and prevToken.text == "."
            -- 3. Previous token is return keyword (module return)
            local prevIsReturn = prevToken and prevToken.kind == "keyword" and prevToken.text == "return"
            if not (nextIsAssignOrPath or prevIsDot or prevIsReturn) then
                return false, "identifier '" .. token.text .. "' at byte " .. token.from
            end
        end
    end
    return true
end

-- `escapeUnicode` re-encodes every codepoint above ASCII as \u{XXXX}, which is what a file that
-- already writes its values that way expects to get back. Without it a star would be written as
-- raw UTF-8 - still correct Lua, but a silent change to the author's own file style, and the
-- rewrite is meant to leave a file looking like the one it edited.
local function escapeLuaString(value, escapeUnicode)
    local escaped = value:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n")
        :gsub("\r", "\\r"):gsub("\t", "\\t")
    if not escapeUnicode then
        return escaped
    end
    local out = {}
    for _, point in ipairs(ParseLua.codepoints(escaped)) do
        out[#out + 1] = point.code < 0x80 and point.char
            or string.format("\\u{%X}", point.code)
    end
    return table.concat(out)
end

function ParseLua.serialize(value, valueType, escapeUnicode)
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
    return "\"" .. escapeLuaString(tostring(value), escapeUnicode) .. "\""
end

-- Splices `edits` (key -> new value) into `content`. Returns newContent, or nil and a reason.
-- The caller verifies by re-parsing; this function only refuses unknown keys and type changes.
function ParseLua.rewrite(content, edits)
    local entries, err = ParseLua.parse(content)
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
        -- A file that spells its codepoints as an escape gets them back in that same form,
        -- decided per value from the literal actually being replaced.
        local original = content:sub(entry.from, entry.to)
        local escapeUnicode = original:find("\\u{", 1, true) ~= nil
        splices[#splices + 1] = { from = entry.from, to = entry.to,
            text = ParseLua.serialize(newValue, entry.type, escapeUnicode) }
    end
    table.sort(splices, function(a, b) return a.from > b.from end)
    for _, splice in ipairs(splices) do
        content = content:sub(1, splice.from - 1) .. splice.text .. content:sub(splice.to + 1)
    end
    return content
end

return ParseLua
