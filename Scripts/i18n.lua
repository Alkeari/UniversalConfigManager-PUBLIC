-- Player-facing strings in the game's own language. `Assets\lang\en.ini` is always loaded
-- first; the file for the language the game reports (KismetInternationalizationLibrary's
-- GetCurrentLanguage: "en", "ja", "zh-Hans", "pt-BR", "es-MX", ...) overlays it, so a key a
-- translation leaves out falls back to English and a missing file falls back whole. The ini
-- files are generated from tools/lang by build_lang.py; never edit them by hand.
local FsUtil = require("fsutil")

local I18n = {}

I18n.language = "en"
local strings = {}

local LIBRARY_PATH = "/Script/Engine.Default__KismetInternationalizationLibrary"

function I18n.languageDirectory()
    local scripts = FsUtil.scriptDirectory()
    local modRoot = FsUtil.parent(scripts) or scripts
    return modRoot .. "\\Assets\\lang"
end

-- key=value per line, "#" comments, UTF-8 with or without a BOM; "\n" in a value is a newline.
function I18n.parse(content)
    local out = {}
    if content == nil then
        return out
    end
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
    end
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^([^=]+)=(.*)$")
            if key ~= nil then
                out[key:match("^%s*(.-)%s*$")] = (value:match("^%s*(.-)%s*$"):gsub("\\n", "\n"))
            end
        end
    end
    return out
end

-- The files worth trying for a reported code, most specific first: "es-MX" tries es-MX then
-- es; "zh-Hans" has no bare parent file and tries only itself.
function I18n.candidates(code)
    local list = {}
    local seen = {}
    local function add(name)
        if name ~= nil and name ~= "" and not seen[name] then
            seen[name] = true
            list[#list + 1] = name
        end
    end
    code = tostring(code or ""):match("^%s*(.-)%s*$")
    add(code)
    local base = code:match("^([%a]+)[%-_]")
    if base ~= nil and base:lower() ~= "zh" then
        add(base)
    end
    return list
end

-- What the game reports, or "en" when the library is unreachable (the offline suite, or an
-- engine that renamed it).
function I18n.detectLanguage()
    if type(StaticFindObject) ~= "function" then
        return "en"
    end
    local ok, code = pcall(function()
        local library = StaticFindObject(LIBRARY_PATH)
        if library == nil or not library:IsValid() then
            return nil
        end
        return library:GetCurrentLanguage():ToString()
    end)
    if ok and type(code) == "string" and code ~= "" then
        return code
    end
    return "en"
end

-- Loads English, then the overlay for `code`. Returns the code whose file was found ("en"
-- when none of the candidates exists).
function I18n.load(directory, code)
    directory = directory or I18n.languageDirectory()
    strings = I18n.parse(FsUtil.readFile(directory .. "\\en.ini"))
    I18n.language = "en"
    for _, candidate in ipairs(I18n.candidates(code)) do
        if candidate ~= "en" then
            local content = FsUtil.readFile(directory .. "\\" .. candidate .. ".ini")
            if content ~= nil then
                for key, value in pairs(I18n.parse(content)) do
                    strings[key] = value
                end
                I18n.language = candidate
                break
            end
        end
    end
    return I18n.language
end

function I18n.refresh()
    return I18n.load(nil, I18n.detectLanguage())
end

-- The string for `key`, or nil when no loaded file has it.
function I18n.lookup(key)
    return strings[key]
end

-- The string for `key` with every {name} replaced from `vars`; the key itself when unknown,
-- so a missing entry shows up in the UI instead of crashing a row.
function I18n.t(key, vars)
    local text = strings[key] or key
    if vars ~= nil then
        text = text:gsub("{(%w+)}", function(name)
            local value = vars[name]
            return value ~= nil and tostring(value) or ("{" .. name .. "}")
        end)
    end
    return text
end

return I18n
