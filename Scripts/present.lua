-- Derives everything the panel shows for a mod or a setting, once, after the boot scan:
-- the mod's display name, each setting's label, its tooltip text, and its sub-header group.
-- Every rule is evidence-based so it holds on any install; the three override tables are the
-- curated escape hatch and ship empty.
local FsUtil = require("fsutil")
local I18n = require("i18n")
local ParseJson = require("parse_json")
local Scope = require("scope")

local Present = {}

Present.COMMUNITY_PROMPT = "No description yet. Notify Alkeari!"

-- names["<modFolder>.<rawKey>"] = label; descriptions[same] = tooltip; mods["<modFolder>"] = name.
-- Shipped in Scripts/catalog.lua; a catalog that fails to load leaves the tables empty.
local function loadCatalog()
    local ok, catalog = pcall(require, "catalog")
    if not ok or type(catalog) ~= "table" then
        return {}
    end
    return catalog
end
local catalog = loadCatalog()
-- A mod staged for testing installs under "<PackageName>Dev" beside its released folder, so every
-- catalog key written for the release ("PalpediaEnhancer.VerboseLogging") misses the staged copy
-- ("PalpediaEnhancerDev.VerboseLogging") and its settings read as undescribed. Whoever is testing
-- a mod is exactly who should see what a player will, so a Dev folder falls back to its release
-- name. The release key is never rewritten, so a catalog entry deliberately written for a Dev
-- folder still wins (found 2026-09-04, staging Palpedia Enhancer beside its Workshop copy).
function Present.lookup(overrides, modName, key, fileRel)
    local suffix = key ~= nil and ("." .. key) or ""
    -- A file-scoped key wins: "PerfProbe.settings.txt:mode" before "PerfProbe.mode".
    if fileRel ~= nil and key ~= nil then
        local leaf = tostring(fileRel):match("([^\\/]+)$") or tostring(fileRel)
        local scoped = overrides[modName .. "." .. leaf .. ":" .. key]
        if scoped ~= nil then
            return scoped
        end
        local releasedName = modName:match("^(.+)Dev$")
        if releasedName ~= nil then
            scoped = overrides[releasedName .. "." .. leaf .. ":" .. key]
            if scoped ~= nil then
                return scoped
            end
        end
    end
    local hit = overrides[modName .. suffix]
    if hit ~= nil then
        return hit
    end
    local released = modName:match("^(.+)Dev$")
    if released ~= nil then
        return overrides[released .. suffix]
    end
    return nil
end

Present.overrides = { names = catalog.names or {}, descriptions = catalog.descriptions or {},
    mods = catalog.mods or {}, entries = catalog.entries or {}, hidden = catalog.hidden or {},
    restart = catalog.restart or {} }

local ABBREVIATIONS = { Cfg = "Config", Btn = "Button", Auto = "Auto", Hp = "HP", Mp = "MP",
    Fps = "FPS", Ui = "UI", Id = "ID", Url = "URL", HUD = "HUD" }

-- Acronyms the camel split tears apart, keyed by their letters with no separators: "PalBoxQoL"
-- splits to Pal|Box|Qo|L, which renders as "Pal Box Qo L", and "IVs" to I|Vs. After
-- splitting, any run of two or three consecutive words whose letters spell one of these is
-- rejoined as the canonical form. Longest run wins, so QOL is preferred over any shorter match.
local ACRONYMS = {
    qol = "QoL", hud = "HUD", ui = "UI", fps = "FPS", hp = "HP", mp = "MP", xp = "XP",
    id = "ID", ids = "IDs", url = "URL", urls = "URLs", npc = "NPC", npcs = "NPCs", ai = "AI",
    rgb = "RGB", rpc = "RPC", iv = "IV", ivs = "IVs", dps = "DPS", gui = "GUI", api = "API",
    ue4ss = "UE4SS", ok = "OK", tsv = "TSV", csv = "CSV", ini = "INI", json = "JSON",
    fov = "FOV", ms = "ms", hq = "HQ", pvp = "PvP", pve = "PvE",
    ["3d"] = "3D", ["2d"] = "2D", ["4k"] = "4K",
}

-- Rejoins the acronym runs ACRONYMS names, longest first.
local function mergeAcronyms(words)
    local index = 1
    while index <= #words do
        local merged = false
        for span = math.min(3, #words - index + 1), 2, -1 do
            local letters = table.concat(words, "", index, index + span - 1):lower()
            if ACRONYMS[letters] ~= nil then
                for _ = 2, span do
                    table.remove(words, index + 1)
                end
                words[index] = ACRONYMS[letters]
                merged = true
                break
            end
        end
        if not merged then
            local single = ACRONYMS[tostring(words[index]):lower()]
            if single ~= nil then
                words[index] = single
            end
            index = index + 1
        end
    end
    return words
end

local function splitWords(rawKey)
    local spaced = rawKey:gsub("_", " ")
    spaced = spaced:gsub("(%l)(%u)", "%1 %2")
    spaced = spaced:gsub("(%u)(%u%l)", "%1 %2")
    spaced = spaced:gsub("(%a)(%d)", "%1 %2")
    spaced = spaced:gsub("(%d)(%a)", "%1 %2")
    local words = {}
    for word in spaced:gmatch("%S+") do
        if ABBREVIATIONS[word] ~= nil then
            words[#words + 1] = ABBREVIATIONS[word]
        elseif #word > 1 and word:match("^%u+$") then
            -- An all-caps token is an acronym the author wrote as one: RT_PATH is "RT Path",
            -- not "Rt Path", and XL is "XL", not "Xl" (audit, 2026-09-03: 30 labels).
            words[#words + 1] = word
        else
            words[#words + 1] = word:sub(1, 1):upper() .. word:sub(2):lower()
        end
    end
    return mergeAcronyms(words)
end

function Present.humanize(rawKey, isHotkey)
    local words = splitWords(rawKey)
    if isHotkey then
        local last = words[#words]
        if last ~= "Hotkey" and last ~= "Key" then
            words[#words + 1] = "Hotkey"
        elseif last == "Key" then
            words[#words] = "Hotkey"
        end
    end
    return table.concat(words, " ")
end

-- Whether a key names one saved row belonging to a particular player, pal or world rather than
-- a setting: no catalog line could ever match it, so it is never worth asking a player to
-- describe. Two shapes, both seen on real installs:
--   "steam@11000010...".."fov"   an id beside an "@", the original rule;
--   "default.FFFFFFFFDC0ED2FE4BA5131E1AAF24A90F4A466A.total"   a whole key segment that is
--                                 nothing but hex, which is how a GUID is written.
-- The second needs no "@" but does need length: eight hex characters can still spell a word
-- ("deadbeef", "facade"), sixteen in a row cannot. PalsLearnOverTime's save file put 100 such
-- rows into a description request the first time I played with it (2026-09-06).
function Present.carriesOwnerId(key)
    key = tostring(key or "")
    if key:find("%x%x%x%x%x%x%x%x") ~= nil and key:find("@") ~= nil then
        return true
    end
    for segment in key:gmatch("[^%.]+") do
        if #segment >= 16 and segment:match("^%x+$") ~= nil then
            return true
        end
    end
    return false
end

-- ============================== key stripping ==============================

local HUNGARIAN = { b = true, i = true, f = true, s = true }

local function stripHungarian(key)
    local prefix, rest = key:match("^([bifs])(%u.*)$")
    if prefix ~= nil and HUNGARIAN[prefix] then
        -- Not when the prefix and the letter after it spell an acronym: PalInsight writes
        -- individual values as iVSeparator, and stripping the i left "V Separator" (audit,
        -- 2026-09-03).
        if ACRONYMS[(prefix .. rest:sub(1, 1)):lower()] ~= nil then
            return key
        end
        return rest
    end
    return key
end

-- The leading camel word of a key ("Pal" in PalModName, "vux" in vuxModName), or nil.
local function leadingCamelWord(key)
    local word = key:match("^(%l+)%u") or key:match("^(%u%l*)%u")
    return word
end

-- Meaningful short prefixes that carry information (max/min/is/etc.) and are never stripped
-- even when every key in the file happens to share them; only vendor/mod-name tokens (Pal,
-- vux, ...) get dropped here.
local MEANINGFUL_PREFIXES = { max = true, min = true, is = true, has = true, get = true,
    set = true, use = true, new = true, old = true, cur = true, def = true, num = true,
    auto = true, show = true, hide = true, mod = true }

-- Maps each raw key of ONE file to its stripped form:
--   1. a dotted group shared by every key is dropped (Defaults.enableMod -> enableMod);
--      differing groups are kept out of the key here and shown as sub-headers instead;
--   2. a short (<= 4 chars) leading camel word shared by every key, three keys or more,
--      is dropped (PalModName -> ModName) - long shared words like Enable are meaning, kept,
--      and so is a meaningful short word like max/min/is (MEANINGFUL_PREFIXES).
--   3. a Hungarian b/i/f/s before an uppercase letter is dropped.
function Present.stripPrefixes(keys)
    local result = {}
    local segments = {}
    local groups = {}
    local groupCount = 0
    for _, key in ipairs(keys) do
        local group = key:match("^(.*)%.[^%.]+$")
        local segment = Scope.lastSegment(key)
        segments[key] = segment
        if group ~= nil and not groups[group] then
            groups[group] = true
            groupCount = groupCount + 1
        end
    end
    local sharedWord = nil
    if #keys >= 3 then
        for _, key in ipairs(keys) do
            local word = leadingCamelWord(segments[key])
            if word == nil or #word > 4 then
                sharedWord = nil
                break
            end
            if sharedWord == nil then
                sharedWord = word
            elseif sharedWord ~= word then
                sharedWord = nil
                break
            end
        end
        if sharedWord ~= nil and MEANINGFUL_PREFIXES[sharedWord:lower()] then
            sharedWord = nil
        end
    end
    for _, key in ipairs(keys) do
        local stripped = segments[key]
        if sharedWord ~= nil then
            stripped = stripped:sub(#sharedWord + 1)
        end
        stripped = stripHungarian(stripped)
        if stripped == "" then
            stripped = segments[key]
        end
        result[key] = stripped
    end
    return result
end

-- The sub-header a key belongs under: its dotted group when the file has more than one group,
-- else nil (a single shared group was stripped as noise, not shown).
local function groupOf(key, groupCount)
    if groupCount < 2 then
        return nil
    end
    return key:match("^(.*)%.[^%.]+$")
end

-- ============================== labels ==============================

function Present.labelFor(modName, rawKey, strippedKey, isHotkey, schemaLabel)
    local override = Present.lookup(Present.overrides.names, modName, rawKey)
    if override ~= nil then
        return override
    end
    if type(schemaLabel) == "string" and schemaLabel ~= "" then
        -- A framework's label is usually already a caption ("Minimap Size", "Vertical Pull").
        -- One with no space in it is the author's identifier rather than a caption
        -- ("OpenUIKey"), so it earns the same humanizing a raw key gets.
        if schemaLabel:find(" ", 1, true) == nil then
            return Present.humanize(schemaLabel, isHotkey)
        end
        return schemaLabel
    end
    return Present.humanize(strippedKey, isHotkey)
end

-- ============================== descriptions ==============================

local REJECTED_WORDS = { "agent", "todo", "fixme", "pending", "retest", "first guess",
    "tune freely", "per an in%-game report", "verification" }
local MONTHS = { "january", "february", "march", "april", "may", "june", "july", "august",
    "september", "october", "november", "december" }

local function commentLines(context)
    local lines = {}
    for line in (context .. "\n"):gmatch("(.-)\n") do
        local comment = line:match("%-%-%s*(.*)$") or line:match("^%s*[;#]%s*(.*)$")
        if comment ~= nil then
            comment = comment:gsub("^[%-%s;#]+", ""):gsub("%s+$", "")
            lines[#lines + 1] = comment
        end
    end
    return lines
end

-- The earlier test, `text:find("[\\/]")`, rejected ANY tooltip containing a bare "/"
-- ("true/false", "on/off", "km/h", real Tidy Base Info text), not just an actual path. A
-- backslash anywhere is still always path-like (Windows has no other use for one here). A
-- forward slash is path-like only when the token around it looks like an actual path: it starts
-- with "./", "../", or a drive letter ("C:/"), one of its "/"-separated segments carries a
-- dot-extension ("config.lua"), or it has two or more slashes ("/usr/bin"). A single slash
-- joining two plain word/number segments ("true/false", "km/h") is left alone.
local function looksLikePathToken(token)
    if token:match("^%.%.?/") ~= nil or token:match("^%a:/") ~= nil then
        return true
    end
    if select(2, token:gsub("/", "")) >= 2 then
        return true
    end
    for segment in token:gmatch("[^/]+") do
        if segment:match("%.%a+$") ~= nil then
            return true
        end
    end
    return false
end

local function looksLikePath(text)
    if text:find("\\", 1, true) ~= nil then
        return true
    end
    for token in text:gmatch("%S+") do
        if token:find("/", 1, true) ~= nil and looksLikePathToken(token) then
            return true
        end
    end
    return false
end

-- No date, no path, no internal-note vocabulary, at most `maxChars` characters and at most
-- `maxSentenceBreaks` sentence boundaries (0 for a single sentence, the own-line/schema-hint
-- rule; 2 for the up-to-three-sentence comment-block rule below).
local function isPlayerFacing(text, maxChars, maxSentenceBreaks)
    maxChars = maxChars or 140
    maxSentenceBreaks = maxSentenceBreaks or 0
    if text == "" or #text > maxChars then
        return false
    end
    -- A comment written in another script (Korean, Chinese, Japanese author notes on the
    -- reference install: InstantHaul, GhostWildCaptureHp) is not readable by this UI's
    -- English-speaking player. Multibyte bytes above a fifth of the text is that; an English
    -- sentence with a stray typographic quote or accent stays well under.
    local multibyte = select(2, text:gsub("[\128-\255]", ""))
    if multibyte * 5 > #text then
        return false
    end
    local lowered = text:lower()
    if lowered:match("%d%d%d%d%-%d%d%-%d%d") then
        return false
    end
    for _, month in ipairs(MONTHS) do
        if lowered:match("%f[%a]" .. month .. "%s+%d") then
            return false
        end
    end
    if looksLikePath(text) or lowered:match("%.%a%a%a?%f[%A]") then
        return false
    end
    for _, word in ipairs(REJECTED_WORDS) do
        if lowered:match("%f[%a]" .. word .. "%f[%A]") then
            return false
        end
    end
    local sentenceEnds = select(2, text:gsub("[%.!?]%s+%u", ""))
    if sentenceEnds > maxSentenceBreaks then
        return false
    end
    return true
end

-- The full contiguous comment block directly above the key's own line: every consecutive
-- comment-only line upward until a blank line, a non-comment line, or the file start. Joined
-- with single spaces, in reading order (top to bottom). Pure over file content and the entry's
-- byte offset; a separate extractor from Bounds.commentContextFor, which only tracks two
-- preceding lines (enough for its own range mining, not enough to catch a multi-line author
-- paragraph). Exported so it is directly testable without threading a whole scan model through.
function Present.commentBlockFor(content, entryFrom)
    local lineStart = entryFrom
    while lineStart > 1 and content:sub(lineStart - 1, lineStart - 1) ~= "\n" do
        lineStart = lineStart - 1
    end
    local collected = {}
    local cursor = lineStart
    while cursor > 1 do
        local prevEnd = cursor - 1   -- the \n
        local prevStart = prevEnd
        while prevStart > 1 and content:sub(prevStart - 1, prevStart - 1) ~= "\n" do
            prevStart = prevStart - 1
        end
        local line = content:sub(prevStart, prevEnd - 1)
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed == "" then
            break
        end
        local comment = trimmed:match("^%-%-%s*(.*)$") or trimmed:match("^[;#]%s*(.*)$")
        if comment == nil then
            break
        end
        collected[#collected + 1] = comment
        cursor = prevStart
    end
    local block = {}
    for i = #collected, 1, -1 do
        block[#block + 1] = collected[i]
    end
    return table.concat(block, " ")
end

-- The entry's own line, verbatim from its byte offset to end of line (may carry a trailing
-- same-line comment, e.g. "true  -- Skips the confirmation prompt.").
function Present.ownLineFor(content, entryFrom)
    local lineEnd = content:find("\n", entryFrom, true) or (#content + 1)
    return content:sub(entryFrom, lineEnd - 1)
end

-- Rule order: 1. curated override; 2. schema hint (clean); 3. the entry's own-line comment,
-- when clean (one sentence, 140 characters); 4. the full contiguous comment block directly
-- above the key, when it passes the same filter with looser caps (at most 3 sentences, 300
-- characters) - the date/path/dev-note-vocabulary rejections apply identically to both;
-- 5. the community prompt.
function Present.descriptionFor(modName, rawKey, schemaHint, ownLineText, blockText, docSibling,
                               fileRel)
    local override = Present.lookup(Present.overrides.descriptions, modName, rawKey, fileRel)
    if override ~= nil then
        return override
    end
    if type(docSibling) == "string" and isPlayerFacing(docSibling, 300, 2) then
        return docSibling
    end
    -- A framework's `desc` is the description its author WROTE for this setting, not prose mined
    -- out of a comment, so it gets the doc-sibling allowance rather than the strict one-sentence
    -- comment test. PalEggInfo's "Where Ability Glasses are needed to be stored in the Player's
    -- Inventory. 'Any Slot' means literally just carry it around." is two sentences and was
    -- thrown away, leaving a described setting asking players for a description (seen in a real
    -- request file, 2026-09-06).
    if type(schemaHint) == "string" and isPlayerFacing(schemaHint, 300, 2) then
        return schemaHint
    end
    if ownLineText ~= nil then
        local own = commentLines(ownLineText)[1]
        if own ~= nil and own ~= "" and isPlayerFacing(own) then
            return own
        end
    end
    if blockText ~= nil and blockText ~= "" and isPlayerFacing(blockText, 300, 2) then
        return blockText
    end
    return Present.COMMUNITY_PROMPT
end

-- ============================== mod names ==============================

local function ownNameField(mod)
    for _, file in ipairs(mod.files or {}) do
        if file.class == "user" or file.class == "puredata" then
            for _, entry in ipairs(file.entries) do
                if entry.type == "string" and type(entry.value) == "string" and entry.value ~= ""
                    and Scope.lastSegment(entry.key):lower():match("modname$") then
                    return entry.value
                end
            end
        end
    end
    return nil
end

-- Title-cases each whitespace-separated word: the first letter is capitalized, everything else
-- in the word is left exactly as the author wrote it - an all-caps word (an acronym like "HUD")
-- is kept as-is rather than mangled, and any inner capital already present survives untouched.
local function titleCaseWords(text)
    local words = {}
    for word in text:gmatch("%S+") do
        if #word > 1 and word:match("^%u+$") then
            words[#words + 1] = word
        else
            local first, rest = word:match("^(%a)(.*)$")
            if first ~= nil then
                words[#words + 1] = first:upper() .. rest
            else
                words[#words + 1] = word
            end
        end
    end
    return table.concat(words, " ")
end

-- ============================== loader ModName cleanup ==============================

local TRAILING_STRIP_WORDS = { reupload = true, updated = true, fixed = true, working = true }

local function isVersionToken(text)
    return text:match("^[vV]?%d+%.%d+[%d%.]*$") ~= nil
end

-- Drops a leading parenthesized or bare version token: "(0.7) Name" -> "Name", "v1.2 Name" ->
-- "Name". Anything else at the start (including a leading parenthesized non-version group) is
-- left alone - only a version-shaped token is ever stripped.
local function stripLeadingVersion(name)
    local paren, rest = name:match("^%(%s*([vV]?%d[%d%.]*)%s*%)%s*(.*)$")
    if paren ~= nil and isVersionToken(paren) and rest ~= "" then
        return rest
    end
    local bare, rest2 = name:match("^([vV]%d[%d%.]*)%s+(.*)$")
    if bare ~= nil and rest2 ~= "" then
        return rest2
    end
    return name
end

-- Drops trailing parenthesized groups one at a time, as long as each one's text is a reupload/
-- version/status noise word ("reupload", "updated", "fixed", "working", or a bare version
-- number), stopping at the first trailing group that is not: "(0.7) Name (Instant) (reupload)"
-- -> "Name (Instant)", never touching "(Instant)" since it is real title text.
local function stripTrailingNoise(name)
    -- A bare trailing version token too, not only a parenthesized one: "Pal Army 1.8.1" is the
    -- author's title plus its version (audit, 2026-09-03).
    local head, token = name:match("^(.-)%s+([%w%.]+)$")
    if head ~= nil and head ~= "" and isVersionToken(token) then
        name = head
    end
    while true do
        local group
        head, group = name:match("^(.-)%s*%(([^()]*)%)%s*$")
        if head == nil or head == "" then
            break
        end
        local lowered = group:lower()
        if TRAILING_STRIP_WORDS[lowered] or isVersionToken(group) then
            name = head
        else
            break
        end
    end
    return name
end

local function cleanLoaderModName(name)
    if name == nil or name == "" then
        return name
    end
    local cleaned = stripTrailingNoise(stripLeadingVersion(name))
    cleaned = cleaned:match("^%s*(.-)%s*$")
    if cleaned == "" then
        return name
    end
    return cleaned
end

local function loaderModName(folderName, managedModsDir)
    if managedModsDir == nil then
        return nil
    end
    local content = FsUtil.readFile(managedModsDir .. "\\" .. folderName .. "\\Info.json")
    if content == nil then
        return nil
    end
    local entries = ParseJson.parse(content)
    for _, entry in ipairs(entries or {}) do
        if entry.key == "ModName" and type(entry.value) == "string" and entry.value ~= "" then
            return entry.value
        end
    end
    return nil
end

-- A name this UI can show: not mostly another script (the mod list is not localized, so a
-- Chinese or Japanese title reads as nothing to most players), and when the author wrote both
-- ("No Building Limits / 無建築限制") the readable half is kept (audit, 2026-09-03).
local function readableName(name)
    if type(name) ~= "string" then
        return nil
    end
    local function readable(text)
        text = text:match("^%s*(.-)%s*$")
        if text == "" then
            return nil
        end
        local multibyte = select(2, text:gsub("[\128-\255]", ""))
        return multibyte * 5 <= #text and text or nil
    end
    local whole = readable(name)
    if whole ~= nil then
        return whole
    end
    for half in name:gmatch("[^/]+") do
        local part = readable(half)
        if part ~= nil then
            return part
        end
    end
    return nil
end

-- The loader's published ModName outranks a name field inside a script: the loader record is
-- the author's own package title, while a `modName` in code is usually a log prefix, and on this
-- install three of them were worse (a trailing " - ", a dropped "(Instant)", a shortened title).
function Present.modDisplayName(mod, managedModsDir)
    local override = Present.lookup(Present.overrides.mods, mod.name, nil)
    if override ~= nil then
        return override
    end
    if type(mod.schemaTitle) == "string" and mod.schemaTitle ~= "" then
        local schema = readableName(mod.schemaTitle)
        if schema ~= nil then
            return schema
        end
    end
    local loader = readableName(loaderModName(mod.name, managedModsDir))
    if loader ~= nil then
        return cleanLoaderModName(loader)
    end
    local own = readableName(ownNameField(mod))
    if own ~= nil then
        return cleanLoaderModName(titleCaseWords(own))
    end
    return table.concat(splitWords(mod.name), " ")
end

-- ============================== decorate ==============================

-- The Workshop item id the loader recorded for this mod's package, from its install manifest;
-- nil for a mod that did not arrive through the loader (Nexus, hand-installed).
function Present.workshopIdFor(folderName, managedModsDir)
    if managedModsDir == nil or folderName == nil then
        return nil
    end
    local content = FsUtil.readFile(managedModsDir .. "\\" .. folderName .. "\\InstallManifest.json")
    if content == nil then
        return nil
    end
    local id = content:match('"WorkshopId"%s*:%s*(%d+)')
    return id ~= nil and tonumber(id) or nil
end

function Present.decorate(model, managedModsDir)
    for _, mod in ipairs(model.mods) do
        mod.displayName = Present.modDisplayName(mod, managedModsDir)
        mod.workshopId = Present.workshopIdFor(mod.name, managedModsDir)
        for _, file in ipairs(mod.files) do
            Present.applyDocSiblings(file)
            local keys = {}
            local groupSet = {}
            local groupCount = 0
            for _, entry in ipairs(file.entries) do
                keys[#keys + 1] = entry.key
                local group = entry.key:match("^(.*)%.[^%.]+$")
                if group ~= nil and not groupSet[group] then
                    groupSet[group] = true
                    groupCount = groupCount + 1
                end
            end
            local stripped = Present.stripPrefixes(keys)
            for _, entry in ipairs(file.entries) do
                local isHotkey = entry.rowKind == "keyCombo"
                entry.strippedKey = stripped[entry.key]
                entry.label = Present.labelFor(mod.name, entry.key, entry.strippedKey, isHotkey,
                    entry.schema and entry.schema.label or nil)
                local ownLineText, blockText = nil, nil
                if file.content ~= nil then
                    ownLineText = Present.ownLineFor(file.content, entry.from)
                    blockText = Present.commentBlockFor(file.content, entry.from)
                end
                entry.tooltip = Present.descriptionFor(mod.name, entry.key,
                    entry.schema and entry.schema.hint or nil, ownLineText, blockText,
                    entry.docSibling, file.rel)
                -- A setting a player cannot usefully change (a version string, a display name
                -- the mod only prints, an internal identifier its code looks up by name) is
                -- not shown at all, in either mode: showing an editable control that achieves
                -- nothing is a dead control. The catalog's `hidden` table names them, its value
                -- being the reason, so the list is auditable.
                -- A `__name` key is a format stamp by convention in every language that has the
                -- convention: the file's own version, not a setting (audit, 2026-09-03: a save
                -- file's `__version`, which a player edit makes the mod reject).
                local segment = Scope.lastSegment(entry.key)
                -- JSON has no comment syntax, so authors write their notes as a string key with
                -- one leading underscore (`_help`, `_comment`, `_note`): prose about the file,
                -- never a setting (audit, 2026-09-03: BaseRadiusImproved's `_help` rendered as
                -- an editable text box holding a paragraph). Only string values, so a numeric
                -- `_version` stays judged by the `__` rule above it.
                entry.hidden = Present.lookup(Present.overrides.hidden, mod.name, entry.key) ~= nil
                    or entry.internal == true
                    or segment:sub(1, 2) == "__"
                    or (segment:sub(1, 1) == "_" and entry.type == "string")
                entry.undescribed = entry.tooltip == Present.COMMUNITY_PROMPT
                if entry.undescribed then
                    entry.tooltip = I18n.t("no_description")
                elseif Present.lookup(Present.overrides.descriptions, mod.name, entry.key,
                    file.rel) ~= nil then
                    -- The translation is looked up under whichever key carried the description:
                    -- a file-scoped entry has its own, and without this the scoped description
                    -- would always show in English.
                    local leaf = tostring(file.rel or ""):match("([^\\/]+)$")
                    local scopedKey = leaf ~= nil
                        and ("d:" .. mod.name .. "." .. leaf .. ":" .. entry.key) or nil
                    entry.tooltip = (scopedKey ~= nil and I18n.lookup(scopedKey) or nil)
                        or I18n.lookup("d:" .. mod.name .. "." .. entry.key)
                        or entry.tooltip
                end
                entry.group = groupOf(entry.key, groupCount)
            end
        end
    end
end

-- Whether a mod re-reads its own config while the game runs, so an edit needs no relaunch.
--
-- Read from the mod's own settings rather than a list of known mods: any author who ships an
-- interval named like "liveReloadSeconds" (in any of the usual spellings) gets this for free, and
-- nothing here depends on a mod knowing that this one exists. A zero interval means the author
-- turned the watching off, so it is not live.
local LIVE_RELOAD_KEYS = {
    livereloadseconds = true, livereload = true, configreloadseconds = true,
    autoreloadseconds = true, reloadintervalseconds = true, settingsreloadseconds = true,
}

function Present.reloadsLive(mod)
    if type(mod) ~= "table" then
        return false
    end
    for _, file in ipairs(mod.files or {}) do
        for _, entry in ipairs(file.entries or {}) do
            local key = tostring(entry.key or ""):gsub("^.*%.", ""):gsub("[_%s%-]", ""):lower()
            if LIVE_RELOAD_KEYS[key] then
                local seconds = tonumber(entry.value)
                if seconds ~= nil and seconds > 0 then
                    return true
                end
                if type(entry.value) == "boolean" and entry.value then
                    return true
                end
            end
        end
    end
    return false
end

-- Whether we are CERTAIN a mod needs the whole game restarted before its change takes effect.
-- Only a curated catalog entry can say so: when in doubt, assume unloading and loading back
-- into a world or server is enough, because that is what a mod actually does most of the time
-- and claiming otherwise costs the player a relaunch they never needed. A Mod Config Menu
-- consumer is the proven case of the default being right: BPModLoader starts its actor on every
-- map load, and a change made at the title screen took effect on entering the world while one
-- made IN the world did not until reloading it.
function Present.requiresGameRestart(mod)
    if type(mod) ~= "table" then
        return false
    end
    return Present.restartRequiredByName(mod.name)
end

-- The same question by name, for a pending set that carries mod names rather than mod tables.
function Present.restartRequiredByName(modName)
    if type(modName) ~= "string" then
        return false
    end
    return Present.lookup(Present.overrides.restart, modName, nil) ~= nil
end

-- True when any name in `modNames` is one the catalog records as needing a relaunch. This is the
-- one question that decides whether leaving the screen prompts at all: everything else saves
-- quietly, because reloading into a world is the default promise.
function Present.anyRequiresGameRestart(modNames)
    if type(modNames) ~= "table" then
        return false
    end
    for _, name in ipairs(modNames) do
        if Present.restartRequiredByName(name) then
            return true
        end
    end
    return false
end


function Present.allReloadLive(mods)
    if type(mods) ~= "table" or #mods == 0 then
        return false
    end
    for _, mod in ipairs(mods) do
        if not Present.reloadsLive(mod) then
            return false
        end
    end
    return true
end

-- A JSON or INI config often documents a setting in a sibling key named with a leading
-- underscore: "_maxRadius" is prose about "maxRadius", not a setting of its own. Reading it gives
-- the author's own words as the description, and drops an entry no player should ever be offered.
-- Keys that document nothing in particular ("_help") and schema markers ("configVersion") are
-- bookkeeping, so they go too. Found on BaseRadiusImproved (2026-09-05), which is any author's
-- file, not ours: nothing here is specific to a mod.
local SCHEMA_KEYS = { configversion = true, schemaversion = true, formatversion = true }

function Present.applyDocSiblings(file)
    if type(file) ~= "table" or type(file.entries) ~= "table" then
        return file
    end
    local byKey = {}
    for _, entry in ipairs(file.entries) do
        byKey[entry.key] = entry
    end


    -- Marked, never removed: the writer still needs every parsed entry to splice a file back
    -- together, and the panel and the request list already skip a hidden entry.
    for _, entry in ipairs(file.entries) do
        local segment = Scope.lastSegment(entry.key)
        if segment:sub(1, 1) == "_" and #segment > 1 then
            local prefix = tostring(entry.key):match("^(.*%.)[^%.]+$") or ""
            local documented = byKey[prefix .. segment:sub(2)]
            if documented ~= nil and type(entry.value) == "string" then
                documented.docSibling = entry.value
            end
            entry.internal = true
        elseif SCHEMA_KEYS[segment:lower()] == true then
            entry.internal = true
        elseif Present.carriesOwnerId(entry.key) then
            -- An id embedded in the key means one player's own row: no catalog line could ever
            -- match it, so it is never worth requesting. It stays editable, because a per-world
            -- or per-server block keyed by id is a real settings shape and hiding it would take
            -- those settings away from the player.
            entry.perPlayerData = true
        end
    end
    return file
end

-- How to find this mod's page, for whoever answers a description request.
--
-- Palworld mods come from at least three places: the Steam Workshop, Nexus Mods and CurseForge.
-- Only a mod the official loader installed leaves a Workshop id behind, so the absence of one
-- says the mod came from somewhere else, not that its id is missing. Saying "Workshop id unknown"
-- sent the reader to the one site the mod provably is not on (user request file, 2026-09-06).
function Present.sourceLabel(mod)
    if type(mod) == "table" and mod.workshopId ~= nil then
        return "Steam Workshop " .. tostring(mod.workshopId)
    end
    return "not installed from the Steam Workshop; search Nexus Mods and CurseForge by name"
end

return Present
