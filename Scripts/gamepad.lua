-- Is the player on a controller right now? Everything gamepad-specific in this mod is gated on
-- this, so a mouse-and-keyboard player sees exactly what they saw before: controller support
-- went in without overtly changing how UCM looks or behaves.
--
-- The game answers this itself: WBP_OptionSettings calls CommonInputSubsystem::GetCurrentInputType
-- (its own import table, build 24575825), and ECommonInputType is CommonUI's standard enum. The
-- subsystem instance is reached through FindFirstOf, the same way controls.lua reaches
-- PalGameInstance for the Backspace gate.
--
-- Every read is pcall-guarded and every failure answers "not a gamepad", so a build where the
-- subsystem cannot be found behaves exactly as this mod did before controller support existed.
local log = require("logger")

local Gamepad = {}

-- ECommonInputType, CommonUI's own values.
Gamepad.MOUSE_AND_KEYBOARD = 0
Gamepad.GAMEPAD = 1
Gamepad.TOUCH = 2

local subsystem = nil
local warned = false

local function resolveSubsystem()
    if subsystem ~= nil then
        local alive = false
        pcall(function() alive = subsystem:IsValid() end)
        if alive then
            return subsystem
        end
        subsystem = nil
    end
    if type(FindFirstOf) ~= "function" then
        return nil
    end
    local ok, found = pcall(function() return FindFirstOf("CommonInputSubsystem") end)
    if not ok or found == nil then
        return nil
    end
    local valid = false
    pcall(function() valid = found:IsValid() end)
    if not valid then
        return nil
    end
    subsystem = found
    return subsystem
end

-- The current input type as CommonUI reports it, or nil when it could not be read.
function Gamepad.currentInputType()
    local instance = resolveSubsystem()
    if instance == nil then
        return nil
    end
    local value = nil
    local ok = pcall(function() value = instance:GetCurrentInputType() end)
    if not ok or value == nil then
        return nil
    end
    -- UE4SS hands an enum back as a number on this build; a table with a Value is tolerated too
    -- rather than assumed away, since neither shape is recorded for this call yet.
    if type(value) == "table" then
        local inner = nil
        pcall(function() inner = value.Value end)
        value = inner
    end
    return tonumber(value)
end

-- True only when the game says the player is on a controller. Unknown answers false, so nothing
-- gamepad-specific ever runs on a guess.
--
-- STICKY, and that is the whole point. CommonUI reports the device of the last input it saw, so
-- with a pad in hand and a mouse on the desk the answer flips on the smallest nudge. Anything
-- built on the raw reading flaps with it: on 2026-09-07 that rebuilt the open page and stole focus
-- back to its first row every second or two, and no press landed at all. A change is only
-- believed after it has been read the same way several times running.
local stable = false
local seeded = false
local pending, pendingCount = nil, 0

function Gamepad.isActive()
    local value = Gamepad.currentInputType()
    if value == nil then
        -- Nothing to go on: keep whatever was last believed rather than claiming a mouse.
        return stable
    end
    local reading = value == Gamepad.GAMEPAD
    -- The FIRST answer the game gives is taken as it stands. Waiting for a run of readings before
    -- believing anything meant the first page was built before the mod knew there was a controller,
    -- so a controller got the mouse's rows and the search box never opened the keyboard
    -- (seen 2026-09-07). Only CHANGES need convincing.
    if not seeded then
        seeded = true
        stable = reading
        return stable
    end
    if reading == stable then
        pending, pendingCount = nil, 0
        return stable
    end
    if reading ~= pending then
        pending, pendingCount = reading, 1
        return stable
    end
    pendingCount = pendingCount + 1
    if pendingCount < (Gamepad.stableReads or 6) then
        return stable
    end
    stable = reading
    pending, pendingCount = nil, 0
    return stable
end

-- How many consecutive identical readings a change of device needs before it is believed. At the
-- 50 ms focus poll this is a third of a second: instant to a player, an eternity to a jittering
-- mouse.
Gamepad.stableReads = 6

-- One line the first time the answer is available, as evidence the lookup works at all; a mod
-- that silently never finds the subsystem would otherwise look identical to one on a keyboard.
function Gamepad.logOnce()
    if warned then
        return
    end
    local value = Gamepad.currentInputType()
    if value == nil then
        return
    end
    warned = true
    log.info("input type: " .. (value == Gamepad.GAMEPAD and "gamepad"
        or value == Gamepad.TOUCH and "touch" or "mouse and keyboard")
        .. " (CommonInputSubsystem)")
end

return Gamepad
