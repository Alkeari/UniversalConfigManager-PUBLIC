-- Opens a URL in the player's own browser, through the engine's own LaunchURL rather than a
-- shell. `os.execute("start ...")` would flash a console window on a game that has none, which
-- is the same reason directory listings go through IterateGameDirectories (category rule).
--
-- UKismetSystemLibrary::LaunchURL is a static BlueprintCallable, reached the way i18n.lua reaches
-- KismetInternationalizationLibrary and clipboard.lua reaches PalUtility. Unproven on this build
-- at the time of writing, so every caller must treat false as ordinary: the URL is always shown
-- in a copyable row as well, and that row is what the player falls back to.
local log = require("logger")

local Browser = {}

local LIBRARY_PATH = "/Script/Engine.Default__KismetSystemLibrary"
local warned = false

function Browser.available()
    return type(StaticFindObject) == "function"
end

-- Opens `url`, returning true only when the engine call was actually made. Never raises.
function Browser.open(url)
    local address = tostring(url or "")
    if address == "" or not Browser.available() then
        return false
    end
    -- Only ever a link this mod itself owns (Config.requestForums). A URL assembled from
    -- anything a player typed has no business being handed to the shell of a browser.
    if address:sub(1, 8) ~= "https://" then
        return false
    end
    local ok, result = pcall(function()
        local library = StaticFindObject(LIBRARY_PATH)
        if library == nil or not library:IsValid() then
            return false
        end
        library:LaunchURL(address)
        return true
    end)
    if not ok or result ~= true then
        if not warned then
            warned = true
            log.warn("could not open a browser (" .. (ok and "call refused" or tostring(result))
                .. "); the link is shown to copy instead")
        end
        return false
    end
    return true
end


-- Opens the FOLDER holding `filePath` in whatever file manager this player uses. A file:// URL
-- goes through the same LaunchURL as an https one, so the default handler decides - never
-- explorer.exe by name, which would both assume File Explorer and cost a console window
-- (observed 2026-09-06). The path is always one this mod wrote inside its own folder.
function Browser.openFolder(filePath)
    local text = tostring(filePath or ""):gsub("\\\\", "/")
    local folder = text:match("^(.*)/[^/]+$")
    if folder == nil or folder == "" or not Browser.available() then
        return false
    end
    local ok, result = pcall(function()
        local library = StaticFindObject(LIBRARY_PATH)
        if library == nil or not library:IsValid() then
            return false
        end
        library:LaunchURL("file:///" .. folder)
        return true
    end)
    return ok and result == true
end

return Browser
