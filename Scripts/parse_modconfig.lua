-- Reader and splice-in-place writer for DekModConfigMenu's `<Name>.modconfig.json`
-- (Nexus 577), the file format its Blueprint UI reads and writes.
--
-- Unlike NativeModOptions and PalModOptions, which broadcast a schema over UE4SS shared
-- variables (frameworks.lua), this framework keeps everything on disk: one file per consumer
-- that is BOTH the schema and the saved values. Each setting carries its own `type`, `desc`,
-- `opts` (a numeric range or a choice list), `init` (the author's default) and `live` (the
-- current value), so a mod using it needs no catalog entry from us at all: the author already
-- wrote the description, the bounds and the vocabulary.
--
-- Only `live` is ever written. `init` is read as the Restore to Default baseline, and every
-- other member (`type`, `desc`, `opts`, `reqs`, `flag`, `meta`, `note`) is read-only input.
--
-- Values that are objects rather than scalars are handled by shape, not by guesswork:
--   keybind  {"key": "F2", "bShift": false, "bCtrl": false, "bAlt": false, "bCmd": false}
--            becomes ONE hotkey row spelled "CTRL+F2", written back as up to five splices
--            into the members' own spans, so the file's formatting survives untouched.
--   color    {"r": 1, "g": 0.5, "b": 0, "a": 1} becomes four 0..1 numeric rows, since a
--            player editing a color needs each channel and the format has no hex form.
local ParseModconfig = {}

-- Structural members of a setting, never settings themselves.
local RESERVED_ROOT = { note = true, meta = true }

-- The framework's types, mapped onto the five this codebase normalizes every framework schema
-- to (frameworks.lua VALID_TYPES). `header` carries no value and `object` is a container; both
-- are handled before this table is consulted.
local TYPE_MAP = { boolean = "boolean", integer = "number", float = "number",
    option = "enum", string = "string", keybind = "keybind", color = "number" }

local KEYBIND_MODIFIERS = { { member = "bCtrl", name = "CTRL" }, { member = "bShift", name = "SHIFT" },
    { member = "bAlt", name = "ALT" }, { member = "bCmd", name = "CMD" } }

local COLOR_CHANNELS = { "r", "g", "b", "a" }

-- ============================== span-aware decode ==============================

-- parse_json.lua walks arrays but never surfaces them, and this format keeps a setting's whole
-- vocabulary in one ("opts": ["top", "center", "bottom"]), so the decode here is its own: it
-- returns a node tree that keeps every value's byte span, which is what lets a write replace
-- one scalar and leave the rest of the file byte-for-byte identical.
local decodeNode

local function skipWhitespace(content, pos)
    while pos <= #content and content:sub(pos, pos):match("[ \t\r\n]") do
        pos = pos + 1
    end
    return pos
end

local function decodeString(content, pos)
    local out = {}
    local from = pos
    pos = pos + 1
    while pos <= #content do
        local c = content:sub(pos, pos)
        if c == "\"" then
            return { kind = "string", value = table.concat(out), from = from, to = pos }, pos + 1
        elseif c == "\\" then
            local escaped = content:sub(pos + 1, pos + 1)
            if escaped == "n" then out[#out + 1] = "\n"
            elseif escaped == "t" then out[#out + 1] = "\t"
            elseif escaped == "r" then out[#out + 1] = "\r"
            elseif escaped == "b" then out[#out + 1] = "\b"
            elseif escaped == "f" then out[#out + 1] = "\f"
            elseif escaped == "u" then
                local code = tonumber(content:sub(pos + 2, pos + 5), 16)
                if code == nil then
                    return nil, nil, "bad \\u escape at byte " .. pos
                end
                out[#out + 1] = code < 128 and string.char(code) or utf8.char(code)
                pos = pos + 4
            else
                out[#out + 1] = escaped
            end
            pos = pos + 2
        else
            out[#out + 1] = c
            pos = pos + 1
        end
    end
    return nil, nil, "unterminated string at byte " .. from
end

decodeNode = function(content, pos)
    pos = skipWhitespace(content, pos)
    local from = pos
    local c = content:sub(pos, pos)
    if c == "\"" then
        return decodeString(content, pos)
    end
    if c == "{" or c == "[" then
        local isObject = c == "{"
        local node = { kind = isObject and "object" or "array", members = {}, order = {},
            items = {}, from = from }
        pos = skipWhitespace(content, pos + 1)
        local closer = isObject and "}" or "]"
        if content:sub(pos, pos) == closer then
            node.to = pos
            return node, pos + 1
        end
        while true do
            local key
            if isObject then
                pos = skipWhitespace(content, pos)
                if content:sub(pos, pos) ~= "\"" then
                    return nil, nil, "expected an object key at byte " .. pos
                end
                local keyNode, afterKey, err = decodeString(content, pos)
                if keyNode == nil then
                    return nil, nil, err
                end
                key = keyNode.value
                pos = skipWhitespace(content, afterKey)
                if content:sub(pos, pos) ~= ":" then
                    return nil, nil, "expected ':' at byte " .. pos
                end
                pos = pos + 1
            end
            local child, afterChild, err = decodeNode(content, pos)
            if child == nil then
                return nil, nil, err
            end
            if isObject then
                node.members[key] = child
                node.order[#node.order + 1] = key
            else
                node.items[#node.items + 1] = child
            end
            pos = skipWhitespace(content, afterChild)
            local sep = content:sub(pos, pos)
            if sep == "," then
                pos = pos + 1
            elseif sep == closer then
                node.to = pos
                return node, pos + 1
            else
                return nil, nil, "expected ',' or '" .. closer .. "' at byte " .. pos
            end
        end
    end
    local literal = content:match("^true", pos) or content:match("^false", pos)
    if literal ~= nil then
        return { kind = "boolean", value = literal == "true", from = from,
            to = from + #literal - 1 }, from + #literal
    end
    if content:match("^null", pos) then
        return { kind = "null", from = from, to = from + 3 }, from + 4
    end
    local number = content:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    if number ~= nil and number ~= "" and tonumber(number) ~= nil then
        return { kind = "number", value = tonumber(number), from = from,
            to = from + #number - 1 }, from + #number
    end
    return nil, nil, "unrecognized value at byte " .. pos
end

-- ============================== entries ==============================

-- Written long rather than as `cond and node.value or nil`, which returns nil for a boolean
-- `false` and so dropped all 18 settings in the sample corpus that ship switched off.
local function scalarOf(node)
    if node == nil then
        return nil
    end
    if node.kind == "string" or node.kind == "number" or node.kind == "boolean" then
        return node.value
    end
    return nil
end

-- "CTRL+F2" from the framework's keybind object. The key name is Unreal's own FKey spelling
-- ("F2", "Five", "Gamepad_DPad_Up"), left exactly as written: the consumer mod compares against
-- it, so translating it into this codebase's key vocabulary would hand the player a value their
-- own mod rejects.
function ParseModconfig.composeKeybind(node)
    local key = scalarOf(node.members and node.members.key)
    if type(key) ~= "string" then
        return nil
    end
    local parts = {}
    for _, modifier in ipairs(KEYBIND_MODIFIERS) do
        if scalarOf(node.members[modifier.member]) == true then
            parts[#parts + 1] = modifier.name
        end
    end
    parts[#parts + 1] = key
    return table.concat(parts, "+")
end

-- The inverse: the key name plus which modifier flags must now be true.
function ParseModconfig.decomposeKeybind(text)
    local flags = {}
    for _, modifier in ipairs(KEYBIND_MODIFIERS) do
        flags[modifier.member] = false
    end
    local key = tostring(text or "")
    while true do
        local head, rest = key:match("^([^+]+)%+(.+)$")
        if head == nil then
            break
        end
        local matched = false
        for _, modifier in ipairs(KEYBIND_MODIFIERS) do
            if head:upper() == modifier.name then
                flags[modifier.member] = true
                matched = true
                break
            end
        end
        if not matched then
            -- Not a modifier this framework has a flag for. A key name never contains a "+",
            -- so the rest is not ours to interpret: keep the value whole and let the write
            -- fail its re-parse rather than silently binding something else.
            return key, flags, "unknown modifier: " .. head
        end
        key = rest
    end
    return key, flags
end

local function optionChoices(optsNode)
    if optsNode == nil or optsNode.kind ~= "array" then
        return nil
    end
    local choices = {}
    for _, item in ipairs(optsNode.items) do
        local value = scalarOf(item)
        if value ~= nil then
            choices[#choices + 1] = tostring(value)
        end
    end
    return #choices > 0 and choices or nil
end

-- The author's description, plus what `reqs` says about when the setting applies. A player
-- looking at a greyed-out-in-the-other-menu setting has no other way to learn that.
local function hintFor(node)
    local desc = scalarOf(node.members.desc)
    local hint = type(desc) == "string" and desc ~= "" and desc or nil
    local reqs = node.members.reqs
    if reqs ~= nil and reqs.kind == "array" then
        local needs, blockedBy = {}, {}
        for _, item in ipairs(reqs.items) do
            local text = scalarOf(item)
            if type(text) == "string" then
                local negated = text:match("^NOT:(.+)$")
                if negated ~= nil then
                    blockedBy[#blockedBy + 1] = negated
                else
                    needs[#needs + 1] = text
                end
            end
        end
        local clauses = {}
        if #needs > 0 then
            clauses[#clauses + 1] = "applies only with " .. table.concat(needs, " and ") .. " on"
        end
        if #blockedBy > 0 then
            clauses[#clauses + 1] = "applies only with " .. table.concat(blockedBy, " and ")
                .. " off"
        end
        if #clauses > 0 then
            local sentence = "This " .. table.concat(clauses, ", and ") .. "."
            hint = hint ~= nil and (hint .. " " .. sentence) or sentence
        end
    end
    return hint
end

local function addEntry(entries, key, entryType, node, valueNode, defaultNode, schema, internal)
    local value = scalarOf(valueNode)
    if value == nil then
        return
    end
    entries[#entries + 1] = {
        key = key,
        type = entryType,
        value = value,
        from = valueNode.from,
        to = valueNode.to,
        default = scalarOf(defaultNode),
        schema = schema,
        internal = internal or nil,
    }
end

-- The author's own caption for a setting, which this format carries in a `name` member beside
-- `desc`. Without it the key is humanized instead, and "AbilityGlassesLocation" came out as
-- "Ability Glasses Location" where its author had written "Ability Glasses Storage Location"
-- (seen in a real request file, 2026-09-06).
local function captionFor(node, fallback)
    local declared = scalarOf(node.members.name)
    if type(declared) == "string" and declared ~= "" then
        return declared
    end
    return fallback
end

local function walkSetting(name, node, prefix, entries)
    if node.kind ~= "object" or node.members.type == nil then
        return
    end
    local declared = scalarOf(node.members.type)
    local key = prefix .. name
    if declared == "object" then
        local data = node.members.data
        if data ~= nil and data.kind == "object" then
            for _, child in ipairs(data.order) do
                walkSetting(child, data.members[child], key .. ".", entries)
            end
        end
        return
    end
    -- A header is a divider with a blurb and no value. This tab already groups a page by the
    -- dotted prefix an `object` produces, so a header row would be a second, emptier grouping.
    if declared == "header" then
        return
    end
    local normalized = TYPE_MAP[declared]
    if normalized == nil then
        return
    end
    local internal = scalarOf(node.members.flag) == "hidden" or nil
    local hint = hintFor(node)
    local live, init = node.members.live, node.members.init

    if declared == "keybind" then
        if live == nil or live.kind ~= "object" then
            return
        end
        local composed = ParseModconfig.composeKeybind(live)
        if composed == nil then
            return
        end
        entries[#entries + 1] = {
            key = key,
            type = "string",
            value = composed,
            from = live.from,
            to = live.to,
            default = init ~= nil and init.kind == "object"
                and ParseModconfig.composeKeybind(init) or nil,
            schema = { type = "keybind", label = captionFor(node, name), hint = hint },
            keybind = live,
            internal = internal,
        }
        return
    end

    if declared == "color" then
        if live == nil or live.kind ~= "object" then
            return
        end
        for _, channel in ipairs(COLOR_CHANNELS) do
            local channelNode = live.members[channel]
            if channelNode ~= nil and channelNode.kind == "number" then
                addEntry(entries, key .. "." .. channel, "number", node, channelNode,
                    init ~= nil and init.members and init.members[channel] or nil,
                    { type = "number", label = captionFor(node, name) .. " " .. channel:upper(), hint = hint,
                      min = 0, max = 1, step = 0.01 }, internal)
            end
        end
        return
    end

    local schema = { type = normalized, label = captionFor(node, name), hint = hint }
    local opts = node.members.opts
    if opts ~= nil and opts.kind == "object" then
        schema.min = scalarOf(opts.members.min)
        schema.max = scalarOf(opts.members.max)
        schema.step = scalarOf(opts.members.step)
    else
        schema.choices = optionChoices(opts)
    end
    -- An integer setting must stay an integer through a write: the framework reads it back into
    -- a Blueprint int and a "5.0" is not that.
    schema.integer = declared == "integer" or nil
    addEntry(entries, key, normalized == "boolean" and "boolean"
        or normalized == "number" and "number" or "string", live, live, init, schema, internal)
end

-- Whether this content is a DekModConfigMenu file rather than some other JSON that happens to
-- be named the same way. Judged on the shape, never on the name alone: a root object with at
-- least one member declaring a `type` this framework defines.
function ParseModconfig.looksLikeModconfig(content)
    local root, _, err = decodeNode(content, 1)
    if root == nil or root.kind ~= "object" then
        return false, err or "not a JSON object"
    end
    for _, name in ipairs(root.order) do
        if not RESERVED_ROOT[name] then
            local member = root.members[name]
            if member.kind == "object" then
                local declared = scalarOf(member.members.type)
                if declared ~= nil and (TYPE_MAP[declared] ~= nil or declared == "object"
                    or declared == "header") then
                    return true
                end
            end
        end
    end
    return false, "no member declares a DekModConfigMenu type"
end

-- Returns an ordered entry list ({ key, type, value, from, to, default, schema }), plus the
-- file's `meta` table when it carries one, or nil and a reason.
function ParseModconfig.parse(content)
    local root, _, err = decodeNode(content, 1)
    if root == nil then
        return nil, err
    end
    if root.kind ~= "object" then
        return nil, "not a JSON object"
    end
    local entries = {}
    for _, name in ipairs(root.order) do
        if not RESERVED_ROOT[name] then
            walkSetting(name, root.members[name], "", entries)
        end
    end
    local meta = {}
    local metaNode = root.members.meta
    if metaNode ~= nil and metaNode.kind == "object" then
        meta.version = scalarOf(metaNode.members.vers)
        meta.author = scalarOf(metaNode.members.auth)
        meta.description = scalarOf(metaNode.members.desc)
    end
    return entries, nil, meta
end

local function escapeJsonString(value)
    return value:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n")
        :gsub("\r", "\\r"):gsub("\t", "\\t")
end

function ParseModconfig.serialize(value, valueType, integer)
    if valueType == "boolean" then
        return value and "true" or "false"
    end
    if valueType == "number" then
        if integer or math.type(value) == "integer" or value == math.floor(value) then
            return string.format("%d", math.floor(value + (value >= 0 and 0.5 or -0.5)))
        end
        local short = string.format("%.14g", value)
        return tonumber(short) == value and short or string.format("%.17g", value)
    end
    return "\"" .. escapeJsonString(tostring(value)) .. "\""
end

-- Splices new `live` values into `content`, leaving every byte this codebase did not change
-- exactly where it was. `edits` is keyed the way `parse` keys its entries.
function ParseModconfig.rewrite(content, edits)
    local entries, err = ParseModconfig.parse(content)
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
        if entry.keybind ~= nil then
            local keyName, flags, badModifier = ParseModconfig.decomposeKeybind(newValue)
            if badModifier ~= nil then
                return nil, badModifier
            end
            local keyNode = entry.keybind.members.key
            splices[#splices + 1] = { from = keyNode.from, to = keyNode.to,
                text = ParseModconfig.serialize(keyName, "string") }
            for _, modifier in ipairs(KEYBIND_MODIFIERS) do
                local flagNode = entry.keybind.members[modifier.member]
                if flagNode ~= nil and flagNode.kind == "boolean" then
                    splices[#splices + 1] = { from = flagNode.from, to = flagNode.to,
                        text = ParseModconfig.serialize(flags[modifier.member], "boolean") }
                end
            end
        else
            if type(newValue) ~= entry.type then
                return nil, "type mismatch for " .. key
            end
            splices[#splices + 1] = { from = entry.from, to = entry.to,
                text = ParseModconfig.serialize(newValue, entry.type,
                    entry.schema and entry.schema.integer) }
        end
    end
    table.sort(splices, function(a, b) return a.from > b.from end)
    for _, splice in ipairs(splices) do
        content = content:sub(1, splice.from - 1) .. splice.text .. content:sub(splice.to + 1)
    end
    return content
end

return ParseModconfig
