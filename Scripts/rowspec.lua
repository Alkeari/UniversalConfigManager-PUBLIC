-- Decides how one config entry is presented, from its type, name, value, and the comments
-- around it. Returns a spec:
--   { kind, choices?, current?, min?, max?, step?, modifier?, key? }
-- Kinds:
--   switch    - boolean, native on/off
--   switch01  - a 0/1 number that behaves as a flag; shown as a switch, written as 0/1
--   slider    - number with derived bounds
--   enum      - string with a known choice list (mined from comments, or a modifier set);
--               dropdown-rendered
--   keyCombo  - hotkey string ("CTRL+N" or "F7"): typed in the same editable text row as any
--               string; the kind only drives the "Hotkey" label suffix
--   text      - anything else: an editable free-text row (Rows.createTextEntry); falls back to
--               a read-only line only when the control itself cannot be built on this run
local Bounds = require("bounds")
local KeyNames = require("keynames")

local RowSpec = {}

-- ============================== enum choice mining ==============================

-- A choice list spelled out in the comments: `a | b | c`, or `one of/options/valid values:
-- a, b, c`. Only trusted when the current value is one of the choices.
local function commentChoiceCandidates(context)
    if context == nil then
        return {}
    end
    local candidates = {}
    for line in (context .. "\n"):gmatch("(.-)\n") do
        local comment = line:match("%-%-%s*(.*)$") or line:match("^%s*[;#]%s*(.*)$")
        if comment ~= nil then
            if comment:find("|", 1, true) then
                -- The list may sit inside prose ("Log detail. debug | info | warn"): the
                -- token just before the first pipe starts it, each pipe-suffixed token
                -- extends it.
                local first = comment:match("([%w_%-%.\"']+)%s*|")
                if first ~= nil then
                    local tokens = { (first:gsub("[\"']", "")) }
                    for token in comment:gmatch("|%s*([%w_%-%.\"']+)") do
                        tokens[#tokens + 1] = (token:gsub("[\"']", ""))
                    end
                    if #tokens >= 2 then
                        candidates[#candidates + 1] = tokens
                    end
                end
            end
            local listed = comment:match("[Oo]ne of:?%s*(.+)$")
                or comment:match("[Oo]ptions:?%s*(.+)$")
                or comment:match("[Vv]alid values:?%s*(.+)$")
                or comment:match("[Ss]upported values:?%s*(.+)$")
                or comment:match("[Aa]llowed values:?%s*(.+)$")
                or comment:match("[Aa]ccepted values:?%s*(.+)$")
                or comment:match("[Ll]egal values:?%s*(.+)$")
            if listed ~= nil then
                -- A parenthesized gloss after each entry ("30000 (300 m), 50000 (500 m), or
                -- 100000 (1000 m)") is the author explaining the list, not part of it; leaving it
                -- in threw the whole list away and drew a slider offering values the mod resets
                -- (audit, 2026-09-03: PalInsight.rarePalBeaconDistance).
                listed = listed:gsub("%b()", "")
                local tokens = {}
                for piece in listed:gmatch("[^,]+") do
                    piece = piece:match("^%s*(.-)%s*$")
                    piece = piece:gsub("^[Oo][Rr]%s+", ""):gsub("^[Aa][Nn][Dd]%s+", "")
                    piece = piece:gsub("%s*%.%s*$", ""):match("^%s*(.-)%s*$")
                    local token = piece:match("^[\"']?([%w_%-%.]+)[\"']?$")
                    if token ~= nil then
                        tokens[#tokens + 1] = token
                    end
                end
                if #tokens >= 2 then
                    candidates[#candidates + 1] = tokens
                end
            end
        end
    end
    return candidates
end

local function choicesFromComment(context, value)
    if type(value) ~= "string" then
        return nil
    end
    for _, tokens in ipairs(commentChoiceCandidates(context)) do
        for _, token in ipairs(tokens) do
            if token:lower() == value:lower() then
                return tokens
            end
        end
    end
    return nil
end

-- A number whose author spelled out its whole choice list ("Mode: 0 | 1 | 2", "Valid values: 8,
-- 12, 16") is an enum, not a range: dragging a slider between named modes offers values that do
-- not exist (audit, 2026-09-03). Every listed token must be numeric and the current value must
-- be one of them, so a documented range ("1 to 5") never becomes a dropdown by accident.
local function numericChoicesFromComment(context, value)
    if type(value) ~= "number" then
        return nil
    end
    for _, tokens in ipairs(commentChoiceCandidates(context)) do
        local allNumeric = true
        local matched = false
        for _, token in ipairs(tokens) do
            local number = tonumber(token)
            if number == nil then
                allNumeric = false
                break
            end
            if number == value then
                matched = true
            end
        end
        if allNumeric and matched then
            return tokens
        end
    end
    return nil
end

-- ============================== flag-shaped numbers ==============================

local FLAG_WORDS = { "enable", "disable", "check", "toggle", "allow", "show", "hide",
    "debug", "acknowledge", "active", "invert", "mute", "skip", "force", "confirm",
    "restart", "notify", "verbose" }

-- Words that prove a number counts or measures something, whatever flag word sits beside them:
-- `progressiveActiveThreshold` is a 0..999 count, not a switch, and switching it "off" wrote 0,
-- which that mod reads as always-on (audit, 2026-09-03).
local COUNT_WORDS = { "threshold", "count", "limit", "size", "max", "min", "level", "amount",
    "radius", "range", "distance", "delay", "interval", "seconds", "percent", "scale", "index",
    "version", "width", "height", "offset", "priority" }

local function isFlagNumber(key, value)
    if value ~= 0 and value ~= 1 then
        return false
    end
    if math.type(value) ~= "integer" and value ~= math.floor(value) then
        return false
    end
    -- Whole words of the LAST segment only: the first version matched substrings across the
    -- whole dotted key, so "active" inside "progressiveActiveThreshold" made it a switch.
    local segment = key:match("[^%.]+$") or key
    local words = " " .. segment:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
        :gsub("[_%-]", " "):lower() .. " "
    for _, word in ipairs(COUNT_WORDS) do
        if words:find("%f[%a]" .. word .. "s?%f[%A]") then
            return false
        end
    end
    for _, word in ipairs(FLAG_WORDS) do
        if words:find("%f[%a]" .. word .. "%a*%f[%A]") then
            return true
        end
    end
    -- is/has/use/should prefixes on the final camelCase segment.
    local segment = key:match("[^%.]+$") or key
    if segment:match("^[iI]s%u") or segment:match("^[hH]as%u")
        or segment:match("^[uU]se%u") or segment:match("^[sS]hould%u") then
        return true
    end
    return false
end

-- ============================== keybind shapes ==============================

local KEY_NAME_HINTS = { "key", "hotkey", "button", "bind", "shortcut" }

local function nameHintsKey(key)
    local lowered = key:lower()
    for _, hint in ipairs(KEY_NAME_HINTS) do
        if lowered:find(hint, 1, true) then
            return true
        end
    end
    return false
end

-- ============================== the classifier ==============================

-- `entry` is a parsed config entry; `file` and `mod` come from the scan model.
--
-- Cached on the entry, the same way Entries.resolve caches its own result and for the same
-- reason: classifying a number runs the whole bounds ladder, which pattern-matches over the
-- mod's concatenated source, so it cost 15 ms per setting and was paid again on every single
-- page open. PalInsight's 118 settings spent 1.8 seconds here, twice, before a widget existed
-- (measured on a real install, 2026-09-05). Scanner.refresh re-parses into NEW entry
-- tables, so the cache cannot outlive the values it describes.
function RowSpec.classify(entry, file, mod)
    if entry.spec ~= nil then
        return entry.spec
    end
    local spec = RowSpec.classifyUncached(entry, file, mod)
    entry.spec = spec
    return spec
end

function RowSpec.classifyUncached(entry, file, mod)
    local context = file.content ~= nil
        and Bounds.commentContextFor(file.content, entry.from) or nil

    -- An author's own published schema outranks every ladder below it: a framework that says a
    -- setting is a keybind, or names its vocabulary outright, has already answered the question
    -- the mining exists to guess at. Bounds.forEntry has honored `schema.min`/`schema.max` since
    -- the framework work; the row KIND was still being guessed, so a declared choice list came
    -- out as a plain text box unless a comment happened to repeat it.
    local schema = entry.schema
    if schema ~= nil then
        if schema.type == "keybind" then
            local value = tostring(entry.value)
            local lowered = value:lower()
            if lowered == "" or lowered == "none" or lowered == "off" then
                return { kind = "keyCombo", modifier = nil, key = value, unbound = true }
            end
            local modifier, keyName = value:match("^(.+)%+([^%+]+)$")
            return { kind = "keyCombo", modifier = modifier, key = keyName or value }
        end
        if type(schema.choices) == "table" and #schema.choices >= 2
            and entry.type ~= "boolean" then
            return { kind = "enum", choices = schema.choices,
                numeric = entry.type == "number" or nil }
        end
    end

    if entry.type == "boolean" then
        return { kind = "switch" }
    end

    if entry.type == "number" then
        if isFlagNumber(entry.key, entry.value) then
            return { kind = "switch01" }
        end
        local listed = numericChoicesFromComment(context, entry.value)
        if listed ~= nil then
            return { kind = "enum", choices = listed, numeric = true }
        end
        local minValue, maxValue, step, _, unit = Bounds.forEntry(entry, file.content, mod.dir,
            file.path, mod.allFiles, mod.name, file.entries)
        return { kind = "slider", min = minValue, max = maxValue, step = step, unit = unit }
    end

    -- Strings.
    local value = tostring(entry.value)

    -- A pure modifier field (SummonAllModifier=NONE) edits over the modifier set.
    if entry.key:lower():find("modifier", 1, true)
        and KeyNames.modifierIndex(value) ~= nil then
        local choices = {}
        for _, name in ipairs(KeyNames.modifiers) do
            choices[#choices + 1] = name
        end
        return { kind = "enum", choices = choices }
    end

    -- An UNBOUND hotkey. A mod spells "no key" as None, Off or an empty value, none of which is
    -- in the key vocabulary, so the row used to fall all the way through to plain text and lose
    -- both its Hotkey label and its list of keys - on every mod, for exactly the settings a
    -- player is most likely to want to bind (found via Palpedia Enhancer, 2026-09-04). The row a
    -- player needs here is the same one a bound hotkey gets.
    if nameHintsKey(entry.key) then
        local unbound = value:lower()
        if unbound == "" or unbound == "none" or unbound == "off" then
            return { kind = "keyCombo", modifier = nil, key = value, unbound = true }
        end
    end

    -- A hotkey: "CTRL+N", "F7", "G", "Gamepad_DPad_Up". A bare one-letter value only counts
    -- when the key's name says it is a key; a multi-token key name (PAGE_UP, Gamepad_*) is
    -- unambiguous on its own.
    local modifier, keyName = KeyNames.split(value)
    if modifier ~= nil then
        local unambiguous = #value > 2 or value:find("+", 1, true)
        if nameHintsKey(entry.key) or unambiguous then
            return { kind = "keyCombo", modifier = modifier, key = keyName }
        end
    end

    -- A choice list the author documented in the comments.
    local choices = choicesFromComment(context, value)
    if choices ~= nil then
        return { kind = "enum", choices = choices }
    end

    -- A choice list mined from the owning mod's own code: equality comparisons against the key
    -- (`if SizeMode == "mesh" then ... elseif SizeMode == "sprite" then ...`), the same
    -- evidence-based approach bounds.lua uses for numeric ranges. A short string with no such
    -- evidence stays read-only rather than being offered a guessed, possibly-wrong choice list.
    local codeChoices = Bounds.choicesForEntry(entry, mod.dir, file.path, mod.allFiles)
    if codeChoices ~= nil then
        return { kind = "enum", choices = codeChoices }
    end

    -- Everything else is read-only: names, versions, paths, class and function references, and
    -- any short string whose valid choices are not backed by evidence.
    return { kind = "text" }
end

-- Recombines a keyCombo selection into the stored string form.
RowSpec.joinKey = KeyNames.join
RowSpec.splitKey = KeyNames.split

return RowSpec
