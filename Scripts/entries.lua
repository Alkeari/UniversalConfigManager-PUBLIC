-- What a text box accepts, as lines a player can read: the Possible Entries strip's content.
-- Pure: no widget is touched here, so the offline suite runs every function on the shipped
-- language files at the shipped constants. Three parts:
--   Entries.resolve   the evidence ladder for one setting (cached on the entry), returning a
--                     source name and raw values, never prose;
--   Entries.lines     the localized lines for a resolved setting, the search box, or the
--                     preset name box, each line marked dim when it is this mod's inference
--                     (its text ends with " (?)", the catalog's own marker);
--   Entries.wrap/fit  the width estimator and line breaker, in UMG units measured off the
--                     rendered font (Config.ui.controls.hint.charWidth), never a character
--                     count: a proportional font makes "PAGE_UP" wider than "example".
local Bounds = require("bounds")
local I18n = require("i18n")
local Config = require("config")
local I18n = require("i18n")
local KeyNames = require("keynames")
local RowSpec = require("rowspec")
local Scope = require("scope")

local Entries = {}

local hint = Config.ui.controls.hint

-- ============================== width estimate ==============================

local function isWide(cp)
    return (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF)
        or (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60)
        or (cp >= 0xFFE0 and cp <= 0xFFE6)
end

-- Combining marks that attach to the glyph before them (Thai and Lao vowels and tones among
-- them): zero advance, and a line never starts with one.
local function isZeroWidth(cp)
    return (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x0483 and cp <= 0x0489)
        or cp == 0x0E31 or (cp >= 0x0E34 and cp <= 0x0E3A) or (cp >= 0x0E47 and cp <= 0x0E4E)
        or cp == 0x0EB1 or (cp >= 0x0EB4 and cp <= 0x0EBC) or (cp >= 0x0EC8 and cp <= 0x0ECD)
end

local UPPER_PUNCTUATION = { [0x5F] = true, [0x2F] = true, [0x2B] = true, [0x2D] = true,
    [0x2C] = true, [0x2E] = true, [0x3A] = true, [0x3B] = true }

local function isUpperish(cp)
    return (cp >= 0x30 and cp <= 0x39) or (cp >= 0x41 and cp <= 0x5A) or UPPER_PUNCTUATION[cp] == true
end

local function codepointWidth(cp)
    local widths = hint.charWidth
    if isZeroWidth(cp) then
        return widths.zero
    elseif isWide(cp) then
        return widths.wide
    elseif isUpperish(cp) then
        return widths.upper
    end
    return widths.lower
end

-- Code points of `text`, or nil when it is not valid UTF-8 (a raw byte string from a file).
local function codepoints(text)
    local ok, list = pcall(function()
        local out = {}
        for _, cp in utf8.codes(text) do
            out[#out + 1] = cp
        end
        return out
    end)
    return ok and list or nil
end

-- Estimated rendered width of `text` in UMG units at the game text block's default size.
function Entries.width(text)
    text = tostring(text or "")
    local cps = codepoints(text)
    if cps == nil then
        return #text * hint.charWidth.lower
    end
    local total = 0
    for _, cp in ipairs(cps) do
        total = total + codepointWidth(cp)
    end
    return total
end

-- ============================== line breaking ==============================

-- Splits `text` into atoms that must not be broken: a maximal run of non-space, non-wide code
-- points (so a key name like PAGE_DOWN or a word stays whole), or a single wide glyph (a
-- spaceless script breaks anywhere), with any combining mark glued to the atom before it. A
-- comma ends an atom so a list can break after it. Each atom records whether a space
-- preceded it. Returns a list of { text, width, spaceBefore }.
local function atoms(text)
    local out = {}
    local cps = codepoints(text) or {}
    local current, currentWidth, spaceBefore = {}, 0, false
    local function flush()
        if #current > 0 then
            out[#out + 1] = { text = utf8.char(table.unpack(current)), width = currentWidth,
                spaceBefore = spaceBefore }
            current, currentWidth = {}, 0
            spaceBefore = false
        end
    end
    for _, cp in ipairs(cps) do
        if cp == 0x20 then
            flush()
            spaceBefore = true
        elseif isZeroWidth(cp) then
            if #current == 0 and #out > 0 then
                local last = out[#out]
                last.text = last.text .. utf8.char(cp)
            else
                current[#current + 1] = cp
            end
        elseif isWide(cp) then
            flush()
            current[1] = cp
            currentWidth = codepointWidth(cp)
            flush()
        else
            current[#current + 1] = cp
            currentWidth = currentWidth + codepointWidth(cp)
            -- A comma always ends an atom so a list can break after it. A slash or a period ends
            -- one only once the run is already 8 code points long, which breaks an asset path
            -- ("/Game/Pal/Blueprint/UI/...WBP_Name.WBP_Name_C") that carries no space or comma
            -- and rendered 800 units past the strip's right edge, while leaving "0.5" and
            -- "1.2.3" whole.
            if cp == 0x2C or ((cp == 0x2F or cp == 0x2E) and #current >= 8) then
                flush()
            end
        end
    end
    flush()
    return out
end

-- Breaks one semantic line into rendered lines no wider than `maxWidth` units. An atom wider
-- than the whole width stands alone (never cut: cutting is what produced PAGE_UP/D + OWN).
function Entries.wrap(text, maxWidth)
    local lines = {}
    local current, currentWidth = {}, 0
    for _, atom in ipairs(atoms(tostring(text or ""))) do
        local gap = (#current > 0 and atom.spaceBefore) and hint.charWidth.lower or 0
        if #current > 0 and currentWidth + gap + atom.width > maxWidth then
            lines[#lines + 1] = table.concat(current)
            current, currentWidth = {}, 0
            gap = 0
        end
        if #current > 0 and atom.spaceBefore then
            current[#current + 1] = " "
        end
        current[#current + 1] = atom.text
        currentWidth = currentWidth + gap + atom.width
    end
    if #current > 0 then
        lines[#lines + 1] = table.concat(current)
    end
    return lines
end

-- Wraps every semantic line ({ text, dim }) into rendered pieces { text, dim, group }, `group`
-- being the index of the semantic line each piece came from. Nothing is cut or capped: every
-- entry is shown; the strip's filter box narrows a long list instead.
function Entries.fit(semanticLines, maxWidth)
    local rendered = {}
    for index, line in ipairs(semanticLines) do
        for _, piece in ipairs(Entries.wrap(line.text, maxWidth)) do
            rendered[#rendered + 1] = { text = piece, dim = line.dim and true or false, group = index }
        end
    end
    return rendered
end

-- The groups of `pieces` (from Entries.fit) whose whole entry contains `query`, as a set
-- { [group] = true }: case-insensitive, plain substring, whitespace trimmed; an empty query
-- keeps every group. Matching is per entry, not per piece, so a filter never shows half of a
-- wrapped entry. Pure, for the strip's filter box.
function Entries.filterGroups(pieces, query)
    local needle = tostring(query or ""):lower():match("^%s*(.-)%s*$")
    local texts = {}
    for _, piece in ipairs(pieces) do
        local group = piece.group or 1
        texts[group] = (texts[group] or "") .. " " .. tostring(piece.text):lower()
    end
    local visible = {}
    for group, text in pairs(texts) do
        visible[group] = needle == "" or text:find(needle, 1, true) ~= nil
    end
    return visible
end

-- The collapsed headline's sample: as many comma-separated `values` as fit `maxWidth` units
-- after `prefixWidth`, cut on a value boundary, never mid-value.
function Entries.sample(values, maxWidth, prefixWidth)
    local out = {}
    local width = prefixWidth
    for _, value in ipairs(values) do
        local piece = (#out > 0 and ", " or "") .. value
        local pieceWidth = Entries.width(piece)
        if width + pieceWidth > maxWidth then
            break
        end
        out[#out + 1] = value
        width = width + pieceWidth
    end
    return table.concat(out, ", ")
end

-- ============================== hotkeys ==============================

local NAVIGATION = { "SPACE", "TAB", "RETURN", "ESCAPE", "BACKSPACE", "CAPS_LOCK", "INS", "DEL",
    "HOME", "END", "PAGE_UP", "PAGE_DOWN", "UP_ARROW", "DOWN_ARROW", "LEFT_ARROW", "RIGHT_ARROW" }
local NUMPAD_OPERATORS = { "ADD", "SUBTRACT", "MULTIPLY", "DIVIDE", "DECIMAL" }

local function known(name)
    return KeyNames.keyIndex(name) ~= nil
end

local function filterKnown(names)
    local out = {}
    for _, name in ipairs(names) do
        if known(name) then
            out[#out + 1] = name
        end
    end
    return out
end

-- The groups of KeyNames.keys the strip names, each read back from the table itself so the
-- strip can never advertise a key the classifier rejects (the 2026-09-03 defect: "0-9" and
-- "arrow keys" were shown while ZERO..NINE and UP_ARROW were what worked). Mouse buttons are
-- left out on purpose: RegisterKeyBind on a mouse button wedges UE4SS (category pitfall).
function Entries.keyGroups()
    local letters, digits, functionKeys, numpad, gamepad = {}, {}, {}, {}, {}
    local digitOrder = { "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" }
    for _, name in ipairs(KeyNames.keys) do
        if name:match("^%u$") then
            letters[#letters + 1] = name
        elseif name:match("^F%d+$") then
            functionKeys[#functionKeys + 1] = name
        elseif name:match("^NUM_") then
            numpad[#numpad + 1] = name
        elseif name:match("^Gamepad_") then
            gamepad[#gamepad + 1] = name
        end
    end
    for _, name in ipairs(digitOrder) do
        if known(name) then
            digits[#digits + 1] = name
        end
    end
    local numpadOperators = filterKnown(NUMPAD_OPERATORS)
    table.sort(functionKeys, function(a, b) return tonumber(a:sub(2)) < tonumber(b:sub(2)) end)
    return {
        modifiers = { "CTRL", "SHIFT", "ALT" },
        letters = letters,
        digits = digits,
        functionKeys = functionKeys,
        navigation = filterKnown(NAVIGATION),
        numpad = numpad,
        numpadOperators = numpadOperators,
        gamepad = gamepad,
    }
end

-- Measured 2026-09-03 against every shipped language at 1100 units: the two key lists cost
-- three lines each whatever the language, so the block is held to Config maxLines by naming
-- the numpad digits as a range, one gamepad example, and the modifiers inside the combination
-- line (German and Indonesian were 15 lines with them separate).
local function hotkeyLines()
    local groups = Entries.keyGroups()
    local lines = {}
    local function add(key, vars, dim)
        lines[#lines + 1] = { text = I18n.t(key, vars), dim = dim and true or false }
    end
    add("hint_keys_letters", {
        first = groups.letters[1], last = groups.letters[#groups.letters],
        firstDigit = groups.digits[1], lastDigit = groups.digits[#groups.digits],
        firstF = groups.functionKeys[1], lastF = groups.functionKeys[#groups.functionKeys],
    })
    add("hint_keys_navigation", { list = table.concat(groups.navigation, ", ") })
    add("hint_keys_numpad", { first = groups.numpad[1], last = groups.numpad[#groups.numpad],
        operators = table.concat(groups.numpadOperators, ", ") })
    add("hint_keys_gamepad", { list = groups.gamepad[1] })
    add("hint_keys_combo", { list = table.concat(groups.modifiers, ", "), example = "CTRL+N",
        bare = "F7" })
    add("hint_keys_source", nil, true)
    return lines
end

-- ============================== the ladder ==============================

-- Distinct string values the same setting name takes across the mod's own files: its template
-- sibling and every other config file exposing that name. Two or more distinct values is a
-- choice set the author demonstrably used; one is just the current value.
-- A set a player can read at a glance. Beyond this many distinct values it is data, not a
-- vocabulary, and listing it buries the strip.
Entries.MAX_SIBLING_VALUES = 24

function Entries.valuesInFiles(entry, file, mod)
    local segment = Scope.lastSegment(entry.key):lower()
    local seen, ordered = {}, {}
    local function add(value)
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            ordered[#ordered + 1] = value
        end
    end
    add(tostring(entry.value))
    for _, templateEntry in ipairs(file.templateEntries or {}) do
        if Scope.lastSegment(templateEntry.key):lower() == segment then
            add(templateEntry.value)
        end
    end
    for _, other in ipairs(mod.files or {}) do
        if other ~= file then
            for _, otherEntry in ipairs(other.entries or {}) do
                if Scope.lastSegment(otherEntry.key):lower() == segment then
                    add(otherEntry.value)
                end
            end
        end
    end

    -- Siblings inside this same file count too. Beam Light Pillar keeps one row per tracked
    -- object, each with its own "group", so all 34 accepted groups sit in the player's own file
    -- while this rung looked only at OTHER files and found nothing (first player request,
    -- 2026-09-06). A closed set repeats: values are taken only when at least one of them is used
    -- more than once, which is what separates a vocabulary from a column of unique labels.
    local occurrences, distinct, repeated = 0, {}, false
    for _, sibling in ipairs(file.entries or {}) do
        if sibling ~= entry and Scope.lastSegment(sibling.key):lower() == segment
            and type(sibling.value) == "string" and sibling.value ~= "" then
            occurrences = occurrences + 1
            if distinct[sibling.value] then
                repeated = true
            end
            distinct[sibling.value] = true
        end
    end
    local distinctCount = 0
    for _ in pairs(distinct) do distinctCount = distinctCount + 1 end
    local substantial = repeated and distinctCount > 0 and distinctCount <= Entries.MAX_SIBLING_VALUES
        and occurrences >= distinctCount * 2
    if occurrences > 0 and substantial then
        for _, sibling in ipairs(file.entries or {}) do
            if sibling ~= entry and Scope.lastSegment(sibling.key):lower() == segment then
                add(sibling.value)
            end
        end
    end
    return ordered
end

local function schemaValues(entry)
    local choices = entry.schema and entry.schema.choices
    if type(choices) ~= "table" or #choices == 0 then
        return nil
    end
    local values = {}
    for _, choice in ipairs(choices) do
        local value = type(choice) == "table" and (choice.value or choice.label) or choice
        if value ~= nil then
            values[#values + 1] = tostring(value)
        end
    end
    return #values > 0 and values or nil
end

local function catalogValues(entry, mod, overrides)
    local record = overrides and overrides[mod.name .. "." .. entry.key]
    -- A mod staged for testing lives in "<PackageName>Dev" beside its released folder, so a
    -- catalog entry written for the release misses it. Present.lookup does this for descriptions;
    -- entries need the same fallback or a tester sees a floor line where a player sees the list.
    if record == nil and overrides ~= nil then
        local released = mod.name:match("^(.+)Dev$")
        if released ~= nil then
            record = overrides[released .. "." .. entry.key]
        end
    end
    if type(record) == "string" and record ~= "" then
        -- The strip is player-facing prose, so it follows the game's language like every other
        -- string here. The catalog holds the English; "e:<mod>.<key>" is its translation, and a
        -- language missing the key falls back to the English per key, never to a blank line.
        local key = mod.name:match("^(.+)Dev$") or mod.name
        return { I18n.lookup("e:" .. key .. "." .. entry.key) or record }
    end
    if type(record) == "table" and #record > 0 then
        return record
    end
    return nil
end

-- One setting's evidence, cached on the entry: { source, values }. Sources, first hit wins:
--   keys     a hotkey (RowSpec keyCombo): the KeyNames vocabulary
--   schema   a framework schema's own choice list
--   catalog  Scripts/catalog.lua entries["<mod>.<key>"], authored from the mod's page or README
--   files    distinct values across the mod's own template and other config files (?)
--   code     string literals the mod's code compares this setting against (?)
--   format   a format its code reads (color, url, path, list, number) (?)
--   floor    nothing found: any text (?)
--   none     not a text box at all (switch, slider, dropdown)
function Entries.resolve(entry, file, mod, overrides)
    if entry.entries ~= nil then
        return entry.entries
    end
    local resolved
    -- Only a string value can be a text box; a boolean or number never gets a strip, and
    -- classifying one without its value (a request fixture) would compare against nil.
    local spec = type(entry.value) == "string" and RowSpec.classify(entry, file, mod)
        or { kind = "none" }
    -- Precedence: the author's own published schema, then our curated entry, then everything
    -- derived. The curated entry must outrank the KEY VOCABULARY too: a mod that reads Unreal
    -- FKey names ("SpaceBar", "NumPadZero") was shown the UE4SS names ("SPACE", "NUM_ZERO"),
    -- which it rejects, because the hotkey branch ran first (audit, 2026-09-03: ten rows on
    -- this install advertised a vocabulary their own mod refuses).
    local declared = schemaValues(entry)
    local curated = catalogValues(entry, mod, overrides)
    if declared ~= nil then
        resolved = { source = "schema", values = declared }
    elseif curated ~= nil then
        resolved = { source = "catalog", values = curated }
    elseif spec.kind == "keyCombo" then
        -- A framework that DECLARES a keybind brings its own key spelling with it:
        -- DekModConfigMenu consumers compare against Unreal's own FKey names ("Five",
        -- "SpaceBar", "Gamepad_FaceButton_Bottom"), which are not the UE4SS names this
        -- vocabulary holds. Listing ours would advertise values the mod rejects, the same
        -- mistake the precedence note above records, so the floor line stands instead.
        if entry.schema ~= nil and entry.schema.type == "keybind" then
            resolved = { source = "floor", values = {} }
        else
            resolved = { source = "keys", values = {} }
        end
    elseif spec.kind ~= "text" then
        resolved = { source = "none", values = {} }
    else
        do
            do
                local values = Entries.valuesInFiles(entry, file, mod)
                if #values >= 2 then
                    resolved = { source = "files", values = values }
                else
                    local values = Bounds.literalsComparedTo(entry, mod.dir, file.path, mod.allFiles)
                    if values ~= nil and #values > 0 then
                        resolved = { source = "code", values = values }
                    else
                        local format = Bounds.hintForText(entry, mod.dir, file.path, mod.allFiles)
                        if format ~= nil then
                            resolved = { source = "format", values = { format } }
                        else
                            resolved = { source = "floor", values = {} }
                        end
                    end
                end
            end
        end
    end
    entry.entries = resolved
    return resolved
end

-- ============================== lines ==============================

local FORMAT_KEYS = { color = "hint_format_color", url = "hint_format_url",
    path = "hint_format_path", list = "hint_format_list", number = "hint_format_number" }

-- The semantic lines ({ text, dim }) for a resolved setting, before wrapping. `dim` marks a
-- line that is this mod's inference; its text carries the " (?)" marker from ui.tsv.
-- A glyph is the one kind of value a player can neither read as a code nor type as a picture, so
-- a listed value that is a single non-ASCII character is shown BOTH ways: the character itself,
-- and the \u{XXXX} escape that produces it: a player needs the appearance and the code both.
-- Derived from the value's own bytes, never from a list written against one mod on one machine,
-- so it holds for any config on any install - PalBoxQoL's button glyphs are simply the first
-- case of it.
--
-- The trailing " (?)" marker is lifted off first and put back after, or the last value in the
-- list would carry it and stop reading as a lone character.
function Entries.annotateGlyphs(text)
    text = tostring(text or "")
    local marker = ""
    if text:sub(-4) == " (?)" then
        marker = " (?)"
        text = text:sub(1, -5)
    end
    local pieces = {}
    for piece in text:gmatch("[^,]+") do
        local value = piece:match("^%s*(.-)%s*$")
        local points = codepoints(value)
        if points ~= nil and #points == 1 and points[1] >= 0x80 then
            pieces[#pieces + 1] = string.format("%s (\\u{%X})", value, points[1])
        else
            pieces[#pieces + 1] = value
        end
    end
    if #pieces == 0 then
        return text .. marker
    end
    return table.concat(pieces, ", ") .. marker
end

-- The strip's lines for a row that ALREADY displays its values, which is what a dropdown does.
-- Returns nil unless the resolved entries carry a note beyond the bare value list, because a
-- strip that repeats what the dropdown shows is noise: Passive Pals alone has 21 dropdowns.
-- A note is a parenthetical after a value, which is how the catalog writes one.
function Entries.annotatedLines(entry, file, mod, overrides)
    local resolved = Entries.resolve(entry, file, mod, overrides)
    if resolved == nil then
        return nil
    end
    -- Curated sources only. A dropdown that fell through to a mined or floor line would show a
    -- generic sentence under a control that already lists its values, which is the noise this
    -- gate exists to prevent.
    if resolved.source ~= "catalog" and resolved.source ~= "schema" then
        return nil
    end
    local lines = Entries.lines(resolved)
    if not Entries.hasNotes(lines) then
        return nil
    end
    return lines
end

-- Whether one value carries a note: a parenthesis INSIDE the value rather than at its start.
-- "smart_defender (winnable only)" carries one; "(empty)" does not, because there the
-- parenthesis is the value.
local function carriesNote(value)
    local trimmed = value:match("^%s*(.-)%s*$")
    local open = trimmed:find("(", 1, true)
    local wide = trimmed:find("\239\188\136", 1, true)
    if wide ~= nil and (open == nil or wide < open) then
        open = wide
    end
    return open ~= nil and open > 1
end

-- Whether any line carries a note beyond the value itself. A note is a parenthetical after a
-- value, which is how the catalog writes one.
--
-- This used to look for " (", a space before the parenthesis. Japanese, Korean and both Chinese
-- translations write the list with an ideographic comma and the note in fullwidth parentheses
-- with no space anywhere, so the test found nothing and the dropdown strip that English shows
-- was suppressed in four of the seventeen languages (2026-09-06). Split on the separator the
-- language actually uses and ask each value.
function Entries.hasNotes(lines)
    for _, line in ipairs(lines or {}) do
        if type(line.text) == "string" then
            local flat = line.text:gsub("\239\188\140", ","):gsub("\227\128\129", ",")
            for value in (flat .. ","):gmatch("(.-),") do
                if carriesNote(value) then
                    return true
                end
            end
        end
    end
    return false
end

function Entries.lines(resolved)
    local source = resolved.source
    if source == "keys" then
        return hotkeyLines()
    elseif source == "schema" or source == "catalog" then
        local lines = {}
        for _, value in ipairs(resolved.values) do
            lines[#lines + 1] = { text = Entries.annotateGlyphs(value),
                dim = value:sub(-4) == " (?)" }
        end
        return lines
    elseif source == "files" then
        return { { text = I18n.t("hint_entries_files",
            { list = Entries.annotateGlyphs(table.concat(resolved.values, ", ")) }), dim = true } }
    elseif source == "code" then
        return { { text = I18n.t("hint_entries_code",
            { list = Entries.annotateGlyphs(table.concat(resolved.values, ", ")) }), dim = true } }
    elseif source == "format" then
        return { { text = I18n.t(FORMAT_KEYS[resolved.values[1]] or "hint_floor"), dim = true } }
    elseif source == "floor" then
        return { { text = I18n.t("hint_floor"), dim = true } }
    end
    return {}
end

-- Whether a text field could have a closed set of accepted values at all.
--
-- Reaching the floor means this mod found no evidence of one. For a name that reads like a choice
-- ("mode", "language", "quality") the author still knows the set and is worth asking. For a plain
-- label, or any row in a lookup table of names, there is nothing to ask for: the field accepts any
-- text, and a list would be a lie. Asking anyway produced 177 unanswerable lines in the first
-- player request (2026-09-06).
local CHOICE_WORDS = { mode = true, language = true, lang = true, style = true, preset = true,
    quality = true, level = true, direction = true, align = true, alignment = true, position = true,
    anchor = true, sort = true, order = true, filter = true, type = true, kind = true,
    theme = true, format = true, unit = true, units = true, behavior = true, behaviour = true,
    profile = true, scope = true, state = true, target = true,
    key = true, keys = true, hotkey = true, hotkeys = true, bind = true, keybind = true,
    binding = true, button = true, shortcut = true, command = true, cmd = true, action = true,
    items = true, list = true, texture = true, work = true, suit = true }

function Entries.couldHaveClosedSet(entry, file)
    -- The whole key, not just its last segment: "keys.menu" is a keybind because of the parent,
    -- and reading only the leaf silenced every one of PalMiniMap's eleven bindings.
    local spaced = tostring(entry.key or ""):gsub("(%l)(%u)", "%1 %2"):gsub("[_%-%.]", " ")
    for word in spaced:gmatch("%a+") do
        if CHOICE_WORDS[word:lower()] then
            return true
        end
    end
    -- Only once the name says nothing does the shape of the file get a say.
    if file ~= nil and Scope.isNameTable(file.entries) then
        return false
    end
    return false
end


return Entries
