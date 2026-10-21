-- Derives slider bounds for a numeric config entry from the strongest evidence available, in
-- this order:
--
--   1. A range in the config file's own comments next to the key ("0-100", "0.0 to 1.0",
--      "between 1 and 50", "max 100", "min 0").
--   2. The owning mod's code: clamp/min/max calls and comparisons that use the key
--      (math.min(x, N), math.max(N, x), clamp(x, A, B), `if x > N`, `x <= N`...).
--   3. The key's name: percent/percentage, chance/opacity/alpha, multiplier/scale, seconds/
--      delay/cooldown, angle/degrees, count/limit/slots families.
--   4. The current value's magnitude (the original heuristic).
--
-- Every derived range is sanity-gated: it must contain the current value (a "range" that does
-- not is a false hit - a date, a version, an unrelated number) and be non-degenerate; otherwise
-- the next strategy is tried. The final range is always widened to include the current value.
local FsUtil = require("fsutil")

local Bounds = {}

-- ============================== helpers ==============================

local function isIntegerish(value)
    return math.type(value) == "integer" or value == math.floor(value)
end

-- Whether the author WROTE this number as a decimal. `1.0` and `1` are the same Lua number, so
-- value alone cannot tell a continuous setting from a counter, and treating every whole-looking
-- value as an integer gave a scale of 1.0 a step of 1 while its 0.75 sibling stepped by 0.05
-- (audit, 2026-09-03: AntiPhat's scales, PalInsight's opacity and color channels). The literal
-- the parser spanned is the evidence.
local function literalIsFloat(fileContent, entry)
    if fileContent == nil or entry == nil or entry.from == nil or entry.to == nil then
        return not isIntegerish(entry and entry.value or 0)
    end
    local literal = fileContent:sub(entry.from, entry.to)
    return literal:find("%.") ~= nil or literal:find("[eE]") ~= nil
end

-- Round numbers, 1, 2 or 5 times a power of ten, from `first` down to `last`, largest first.
-- Every step a bar is given comes from this ladder, so a player always drags between numbers
-- they would have typed.
local function roundSteps(first, last)
    local steps = {}
    if first <= 0 or last <= 0 or last > first then
        return steps
    end
    local exponent = math.floor(math.log(first, 10) + 1e-12)
    while 10 ^ exponent >= last * (1 - 1e-9) do
        for _, mantissa in ipairs({ 5, 2, 1 }) do
            local step = mantissa * 10 ^ exponent
            if step <= first * (1 + 1e-9) and step >= last * (1 - 1e-9) then
                steps[#steps + 1] = step
            end
        end
        exponent = exponent - 1
    end
    return steps
end

-- Rounds a derived ceiling UP to at most two significant digits, so a bar tops out at a number
-- a player recognizes: 4 x 999999 was showing 3999996 as a maximum (audit, 2026-09-03). Only
-- derived tops go through this; a number an author stated is never rounded.
local function roundTop(top)
    if top <= 0 then
        return top
    end
    local scale = 10 ^ (math.floor(math.log(top, 10) + 1e-12) - 1)
    if scale <= 0 then
        return top
    end
    return math.ceil(top / scale - 1e-9) * scale
end

-- The step the bar would like before `gridStep` refines it: a round number giving roughly fifty
-- stops across the span, never finer than the format can express. The old version returned 0 for
-- any fractional range whose midpoint had no fractional part, which alone left 56 of 390 live
-- sliders continuous (audit, 2026-09-03).
local function stepFor(minValue, maxValue, integer)
    local span = maxValue - minValue
    if span <= 0 then
        return 0
    end
    local smallest = integer and 1 or 0.001
    -- A fractional bar two units wide or less keeps the twentieth it has always used: finer than
    -- that reads as continuous on a bar this short.
    local target = (not integer and span <= 2) and (span / 20) or (span / 50)
    if target < smallest then
        target = smallest
    end
    return roundSteps(target, smallest)[1] or smallest
end

-- The most stops a bar may carry. Generous on purpose: a crowded grid still lets a player land
-- on round numbers, and the value beside the bar is typed as well as dragged, while a step of 0
-- lets them land on nothing at all.
local MAX_STOPS = 20000

local function divides(distance, step)
    local units = distance / step
    return math.abs(units - math.floor(units + 0.5)) < 1e-6
end

-- Puts the CURRENT value on the grid without moving either end of the range: the largest round
-- step at or below `preferred` that divides (value - min) exactly. A bar whose step skips its own
-- value can never be returned to it, and the old repair (drop the step to 0) left a continuous
-- bar on which no round number can be landed either. Zero is still the answer when nothing
-- divides the distance, such as a color channel holding 0.3813260198.
local function gridStep(minValue, maxValue, value, integer, preferred)
    if preferred <= 0 then
        return 0
    end
    local distance = value - minValue
    if math.abs(distance) < 1e-12 or divides(distance, preferred) then
        return preferred
    end
    for _, step in ipairs(roundSteps(preferred, integer and 1 or 0.001)) do
        if divides(distance, step) and (maxValue - minValue) / step <= MAX_STOPS then
            return step
        end
    end
    return 0
end

local function sane(minValue, maxValue, value)
    return minValue ~= nil and maxValue ~= nil and minValue < maxValue
        and value >= minValue and value <= maxValue
end

-- `integer` is the caller's reading of the literal (literalIsFloat); nil falls back to the
-- value's own shape. Both ends of the range stay where the evidence put them, floor included,
-- and the STEP is what moves so the CURRENT value lands on the grid: a bar whose step skips its
-- own value can never be returned to it (audit, 2026-09-03: fourteen settings, including a 10000
-- gold default on a step of 10,000,000). The version before this one shifted the origin instead,
-- by an offset with the wrong sign, behind a guard no range could satisfy - so every one of those
-- fourteen, and 116 of 390 live sliders, ended with no step at all.
local function finish(minValue, maxValue, value, source, integer, forcedStep)
    if minValue > value then
        minValue = value
    end
    if maxValue < value then
        maxValue = value
    end
    if integer == nil then
        integer = isIntegerish(value)
    end
    if integer then
        minValue = math.floor(minValue)
        maxValue = math.ceil(maxValue)
    end
    local preferred = forcedStep or stepFor(minValue, maxValue, integer)
    local step = gridStep(minValue, maxValue, value, integer, preferred)
    return minValue, maxValue, step, source
end

-- ============================== 1. comment mining ==============================

-- The comment text around one entry: the remainder of its own line plus up to two immediately
-- preceding comment-only lines.
local function commentContext(content, entryFrom)
    local lineStart = entryFrom
    while lineStart > 1 and content:sub(lineStart - 1, lineStart - 1) ~= "\n" do
        lineStart = lineStart - 1
    end
    local lineEnd = content:find("\n", entryFrom, true) or (#content + 1)
    local pieces = { content:sub(entryFrom, lineEnd - 1) }
    local cursor = lineStart
    -- The WHOLE contiguous comment block above the entry, not a fixed two lines: an author's
    -- stated range often sits three or four lines up, under a heading (audit, 2026-09-03:
    -- AntiWaste's "0.1 to 1.0" and PalInsight's "Safe ranges: X -60..400, Y -300..20" were both
    -- missed by one line). The sanity gate still discards a number that is not a real range.
    while true do
        if cursor <= 1 then
            break
        end
        local prevEnd = cursor - 1   -- the \n
        local prevStart = prevEnd
        while prevStart > 1 and content:sub(prevStart - 1, prevStart - 1) ~= "\n" do
            prevStart = prevStart - 1
        end
        local line = content:sub(prevStart, prevEnd - 1)
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:match("^%-%-") or trimmed:match("^[;#]") then
            pieces[#pieces + 1] = trimmed
            cursor = prevStart
        else
            break
        end
    end
    return table.concat(pieces, "\n")
end

local NUMBER = "%-?%d+%.?%d*"

-- Exported for rowspec.lua, which turns the same comment context into row descriptions and
-- enum choice lists.
function Bounds.commentContextFor(content, entryFrom)
    return commentContext(content, entryFrom)
end

-- Extracts an explicit range from comment text. Patterns are deliberately narrow; the sanity
-- gate discards false hits.
local function rangeFromComment(text, value)
    if text == nil or text == "" then
        return nil
    end
    for _, pattern in ipairs({
        "%(%s*(" .. NUMBER .. ")%s*%-%s*(" .. NUMBER .. ")%s*%)",       -- (0 - 100)
        "(" .. NUMBER .. ")%s*%-%s*(" .. NUMBER .. ")",                 -- 0-100
        "(" .. NUMBER .. ")%s+to%s+(" .. NUMBER .. ")",                 -- 0 to 100
        "(" .. NUMBER .. ")%s*%.%.%s*(" .. NUMBER .. ")",               -- 0..100
        "[Bb]etween%s+(" .. NUMBER .. ")%s+and%s+(" .. NUMBER .. ")",   -- between 0 and 100
    }) do
        for first, second in text:gmatch(pattern) do
            local low, high = tonumber(first), tonumber(second)
            if sane(low, high, value) then
                return low, high
            end
            -- Zero below a documented range is the common "off" sentinel written on its own
            -- line ("0 = durability-scaled, 0.1 to 1.0 = fixed percentage"): keep the stated
            -- ceiling and let the range start at the value (audit, 2026-09-03).
            if value == 0 and low ~= nil and low > 0 and high ~= nil and high > low then
                return 0, high
            end
        end
    end
    -- A stated set of legal numbers ("Supported values: 8, 12, or 16"): its own smallest and
    -- largest are the range, so the slider cannot leave the set's span (audit, 2026-09-03).
    local listed = text:match("[Ss]upported values:?%s*([%d%s,or]+)")
        or text:match("[Ll]egal values:?%s*([%d%s,or]+)")
    if listed ~= nil then
        local numbers = {}
        for number in listed:gmatch("%d+%.?%d*") do
            numbers[#numbers + 1] = tonumber(number)
        end
        if #numbers >= 2 then
            table.sort(numbers)
            if sane(numbers[1], numbers[#numbers], value) then
                return numbers[1], numbers[#numbers]
            end
        end
    end
    -- Half-open hints: "max N" / "up to N" / "min N". The other end comes from zero or the value.
    local high = tonumber(text:match("[Mm]ax[imum]*%s*:?%s*(" .. NUMBER .. ")"))
        or tonumber(text:match("[Uu]p%s+to%s+(" .. NUMBER .. ")"))
    local low = tonumber(text:match("[Mm]in[imum]*%s*:?%s*(" .. NUMBER .. ")"))
    if high ~= nil and low == nil then
        low = math.min(0, value)
    end
    if low ~= nil and high == nil and high ~= low then
        high = math.max(value * 4, low + 10)
    end
    if sane(low, high, value) then
        return low, high
    end
    return nil
end

-- ============================== 2. code mining ==============================

-- The spellings a config key may wear in code: an INI's `SummonLimit` is read into
-- `config.summon_limit`, a Lua module's `pollSeconds` stays as-is. All lowercase, because the
-- mining below runs on a lowercased copy of the code.
local function nameVariants(segment)
    local variants = {}
    local seen = {}
    local function add(name)
        if name ~= nil and #name >= 3 and not seen[name] then
            seen[name] = true
            variants[#variants + 1] = name
        end
    end
    add(segment:lower())
    add(segment:gsub("(%l)(%u)", "%1_%2"):lower())   -- CamelCase -> camel_case
    add(segment:gsub("_", ""):lower())               -- snake_case -> snakecase
    return variants
end

-- A Lua pattern matching `word` in any case, so a literal can be read from the ORIGINAL source
-- (which preserves the author's spelling) while positions are found on a lowercased copy.
-- Punctuation is escaped FIRST, then letters become classes: doing it the other way round made
-- the gsub escape the very brackets it had just inserted, so every case-insensitive search
-- silently matched nothing (audit follow-up, 2026-09-03).
local function ciPattern(word)
    return (word:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"):gsub("%a", function(letter)
        return "[" .. letter:lower() .. letter:upper() .. "]"
    end))
end

-- True when the character is not part of an identifier (so a hit is a whole word, not a
-- substring of a longer name).
local function boundary(text, index)
    if index < 1 or index > #text then
        return true
    end
    return text:sub(index, index):match("[%w_]") == nil
end

-- ============================== the per-mod code index ==============================

-- Every rung below read the mod's whole concatenated source ONCE PER SETTING, and PalInsight's
-- is 2.8 MB, so opening its page pattern-matched over a third of a gigabyte and took 2.3 seconds
-- (measured on a real install, 2026-09-05). The blob therefore carries an index: the
-- lowercased copy the mining runs on, where each identifier ASKED ABOUT is mentioned, the quotes
-- a declaration can hang its key off, and the table literals a choice list can come from. Each
-- part is ONE pass over the blob, built the first time a rung asks for it - so a mod pays only
-- for the rungs its own settings reach - and each part dies with the blob in Bounds.resetCache.
--
-- The index is an accelerator, never a second opinion: every lookup below returns exactly the
-- hits the scan it replaces returned, in the same order. Where a shape cannot be indexed (a key
-- that does not end in three identifier characters), the original scan still runs.
local codeCache = {}
local indexByCode = {}

function Bounds.resetCache()
    codeCache = {}
    indexByCode = {}
end

-- Lua's own idea of an identifier character, taken from the pattern class rather than an ASCII
-- range, so the index and the `[%w_]` patterns it stands beside can never disagree.
local WORD_BYTE = {}
for byte = 0, 255 do
    WORD_BYTE[byte] = string.char(byte):match("[%w_]") ~= nil
end

local function indexFor(codeText)
    if codeText == nil or codeText == "" then
        return nil
    end
    local index = indexByCode[codeText]
    if index == nil then
        index = { code = codeText }
        indexByCode[codeText] = index
    end
    return index
end

-- string.lower keeps byte length, so an offset found here addresses the same character in the
-- original: that is what lets the miners read an author's own spelling out of `index.code` at a
-- position found in the lowercased copy.
local function loweredCode(index)
    local lowered = index.lowered
    if lowered == nil then
        lowered = index.code:lower()
        index.lowered = lowered
    end
    return lowered
end

-- The offsets at which one identifier appears as a whole word, ascending: exactly the hits the
-- plain-find loop with a boundary test on both sides used to walk the blob for, kept the first
-- time an identifier is asked about. Four rungs ask about the same key (a numeric range, an
-- enum, a format clue, the literals compared against it) and several settings of one mod share a
-- leaf name, so the blob is walked once per NAME rather than once per rung per setting.
--
-- Indexing every identifier in the blob up front was measured against this and lost: the one
-- pass that builds it costs more than the walks it saves (841 ms against 677 ms across the
-- whole of a real install, 2026-09-05) and it held 30 MB of offsets nothing asked for.
local function wholeWordHits(index, variant)
    local mentions = index.mentions
    if mentions == nil then
        mentions = {}
        index.mentions = mentions
    end
    local hits = mentions[variant]
    if hits ~= nil then
        return hits
    end
    hits = {}
    local lowered = loweredCode(index)
    local from = 1
    while true do
        local hitFrom, hitTo = lowered:find(variant, from, true)
        if hitFrom == nil then
            break
        end
        from = hitTo + 1
        if boundary(lowered, hitFrom - 1) and boundary(lowered, hitTo + 1) then
            hits[#hits + 1] = hitFrom
        end
    end
    mentions[variant] = hits
    return hits
end

-- Every place a declaration can name its key: a `"` with the key's own last character just
-- before it, or just before a `.` before it (the dotted-path spelling `path = key .. ".Scales."`).
-- declaredNear's needle ends at that quote and puts no boundary in front of the key, so the
-- text before the quote is the whole candidate set, and the three characters ending it are the
-- three any key of three characters or more must end with. Bucketing the quotes by those three
-- turns a pattern scan of the whole blob, per setting, into a walk of a few dozen positions.
local function declaredQuoteSites(index)
    local sites = index.quoted
    if sites ~= nil then
        return sites
    end
    sites = {}
    local lowered = loweredCode(index)
    local at = 0
    while true do
        at = lowered:find("\"", at + 1, true)
        if at == nil then
            break
        end
        local last = at - 1
        if lowered:byte(last) == 46 then
            last = last - 1
        end
        -- Three identifier characters, because a key is at least three long and every character
        -- of one is an identifier character. It skips the OPENING quote of every string literal,
        -- which is most of them.
        if last >= 3 and WORD_BYTE[lowered:byte(last)] and WORD_BYTE[lowered:byte(last - 1)]
            and WORD_BYTE[lowered:byte(last - 2)] then
            local ending = lowered:sub(last - 2, last)
            local bucket = sites[ending]
            if bucket == nil then
                bucket = {}
                sites[ending] = bucket
            end
            bucket[#bucket + 1] = at
        end
    end
    index.quoted = sites
    return sites
end

-- Every `name = {` in the blob, in source order, with the keys of each literal filled in the
-- first time that literal is asked for. choicesFromTableKeys walked the whole blob for these
-- once per string setting, at 110 ms a walk.
local function tableSites(index)
    local sites = index.tables
    if sites ~= nil then
        return sites
    end
    sites = {}
    local code = index.code
    local from = 1
    while true do
        local nameFrom, nameTo, name = code:find("%f[%w_]([%a_][%w_]*)%s*=%s*{", from)
        if nameFrom == nil then
            break
        end
        from = nameTo + 1
        sites[#sites + 1] = { name = name:lower(), openAt = nameTo }
    end
    index.tables = sites
    return sites
end

-- Mines the mod's code for clamps, min/max calls, and comparisons that use the key, working on
-- whitespace-flattened windows around each occurrence so multi-line idioms like
-- `x = math.max(0, math.min(100, ...))` are seen whole. Runs on a lowercased copy: an INI key's
-- casing rarely matches the code's.
local function rangeFromCode(index, key, value)
    if index == nil or index.code == "" then
        return nil
    end
    local segment = key:match("[^%.]+$")
    if segment == nil or #segment < 3 then
        return nil
    end
    local lowered = loweredCode(index)
    local lows, highs = {}, {}
    local function consider(kind, number)
        local n = tonumber(number)
        if n ~= nil then
            if kind == "low" then
                lows[#lows + 1] = n
            else
                highs[#highs + 1] = n
            end
        end
    end
    for _, variant in ipairs(nameVariants(segment)) do
        local escaped = variant:gsub("([%W])", "%%%1")
        for _, hitFrom in ipairs(wholeWordHits(index, variant)) do
            local hitTo = hitFrom + #variant - 1
            -- Window: enough behind for `clamp(` / `math.min(N,`, enough ahead for the
            -- assignment idiom whose max/min calls FOLLOW the identifier.
            local window = lowered:sub(math.max(1, hitFrom - 160), hitTo + 280)
                :gsub("%s+", " ")
            -- x = math.max(A, math.min(B, ...)) and the mirrored form.
            for low, high in window:gmatch(escaped .. "%s*=%s*math%.max%s*%(%s*("
                .. NUMBER .. ")%s*,%s*math%.min%s*%(%s*(" .. NUMBER .. ")") do
                consider("low", low)
                consider("high", high)
            end
            for high, low in window:gmatch(escaped .. "%s*=%s*math%.min%s*%(%s*("
                .. NUMBER .. ")%s*,%s*math%.max%s*%(%s*(" .. NUMBER .. ")") do
                consider("low", low)
                consider("high", high)
            end
            -- clamp(x, A, B), with the key anywhere in the first argument.
            for low, high in window:gmatch("clamp%s*%(%s*[%w_%.%[%]\"']*" .. escaped
                .. "[%w_%.%[%]\"']*%s*,%s*(" .. NUMBER .. ")%s*,%s*("
                .. NUMBER .. ")") do
                consider("low", low)
                consider("high", high)
            end
            -- math.min(x, N) / math.min(N, x): N is a ceiling. math.max: a floor.
            for n in window:gmatch("math%.min%s*%([^,%)]*" .. escaped .. "[^,%)]*,%s*("
                .. NUMBER .. ")%s*%)") do
                consider("high", n)
            end
            for n in window:gmatch("math%.min%s*%(%s*(" .. NUMBER .. ")%s*,[^%)]*"
                .. escaped) do
                consider("high", n)
            end
            for n in window:gmatch("math%.max%s*%([^,%)]*" .. escaped .. "[^,%)]*,%s*("
                .. NUMBER .. ")%s*%)") do
                consider("low", n)
            end
            for n in window:gmatch("math%.max%s*%(%s*(" .. NUMBER .. ")%s*,[^%)]*"
                .. escaped) do
                consider("low", n)
            end
            -- Comparisons: whether N is a floor or a ceiling depends on the idiom (a guard
            -- `if x > N then x = N` makes N the max; a validation `x >= N` makes N the
            -- min), which the operator alone cannot disambiguate. N's position relative to
            -- the current value decides: at or above the value it is a ceiling candidate,
            -- below it a floor candidate.
            for _, n in window:gmatch(escaped .. "%s*([<>]=?)%s*(" .. NUMBER .. ")") do
                consider(tonumber(n) ~= nil and tonumber(n) >= value and "high" or "low", n)
            end
            for n in window:gmatch("(" .. NUMBER .. ")%s*[<>]=?%s*[%w_%.]*" .. escaped) do
                consider(tonumber(n) ~= nil and tonumber(n) >= value and "high" or "low", n)
            end
        end
    end
    if #highs == 0 then
        return nil
    end
    local high = math.max(table.unpack(highs))
    local low = #lows > 0 and math.min(table.unpack(lows)) or math.min(0, value)
    if sane(low, high, value) then
        return low, high
    end
    return nil
end

-- ============================== 3. name semantics ==============================

-- The LAST dotted segment, split at camel humps and separators, matched on whole words. The
-- first version lowercased the whole dotted key and matched substrings, so
-- `MassOperations.BatchSize` matched "ratio" inside "massope-ratio-ns" and got a 0..1 slider on
-- a setting the mod clamps to 1..100 (audit, 2026-09-03).
local function nameWords(key)
    local segment = key:match("[^%.]+$") or key
    return " " .. segment:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
        :gsub("[_%-]", " "):lower() .. " "
end

local function hasWord(words, ...)
    for _, word in ipairs({ ... }) do
        if words:find("%f[%a]" .. word .. "s?%f[%A]") then
            return true
        end
    end
    return false
end

local function rangeFromName(key, value)
    local words = nameWords(key)
    local parent = (key:match("^(.*)%.[^%.]+$") or ""):lower()
    local function has(...)
        return hasWord(words, ...)
    end
    -- A single-letter channel under a color or tint parent is 0..1 linear light, never 0..10
    -- (audit: four sliders of one RGBA color derived four different ranges).
    -- "alpha" needs the same color parent the single letters do: on its own it is Palworld's own
    -- word for a boss pal, and a count of defeated Alphas was drawing a two-stop 0..1 bar
    -- (audit, 2026-09-03: HUDLocator.defeatedAlphas, PalBoxQoL.alphaIndex).
    if parent:find("color", 1, true) or parent:find("tint", 1, true) then
        if words:match("^ [rgba] $") or has("red", "green", "blue", "alpha") then
            if value >= 0 and value <= 1 then
                return 0, 1
            end
        end
    end
    -- An offset, nudge or delta moves in both directions; a range starting at 0 makes half of
    -- the setting unreachable (audit: eleven of them across five mods).
    if has("offset", "nudge", "delta", "shift") then
        local reach = roundTop(math.max(math.abs(value) * 2, 100))
        return -reach, reach
    end
    if has("percent", "percentage") then
        if value >= 0 and value <= 100 then
            return 0, 100
        end
    end
    if has("chance", "probability", "opacity", "ratio") then
        if value >= 0 and value <= 1 then
            return 0, 1
        end
        if value >= 0 and value <= 100 then
            return 0, 100
        end
    end
    if has("angle", "degrees", "rotation") then
        if value >= 0 and value <= 360 then
            return 0, 360
        end
    end
    if has("multiplier", "scale", "factor", "speed") then
        if value > 0 then
            return 0, roundTop(math.max(value * 4, 10))
        end
    end
    -- No constant floor under a time: a minute-wide bar put a half-second default 0.8% along it
    -- (audit, 2026-09-03: NoDecayFeedBag, GoToBedTeleportEdition, NoBuildingLimits100). Four
    -- times the default reads the same at every scale; a default of zero has no scale of its own,
    -- so it keeps a plain ten-unit bar.
    if has("seconds", "delay", "interval", "cooldown", "duration", "timeout") then
        if value > 0 then
            return 0, roundTop(value * 4)
        end
        if value == 0 then
            return 0, 10
        end
    end
    if has("milliseconds", "millis") then
        if value > 0 then
            return 0, roundTop(value * 4)
        end
        if value == 0 then
            return 0, 1000
        end
    end
    if has("slots", "count", "limit", "level", "amount", "size", "quantity", "stack") then
        if value >= 0 and isIntegerish(value) then
            return 0, roundTop(math.max(value * 4, 10))
        end
    end
    return nil
end

-- ============================== 4. value fallback ==============================

local function rangeFromValue(value)
    if value == 0 then
        return 0, 10
    end
    local magnitude = math.abs(value)
    if not isIntegerish(value) and magnitude <= 1 then
        return value < 0 and -1 or 0, 1
    end
    local top = magnitude * 4
    if isIntegerish(value) and top < 10 then
        top = 10
    end
    top = roundTop(top)
    return value < 0 and -top or 0, top
end

-- ============================== entry point ==============================

-- Per-mod code index over the concatenation of every .lua file in the mod folder except the
-- config file itself. The file inventory comes from the scan model (`allFiles`), never from a
-- fresh directory listing: the shell listing fallback flashes a console window per call. Read
-- once per mod per session, so a page open reads no code at all after the first.
local function modIndex(modDir, configPath, allFiles)
    local cached = codeCache[modDir]
    if cached ~= nil then
        return cached
    end
    local pieces = {}
    local files = allFiles or FsUtil.listFilesRecursive(modDir) or {}
    for _, path in ipairs(files) do
        if path:lower():match("%.lua$") and path ~= configPath then
            local content = FsUtil.readFile(path)
            -- Code mining is line-based; a very large file is truncated rather than skipped.
            if content ~= nil then
                -- 4 MiB, not 256 KiB: PalInsight's main.lua is 2.4 MB, so the old cap threw
                -- away 89% of the one file whose comparisons the miner most needs (audit,
                -- 2026-09-03).
                pieces[#pieces + 1] = #content > 4194304 and content:sub(1, 4194304) or content
            end
        end
    end
    local index = indexFor(table.concat(pieces, "\n")) or { code = "" }
    codeCache[modDir] = index
    return index
end

-- ============================== string enum mining ==============================

-- Collects the string literals compared for equality against the key anywhere in the mod's own
-- code (`if SizeMode == "mesh" then ... elseif SizeMode == "sprite" then ...`), the same
-- evidence-based approach as the numeric range mining above. Only trusted when the entry's
-- current value is one of the collected literals and at least one other literal was found
-- alongside it: a real enum, never a single re-confirmation of the value itself, and never a
-- guess at values the mod's own code does not demonstrably compare against.
local function choicesFromCode(index, key, value)
    if index == nil or index.code == "" then
        return nil
    end
    local codeText = index.code
    local segment = key:match("[^%.]+$")
    if segment == nil or #segment < 3 then
        return nil
    end
    local seen, ordered = {}, {}
    local function add(token)
        if not seen[token] then
            seen[token] = true
            ordered[#ordered + 1] = token
        end
    end
    for _, variant in ipairs(nameVariants(segment)) do
        local insensitive = ciPattern(variant)
        for _, hitFrom in ipairs(wholeWordHits(index, variant)) do
            local hitTo = hitFrom + #variant - 1
            -- Positions come from the lowercased copy, but the literal is read from the
            -- ORIGINAL window with a case-insensitive identifier pattern: a mod comparing
            -- against "Shortcut" was offered "shortcut", which it rejects on load (audit,
            -- 2026-09-03). string.lower keeps byte length, so the offsets line up.
            local window = codeText:sub(math.max(1, hitFrom - 40), hitTo + 200)
            for token in window:gmatch(insensitive .. "%s*==%s*[\"']([%w_%-%.]+)[\"']") do
                add(token)
            end
            for token in window:gmatch("[\"']([%w_%-%.]+)[\"']%s*==%s*" .. insensitive) do
                add(token)
            end
        end
    end
    if #ordered < 2 then
        return nil
    end
    local lowerValue = tostring(value):lower()
    for _, token in ipairs(ordered) do
        if token == lowerValue then
            return ordered
        end
    end
    return nil
end

-- Returns a choice list for a string entry, mined from the owning mod's own code, or nil when
-- no such evidence exists. `modDir` may be nil (no code mining).
-- The string keys of one table literal starting at `openAt` (the "{"), or nil when the literal
-- is not a plain keyed record (array items, nested-only content, or an unbalanced brace).
local function tableLiteralKeys(codeText, openAt)
    local depth, i, len = 0, openAt, #codeText
    local keys = {}
    local lineStart = openAt
    while i <= len do
        local c = codeText:sub(i, i)
        if c == "{" then
            depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then
                return keys
            end
        elseif c == "\n" then
            lineStart = i + 1
        elseif depth == 1 and c == "=" and i > lineStart then
            local before = codeText:sub(lineStart, i - 1)
            local key = before:match("^%s*([%a_][%w_]*)%s*$")
                or before:match("^%s*%[%s*[\"']([^\"']+)[\"']%s*%]%s*$")
            if key ~= nil then
                keys[#keys + 1] = key
            end
        end
        i = i + 1
    end
    return nil
end

-- The keys of a table literal in the mod's own code whose NAME shares a word with the config
-- key and whose keys include the current value: PassivePals' `defaultPalProfile =
-- "pacifist_avenger"` is chosen from `BUILTIN_PROFILES = { pacifist_avenger = {...},
-- vanilla = {...}, ... }` (reference install, 2026-09-02). Both gates are required: the shared
-- word ties the table to the setting, membership proves the value is drawn from it.
local function choicesFromTableKeys(index, key, value)
    if index == nil or index.code == "" or type(value) ~= "string" then
        return nil
    end
    local segment = key:match("[^%.]+$") or key
    local words = {}
    for word in segment:gsub("(%l)(%u)", "%1 %2"):gsub("_", " "):gmatch("%a%a%a%a+") do
        words[#words + 1] = word:lower()
    end
    if #words == 0 then
        return nil
    end
    for _, site in ipairs(tableSites(index)) do
        local related = false
        for _, word in ipairs(words) do
            if site.name:find(word, 1, true) then
                related = true
            end
        end
        if related then
            -- The keys of one literal are what they are: read once, kept on the site, since
            -- several settings of one mod can share a candidate table.
            if not site.read then
                site.keys = tableLiteralKeys(index.code, site.openAt)
                site.read = true
            end
            local keys = site.keys
            if keys ~= nil and #keys >= 2 and #keys <= 40 then
                for _, candidate in ipairs(keys) do
                    if candidate == value then
                        return keys
                    end
                end
            end
        end
    end
    return nil
end

function Bounds.choicesFromTableKeys(codeText, key, value)
    return choicesFromTableKeys(indexFor(codeText), key, value)
end

-- ============================== text format hints ==============================

-- Format clues mined from the owning mod's own code for a string entry that has neither a
-- comment-documented nor a code-mined choice list (rowspec.lua's "text" kind: the last resort,
-- read-only-otherwise fallback). Same evidence discipline as the range/enum mining above: a clue
-- is only returned when the mod's own code demonstrably does something with the key that implies
-- a format, never a guess at what a free string "probably" is. Checked in specificity order
-- (a hex-color check would false-positive as a path if path came first); the first match wins.
-- Returns a stable NAME, never prose: this module stays language-agnostic, the caller (panel.lua)
-- maps the name to a localized, " (?)"-marked string (Present.lua's catalog convention: this is
-- OUR inference from what the code does, never the mod author's own word for it). The window
-- (-20/+40 chars) is tuned against a synthetic fixture, not a real mod's code density - if an
-- in-game pass surfaces a hint attributed to the wrong key in a real file, narrow it further and
-- record what the pass showed.
local TEXT_HINTS = {
    { name = "color", test = function(window) return window:find("#%x", 1, true) ~= nil end },
    { name = "url", test = function(window) return window:find("http://", 1, true) ~= nil
        or window:find("https://", 1, true) ~= nil or window:find('"http', 1, true) ~= nil end },
    { name = "path", test = function(window) return window:find("io.open", 1, true) ~= nil
        or window:find("os.rename", 1, true) ~= nil
        or window:find("fsutil.readfile", 1, true) ~= nil
        or window:find("fsutil.writefile", 1, true) ~= nil end },
    { name = "list", test = function(window)
        return (window:find("gmatch", 1, true) ~= nil or window:find("split", 1, true) ~= nil)
            and window:find(",", 1, true) ~= nil
    end },
    { name = "number", test = function(window) return window:find("tonumber%s*%(", 1) ~= nil end },
}

-- The value must be consistent with the format the code hints at, or the hint is a coincidence
-- from a neighboring statement: a URL-bearing credit string was called "a number written as
-- text", and a save-schema stamp "v2" was called "a file path" (audit, 2026-09-03: four of the
-- five format hints on this install were false).
local FORMAT_FITS = {
    color = function(value) return value:match("^#%x%x%x") ~= nil end,
    url = function(value) return value:find("://", 1, true) ~= nil end,
    path = function(value)
        return value:find("[/\\]") ~= nil or value:match("%.%a%a%a?%a?$") ~= nil
    end,
    list = function(value) return value:find(",", 1, true) ~= nil end,
    number = function(value) return tonumber(value) ~= nil end,
}

-- Returns the name of the format clue found for `entry` ("color"|"url"|"path"|"list"|"number"),
-- or nil when the mod's own code shows no such evidence near the key (`modDir` nil, or nothing
-- found). Exported separately from Bounds.forEntry/choicesForEntry since it runs only as a last
-- resort after both of those have already failed to classify the entry.
function Bounds.hintForText(entry, modDir, filePath, allFiles)
    if modDir == nil or type(entry.value) ~= "string" then
        return nil
    end
    local index = modIndex(modDir, filePath, allFiles)
    if index.code == "" then
        return nil
    end
    local segment = entry.key:match("[^%.]+$")
    if segment == nil or #segment < 3 then
        return nil
    end
    local lowered = loweredCode(index)
    for _, variant in ipairs(nameVariants(segment)) do
        for _, hitFrom in ipairs(wholeWordHits(index, variant)) do
            local hitTo = hitFrom + #variant - 1
            -- Narrow on purpose (unlike the range/enum mining above, which needs room for a
            -- clamp idiom that follows the identifier): format evidence is almost always
            -- method-chained directly onto the key or the argument immediately wrapping it,
            -- on the same statement. A wide window bleeds into a neighboring key's own
            -- evidence in real config-reading code, where several keys sit a few lines apart.
            local window = lowered:sub(math.max(1, hitFrom - 20), hitTo + 40)
                :gsub("%s+", " ")
            for _, hint in ipairs(TEXT_HINTS) do
                local fits = FORMAT_FITS[hint.name]
                if hint.test(window) and (fits == nil or fits(entry.value)) then
                    return hint.name
                end
            end
        end
    end
    return nil
end

-- Every string literal the mod's own code compares this setting against, anywhere in the mod
-- (`x == "v"`, `x ~= "v"`, `x:lower() == "v"`, and the mirrored forms), in the literal's own
-- spelling, without the membership gate choicesFromCode applies. The gate makes choicesFromCode
-- a proven enum (a dropdown); this is the weaker evidence the Possible Entries strip shows
-- marked " (?)": what the code checks for, which may be only part of what it accepts.
function Bounds.literalsComparedTo(entry, modDir, filePath, allFiles)
    if modDir == nil or type(entry.value) ~= "string" then
        return nil
    end
    local index = modIndex(modDir, filePath, allFiles)
    if index.code == "" then
        return nil
    end
    local codeText = index.code
    local segment = entry.key:match("[^%.]+$")
    if segment == nil or #segment < 3 then
        return nil
    end
    local seen, ordered = {}, {}
    local function add(token)
        if token ~= "" and not seen[token] then
            seen[token] = true
            ordered[#ordered + 1] = token
        end
    end
    for _, variant in ipairs(nameVariants(segment)) do
        for _, hitFrom in ipairs(wholeWordHits(index, variant)) do
            -- Positions come from the lowercased copy and the literal is read from the
            -- original at the same offsets: string.lower keeps byte length, and a value's
            -- case matters.
            local hitTo = hitFrom + #variant - 1
            local windowFrom, windowTo = math.max(1, hitFrom - 40), math.min(#codeText, hitTo + 200)
            local window = codeText:sub(windowFrom, windowTo)
            local tail = window:sub(hitTo - windowFrom + 2)
            for literal in tail:gmatch("^[%w_%.%[%]\"':%(%)]-%s*[=~]=%s*[\"']([^\"'\n]+)[\"']") do
                add(literal)
            end
            for literal in tail:gmatch("^%s*:lower%(%)%s*[=~]=%s*[\"']([^\"'\n]+)[\"']") do
                add(literal)
            end
            local head = window:sub(1, hitFrom - windowFrom)
            for literal in head:gmatch("[\"']([^\"'\n]+)[\"']%s*[=~]=%s*$") do
                add(literal)
            end
        end
    end
    return ordered
end

function Bounds.choicesForEntry(entry, modDir, filePath, allFiles)
    if modDir == nil or type(entry.value) ~= "string" then
        return nil
    end
    local index = modIndex(modDir, filePath, allFiles)
    return choicesFromCode(index, entry.key, entry.value)
        or choicesFromTableKeys(index, entry.key, entry.value)
end

-- Returns min, max, step, source ("comment" | "code" | "name" | "value") for a numeric entry.
-- `modDir` may be nil (no code mining); `fileContent` may be nil (no comment mining);
-- `allFiles` is the mod's pre-listed file inventory (from the scan model).
-- A curated range for one setting, from the catalog's `bounds` table: "min|max" or
-- "min|max|step". The last resort for a clamp no rule can mine, such as one applied through a
-- loop over a list of key names (audit, 2026-09-03: SmartPalFeeding clamps four keys to 0..100
-- with no literal anywhere near the key).
local function loadCatalogBounds()
    local ok, catalog = pcall(require, "catalog")
    if ok and type(catalog) == "table" and type(catalog.bounds) == "table" then
        return catalog.bounds
    end
    return {}
end
Bounds.overrides = loadCatalogBounds()

local function overrideFor(modName, key)
    if modName == nil then
        return nil
    end
    local spec = Bounds.overrides[modName .. "." .. key]
    if type(spec) ~= "string" then
        return nil
    end
    local low, high, step = spec:match("^(-?[%d%.]+)|(-?[%d%.]+)|?(-?[%d%.]*)$")
    return tonumber(low), tonumber(high), tonumber(step)
end

-- A range whose top is a hundred times the current value leaves the useful part of the bar
-- under a pixel; for a MINED range the value's own magnitude is the better guide (audit: a
-- 1..2147483647 clamp put a 10000 default 0.0005% along the bar). It applies to every rung that
-- reads a bound out of code or out of a neighboring key - `code`, `declared` and `sibling` - and
-- not to `schema`, which is the range an author published for their own settings panel.
local function capMinedSpan(low, high, value)
    if value ~= 0 and high > math.abs(value) * 100 then
        return low, roundTop(math.max(math.abs(value) * 10, low + 10))
    end
    return low, high
end

-- `modName` keys the catalog override; `entry.schema` is a framework's own declaration.
-- The bounds stated in the 260 characters that follow one quoted mention of the key.
local function declaredAfter(codeText, quoteAt, value)
    local window = codeText:sub(quoteAt + 1, quoteAt + 260):gsub("%s+", " ")
    local low = tonumber(window:match("%f[%a]min%f[%A][%a]*%s*=%s*(" .. NUMBER .. ")"))
    local high = tonumber(window:match("%f[%a]max%f[%A][%a]*%s*=%s*(" .. NUMBER .. ")"))
    if low == nil or high == nil then
        local first, second = window:match("[,%s=]%s*(" .. NUMBER .. ")%s*,%s*(" .. NUMBER .. ")")
        low, high = tonumber(first), tonumber(second)
    end
    if sane(low, high, value) then
        return low, high
    end
    return nil
end

-- The bounds an author declared beside the setting's own name in their code. Three shapes seen
-- live (audit, 2026-09-03): named fields in the same table (`{ path = "...BossScale", kind =
-- "number", min = 0.01, max = 10 }`), positional arguments (`addNumberRow(page, "panelScale",
-- label, 40, 100)`, `configNumber("maxWildPalLevel", default, 1, 9999)`), and a validator keyed
-- by the name (`key == "BATCHSIZE" then numeric_min, numeric_max = 1, 100`). The key is matched
-- as a quoted token so a dotted path literal (".BossScale") counts. Gated on containing the
-- current value, like every other rung.
--
-- Case-insensitive: a validator may key on the upper-cased name (`key == "BATCHSIZE"`) while
-- the config writes it camel-cased (audit follow-up, 2026-09-03). The optional dot lets a
-- path PREFIX count too (`path = key .. ".Scales." .. s`), which is how a mod declares one
-- set of bounds for a whole generated group.
local function declaredNear(index, segment, value)
    if #segment < 3 then
        return nil
    end
    -- Comparing lowercase to lowercase is what ciPattern's letter classes did, one character at
    -- a time: every other byte the pattern matched literally, and string.lower leaves those
    -- alone. So the candidates are the quotes whose text ends with this key, in source order.
    local wanted = segment:lower()
    local ending = wanted:sub(-3)
    if ending:match("^[%w_][%w_][%w_]$") ~= nil then
        local bucket = declaredQuoteSites(index)[ending]
        if bucket == nil then
            return nil
        end
        local lowered, length = loweredCode(index), #wanted
        for _, at in ipairs(bucket) do
            local last = lowered:byte(at - 1) == 46 and (at - 2) or (at - 1)
            if lowered:sub(last - length + 1, last) == wanted then
                local low, high = declaredAfter(index.code, at, value)
                if low ~= nil then
                    return low, high
                end
            end
        end
        return nil
    end
    -- A key that does not end in three identifier characters is not in the index, which keeps
    -- only quotes that could carry one. It is scanned for the way every key used to be.
    local codeText = index.code
    local needle = ciPattern(segment) .. "%.?\""
    local from = 1
    while true do
        local hitFrom, hitTo = codeText:find(needle, from)
        if hitFrom == nil then
            return nil
        end
        from = hitTo + 1
        local low, high = declaredAfter(codeText, hitTo, value)
        if low ~= nil then
            return low, high
        end
    end
end

local function rangeFromDeclaredRow(index, key, value)
    if index == nil or index.code == "" then
        return nil
    end
    local segment = key:match("[^%.]+$") or key
    local low, high = declaredNear(index, segment, value)
    if low ~= nil then
        return low, high
    end
    -- A generated path never spells its own leaf out, so the leaf finds nothing while the GROUP
    -- it belongs to carries the declaration for every member: AntiPhatPalResizing writes
    -- `path = key .. ".Scales." .. s, kind = "number", min = 0.01, max = 10` once for all
    -- fifteen of its size rows (audit, 2026-09-03: 51 of its 54 rows missed their own bounds).
    -- The containment gate still discards a group whose numbers do not fit this setting.
    local parent = key:match("^(.*)%.[^%.]+$")
    if parent ~= nil then
        return declaredNear(index, parent:match("[^%.]+$") or parent, value)
    end
    return nil
end

function Bounds.rangeFromDeclaredRow(codeText, key, value)
    return rangeFromDeclaredRow(indexFor(codeText), key, value)
end

-- The bounds a sibling key in the same table states: `movement = { fine = 1.0, normal = 10.0,
-- minimum = 0.1, maximum = 1000.0 }` (audit, 2026-09-03: PerfectPlacement). Also `<stem>Min` /
-- `<stem>Max` beside `<stem>`. `siblings` is the parsed file's own entry list.
function Bounds.rangeFromSiblings(entry, siblings)
    if type(siblings) ~= "table" then
        return nil
    end
    local parent = entry.key:match("^(.*)%.[^%.]+$")
    local segment = entry.key:match("[^%.]+$") or entry.key
    local byKey = {}
    for _, other in ipairs(siblings) do
        if other.type == "number" then
            byKey[other.key:lower()] = other.value
        end
    end
    local function pick(...)
        for _, candidate in ipairs({ ... }) do
            if candidate ~= nil and byKey[candidate:lower()] ~= nil then
                return byKey[candidate:lower()]
            end
        end
        return nil
    end
    local prefix = parent ~= nil and (parent .. ".") or ""
    local low = pick(prefix .. "minimum", prefix .. "min", prefix .. segment .. "Min")
    local high = pick(prefix .. "maximum", prefix .. "max", prefix .. segment .. "Max")
    if low ~= nil and high ~= nil and low < high then
        return low, high
    end
    return nil
end

local function forEntryCore(entry, fileContent, modDir, filePath, allFiles, modName, siblings)
    local value = entry.value
    local integer = not literalIsFloat(fileContent, entry)
    -- A whole-looking value whose own comment talks in decimals is continuous: the author ships
    -- 0 for "off" and documents "0.1 to 1.0" for the rest, and an integer step made every legal
    -- fraction unreachable (audit, 2026-09-03).
    if integer and fileContent ~= nil then
        local context = commentContext(fileContent, entry.from)
        if context:find("%d%.%d") ~= nil then
            integer = false
        end
    end
    local low, high, step = overrideFor(modName, entry.key)
    if low ~= nil and sane(low, high, value) then
        return finish(low, high, value, "catalog", integer, step)
    end
    -- The author's own published schema outranks everything mined.
    local schema = entry.schema
    if schema ~= nil and type(schema.min) == "number" and type(schema.max) == "number"
        and sane(schema.min, schema.max, value) then
        return finish(schema.min, schema.max, value, "schema", integer)
    end
    if fileContent ~= nil then
        low, high = rangeFromComment(commentContext(fileContent, entry.from), value)
        if low ~= nil then
            return finish(low, high, value, "comment", integer)
        end
    end
    low, high = Bounds.rangeFromSiblings(entry, siblings)
    if low ~= nil and sane(low, high, value) then
        low, high = capMinedSpan(low, high, value)
        return finish(low, high, value, "sibling", integer)
    end
    if modDir ~= nil then
        local index = modIndex(modDir, filePath, allFiles)
        low, high = rangeFromDeclaredRow(index, entry.key, value)
        if low ~= nil then
            low, high = capMinedSpan(low, high, value)
            return finish(low, high, value, "declared", integer)
        end
        low, high = rangeFromCode(index, entry.key, value)
        if low ~= nil then
            low, high = capMinedSpan(low, high, value)
            return finish(low, high, value, "code", integer)
        end
    end
    low, high = rangeFromName(entry.key, value)
    if low ~= nil then
        return finish(low, high, value, "name", integer)
    end
    low, high = rangeFromValue(value)
    return finish(low, high, value, "value", integer)
end

-- How many digits the author wrote after the point. `1.25` gives 2, `1.0` gives 1, `1` gives 0.
-- Read from the LITERAL rather than the number, since 1.0 and 1 are the same Lua value.
local function literalDecimals(fileContent, entry)
    if fileContent == nil or entry == nil or entry.from == nil or entry.to == nil then
        return 0
    end
    local fraction = fileContent:sub(entry.from, entry.to):match("^%s*%-?%d*%.(%d+)")
    return fraction ~= nil and #fraction or 0
end

-- One press of left or right on a controller moves a bar by ONE of these, not by the display
-- step: a whole-numbered setting goes 1 to 2, and a setting the author wrote to one decimal goes
-- 1.0 to 1.1. On the display step a whole-number bar needed many presses to move by one
-- (seen 2026-09-07), because the drag grid it shares with a mouse is sized for roughly fifty
-- stops across the range and the number beside it rounds. Capped at three places, which is the
-- smallest step the ladder mines.
local function unitFor(fileContent, entry, integer, step)
    if integer then
        return 1
    end
    local places = literalDecimals(fileContent, entry)
    if places < 1 then
        places = 1
    elseif places > 3 then
        places = 3
    end
    local unit = 10 ^ -places
    -- A bar whose own grid is finer than the literal's precision keeps the finer one, so no
    -- value the mouse can reach becomes unreachable with a pad.
    if step ~= nil and step > 0 and step < unit then
        return step
    end
    return unit
end

-- The granularity a set of numbers is written on: the LARGEST of these that divides every one of
-- them exactly. AntiPhat's scales are 0.8, 0.75, 0.65 and 0.5, which is a 0.05 setting however
-- fine a bar sized for fifty stops would make it.
local UNIT_LADDER = { 2500, 1000, 250, 100, 25, 10, 5, 1, 0.5, 0.25, 0.2, 0.1, 0.05, 0.025, 0.01,
    0.005, 0.001 }

-- The largest 1, 2 or 5 times a power of ten at or below `limit`, which is the same shape
-- `roundSteps` walks. Returns nil below the finest interval this mod will offer.
local function roundedDownTo(limit)
    if type(limit) ~= "number" or limit <= 0 then
        return nil
    end
    local exponent = math.floor(math.log(limit, 10) + 1e-12)
    for scale = exponent, -3, -1 do
        for _, mantissa in ipairs({ 5, 2, 1 }) do
            local candidate = mantissa * 10 ^ scale
            if candidate <= limit * (1 + 1e-9) then
                return tonumber(string.format("%.6g", candidate))
            end
        end
    end
    return nil
end

-- The smallest 1, 2 or 5 times a power of ten at or above `limit`.
local function roundedUpTo(limit)
    if type(limit) ~= "number" or limit <= 0 then
        return nil
    end
    local exponent = math.floor(math.log(limit, 10) + 1e-12) - 1
    for scale = exponent, exponent + 12 do
        for _, mantissa in ipairs({ 1, 2, 5 }) do
            local candidate = mantissa * 10 ^ scale
            if candidate >= limit * (1 - 1e-9) then
                return tonumber(string.format("%.6g", candidate))
            end
        end
    end
    return nil
end

-- The hard bound, applied to every interval including a curated one: a bar must be crossable.
-- Past this many presses the bar is not the way to reach a value and the typed box is, so a finer
-- interval buys nothing and costs the player the ability to get anywhere.
local MAX_STOPS_ON_A_BAR = 1000

-- No interval finer than a hundredth of the number's own size. A setting sitting at 30000 was
-- offered 0.1, which is five million presses from end to end, purely because its author wrote one
-- decimal place. This is a FLOOR: it only ever makes an interval coarser, so a 0.8 scale keeps the
-- 0.05 its siblings prove. A value of 0 has no size of its own, so the span stands in for it.
local function magnitudeFloor(value, minValue, maxValue)
    local size = math.abs(value or 0)
    if size > 0 then
        return roundedDownTo(size / 100)
    end
    if minValue ~= nil and maxValue ~= nil and maxValue > minValue then
        return roundedDownTo((maxValue - minValue) / 500)
    end
    return nil
end

-- A color channel is written to whatever precision a picker happened to emit
-- (`badIVColor.r = 0.3813260198`), so the numbers themselves say nothing. Two decimal places is
-- what a person adjusts a channel in.
local CHANNEL_LEAVES = { r = true, g = true, b = true, a = true,
    red = true, green = true, blue = true, alpha = true }

local function isColorChannel(key, minValue, maxValue)
    if key == nil or minValue == nil or maxValue == nil then
        return false
    end
    if minValue < 0 or maxValue > 1 then
        return false
    end
    local parent, leaf = key:match("^(.*)%.([^%.]+)$")
    if parent == nil or not CHANNEL_LEAVES[leaf:lower()] then
        return false
    end
    parent = parent:lower()
    return parent:find("color", 1, true) ~= nil or parent:find("tint", 1, true) ~= nil
end

local function divisibleBy(values, unit)
    for _, value in ipairs(values) do
        local units = value / unit
        if math.abs(units - math.floor(units + 0.5)) > 1e-6 then
            return false
        end
    end
    return true
end

-- The numbers written beside this one under the same parent: `Base.Scales.XS` is read with `S`,
-- `M`, `L` and `XL`, which is where the author's own granularity shows. One value on its own says
-- nothing, so two or more are required.
local function siblingUnit(entry, siblings)
    if entry == nil or siblings == nil or entry.key == nil then
        return nil
    end
    local parent = entry.key:match("^(.*)%.[^%.]+$")
    if parent == nil then
        return nil
    end
    local values = {}
    for _, other in ipairs(siblings) do
        if type(other.value) == "number" and other.key ~= nil
            and other.key:match("^(.*)%.[^%.]+$") == parent then
            values[#values + 1] = other.value
        end
    end
    if #values < 2 then
        return nil
    end
    -- A group whose members are orders of magnitude apart is not one vocabulary, and its divisor
    -- belongs to the smallest member: `{ xpMult = 2, singleSuitFactor = 0.5, seqCap = 2000 }`
    -- would hand `seqCap` an interval of 0.5.
    local low, high = nil, nil
    for _, value in ipairs(values) do
        local size = math.abs(value)
        if size > 0 then
            low = (low == nil or size < low) and size or low
            high = (high == nil or size > high) and size or high
        end
    end
    if low ~= nil and high ~= nil and high > low * 100 then
        return nil
    end
    for _, unit in ipairs(UNIT_LADDER) do
        if divisibleBy(values, unit) then
            return unit
        end
    end
    return nil
end

-- Returns min, max, step, source, unit. `unit` is the interval one adjustment moves, for a D-pad
-- press and for a mouse drag alike; `step` stays the grid the bar itself is built on.
function Bounds.forEntry(entry, fileContent, modDir, filePath, allFiles, modName, siblings)
    local minValue, maxValue, step, source =
        forEntryCore(entry, fileContent, modDir, filePath, allFiles, modName, siblings)
    -- The interval, in order of authority: what the author's own catalog entry states, then the
    -- granularity the values beside this one are written on, then the precision of the literal
    -- itself. Whichever wins is clamped to the range, since a unit bigger than the span cannot
    -- move at all.
    local _, _, curated = overrideFor(modName, entry.key)
    local unit = curated
    if (unit == nil or unit <= 0) and isColorChannel(entry.key, minValue, maxValue) then
        unit = 0.01
    end
    if unit == nil or unit <= 0 then
        unit = siblingUnit(entry, siblings)
    end
    if unit == nil or unit <= 0 then
        -- A fractional grid means the core read this as continuous, whatever the literal looks
        -- like: a whole-looking value whose comment talks in decimals is one of those.
        local integer = not literalIsFloat(fileContent, entry)
            and (step == nil or step <= 0 or step == math.floor(step))
        unit = unitFor(fileContent, entry, integer, step)
    end
    -- The floor applies to everything this mod DERIVED, never to a curated entry: the catalog is
    -- the author's own answer and outranks any rule.
    if curated == nil or curated <= 0 then
        local floor = magnitudeFloor(entry.value, minValue, maxValue)
        if floor ~= nil and (unit == nil or unit < floor) then
            unit = floor
        end
    end
    if maxValue > minValue then
        local span = maxValue - minValue
        if unit == nil or unit <= 0 or span / unit > MAX_STOPS_ON_A_BAR then
            local crossable = roundedUpTo(span / MAX_STOPS_ON_A_BAR)
            if crossable ~= nil and (unit == nil or crossable > unit) then
                unit = crossable
            end
        end
        if unit ~= nil and unit > span then
            unit = nil
        end
    end
    return minValue, maxValue, step, source, unit
end

return Bounds
