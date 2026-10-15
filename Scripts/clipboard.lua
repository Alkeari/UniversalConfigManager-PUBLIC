-- The player's clipboard, through the game's own static library: PalUtility:ClipboardCopy
-- (String) -> bool and GetClipboard (UE4SS object dump, build 24575825, 2026-09-01; the MapsPlus
-- mod calls ClipboardCopy from its map panel, so the call works from a mod on this build).
-- Called the way i18n.lua calls KismetInternationalizationLibrary and controls.lua calls
-- PalUIUtility. Never a shell: `clip.exe` or PowerShell would flash a console (category rule).
local log = require("logger")

local Clipboard = {}

local LIBRARY_PATH = "/Script/Pal.Default__PalUtility"
local warned = false

-- Copies `text` and returns true, or false when the library is unreachable (the offline suite,
-- a build that renamed it) or the call reports failure. Logs the first failure once.
function Clipboard.copy(text)
    if type(StaticFindObject) ~= "function" then
        return false
    end
    local ok, result = pcall(function()
        local library = StaticFindObject(LIBRARY_PATH)
        if library == nil or not library:IsValid() then
            return false
        end
        return library:ClipboardCopy(tostring(text or "")) and true or false
    end)
    if not ok or not result then
        if not warned then
            warned = true
            log.warn("clipboard copy failed" .. (ok and "" or (": " .. tostring(result))))
        end
        return false
    end
    return true
end

return Clipboard
