-- The key-name vocabulary for hotkey config values, ordered common-first so the native LR
-- selector reaches everyday choices quickly. Sources: the UE4SS `Key` table (RE-UE4SS
-- docs/lua-api/table-definitions/key.md, 165 names - what mods pass to RegisterKeyBind) plus
-- the Unreal Gamepad FKey names observed in real configs (PalArmy).
local KeyNames = {}

KeyNames.modifiers = { "NONE", "CTRL", "SHIFT", "ALT" }

KeyNames.keys = {
    -- Letters and digits.
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
    "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
    "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE",
    -- Function keys.
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    -- Navigation and editing.
    "SPACE", "TAB", "RETURN", "ESCAPE", "BACKSPACE",
    "UP_ARROW", "DOWN_ARROW", "LEFT_ARROW", "RIGHT_ARROW",
    "PAGE_UP", "PAGE_DOWN", "HOME", "END", "INS", "DEL",
    -- Numpad.
    "NUM_ZERO", "NUM_ONE", "NUM_TWO", "NUM_THREE", "NUM_FOUR",
    "NUM_FIVE", "NUM_SIX", "NUM_SEVEN", "NUM_EIGHT", "NUM_NINE",
    "MULTIPLY", "ADD", "SUBTRACT", "DECIMAL", "DIVIDE", "SEPARATOR",
    -- Mouse.
    "LEFT_MOUSE_BUTTON", "RIGHT_MOUSE_BUTTON", "MIDDLE_MOUSE_BUTTON",
    "XBUTTON_ONE", "XBUTTON_TWO",
    -- Gamepad (Unreal FKey names, exact case).
    "Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right",
    "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left",
    "Gamepad_FaceButton_Top",
    "Gamepad_LeftShoulder", "Gamepad_RightShoulder",
    "Gamepad_LeftTrigger", "Gamepad_RightTrigger",
    "Gamepad_LeftThumbstick", "Gamepad_RightThumbstick",
    "Gamepad_Special_Left", "Gamepad_Special_Right",
    -- The rest of the UE4SS Key table.
    "CAPS_LOCK", "NUM_LOCK", "SCROLL_LOCK", "PAUSE", "PRINT_SCREEN",
    "CANCEL", "CLEAR", "SELECT", "PRINT", "EXECUTE", "HELP", "SLEEP",
    "LEFT_WIN", "RIGHT_WIN", "APPS",
    "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24",
    "BROWSER_BACK", "BROWSER_FORWARD", "BROWSER_REFRESH", "BROWSER_STOP",
    "BROWSER_SEARCH", "BROWSER_FAVORITES", "BROWSER_HOME",
    "VOLUME_MUTE", "VOLUME_DOWN", "VOLUME_UP",
    "MEDIA_NEXT_TRACK", "MEDIA_PREV_TRACK", "MEDIA_STOP", "MEDIA_PLAY_PAUSE",
    "LAUNCH_MAIL", "LAUNCH_MEDIA_SELECT", "LAUNCH_APP1", "LAUNCH_APP2",
    "OEM_ONE", "OEM_PLUS", "OEM_COMMA", "OEM_MINUS", "OEM_PERIOD", "OEM_TWO",
    "OEM_THREE", "OEM_FOUR", "OEM_FIVE", "OEM_SIX", "OEM_SEVEN", "OEM_EIGHT",
    "OEM_102", "OEM_CLEAR",
    "IME_KANA", "IME_HANGUEL", "IME_HANGUL", "IME_ON", "IME_JUNJA", "IME_FINAL",
    "IME_HANJA", "IME_KANJI", "IME_OFF", "IME_CONVERT", "IME_NONCONVERT",
    "IME_ACCEPT", "IME_MODECHANGE", "IME_PROCESS",
    "PACKET", "ATTN", "CRSEL", "EXSEL", "EREOF", "PLAY", "ZOOM", "PA1",
}

local keyIndexByLower = {}
for index, name in ipairs(KeyNames.keys) do
    keyIndexByLower[name:lower()] = index
end
local modifierIndexByLower = {}
for index, name in ipairs(KeyNames.modifiers) do
    modifierIndexByLower[name:lower()] = index
end

-- 1-based index of `value` in the key list (case-insensitive), or nil.
function KeyNames.keyIndex(value)
    return type(value) == "string" and keyIndexByLower[value:lower()] or nil
end

function KeyNames.modifierIndex(value)
    return type(value) == "string" and modifierIndexByLower[value:lower()] or nil
end

-- Splits "CTRL+N" into canonical modifier and key names; a bare key returns ("NONE", key).
-- Returns nil when the value is not expressible in this vocabulary.
function KeyNames.split(value)
    if type(value) ~= "string" then
        return nil
    end
    local prefix, rest = value:match("^([%w]+)%s*%+%s*(.+)$")
    if prefix ~= nil then
        local modifierAt = modifierIndexByLower[prefix:lower()]
        local keyAt = keyIndexByLower[rest:lower()]
        if modifierAt ~= nil and modifierAt > 1 and keyAt ~= nil then
            return KeyNames.modifiers[modifierAt], KeyNames.keys[keyAt]
        end
        return nil
    end
    local keyAt = keyIndexByLower[value:lower()]
    if keyAt ~= nil then
        return "NONE", KeyNames.keys[keyAt]
    end
    return nil
end

-- The inverse of split: ("NONE", "N") -> "N"; ("CTRL", "N") -> "CTRL+N".
function KeyNames.join(modifier, key)
    if modifier == nil or modifier == "NONE" then
        return key
    end
    return modifier .. "+" .. key
end

return KeyNames
