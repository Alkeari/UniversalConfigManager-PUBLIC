-- Suppresses another config framework's own interface, so that with this mod installed exactly
-- one thing on screen renders mod configuration. Unconditional and not a setting: two config
-- menus on one screen leave the player guessing which one the game actually reads.
--
-- This is a DIFFERENT act from the framework-button hiding in inject.lua. That collapses a
-- button another UE4SS Lua mod injected into the game's own Options screen or ESC menu, which
-- are widgets this mod already holds a handle on. DekModConfigMenu (Nexus 577) injects nothing
-- into a game menu: its whole pak references exactly two game assets, a UI sound event and a
-- keyboard key-guide texture. It adds its OWN widget to the viewport - the "Mod Config" label
-- and gear in the title screen's top-right corner - and opens its own window from its own key.
-- So there is no game-menu button to collapse, and the widget itself is the target.
--
-- HOW, and why it changed (2026-09-06). The first version swept every five seconds for the whole
-- session, calling SetVisibility on another mod's widgets on a timer. Between the IsValid check
-- and the call there is a window in which the widget can be destroyed, and a level transition is
-- exactly when that happens, and pcall does NOT catch an access violation
-- inside UE4SS, so losing that race is a hard crash rather than a logged failure. The sweep now
-- exists only to find the class once. As soon as it has an instance it registers a hook on that
-- class's own Construct and stops polling: a widget is provably alive while it is constructing,
-- which removes the race instead of narrowing it, and it collapses the moment it appears rather
-- than up to five seconds later.
--
-- Resolved by short class name through FindAllOf, never by a hardcoded asset path: the pak's own
-- index spells the widget package two ways ("/Game/Mods/DekConfigMenu_P/Widgets/" beside
-- "/Game/Mods/DekModConfigMenu_P/"), so a path constant would be a guess where the class name is
-- not. The path the hook needs is read off a live instance instead.
local Config = require("config")
local HookParam = require("hook_param")
local log = require("logger")

local Suppress = {}

local everFound = false
local loggedFound = {}
local loggedAbsent = false
local running = false
local hookedClasses = {}
local hookedCount = 0

-- Collapsed (ESlateVisibility 1) rather than RemoveFromParent: the owning Blueprint re-adds its
-- widget whenever the title screen is rebuilt, so a removal would be undone and a destroyed
-- widget could take its owner's own logic down with it. Collapsing is idempotent and reversible.
local COLLAPSED = Config.ui.pageInactiveVisibility

-- "WidgetBlueprintGeneratedClass /Game/Mods/X/Widgets/WBP_Y.WBP_Y_C" is what GetFullName gives
-- for a Blueprint class; RegisterHook wants the object path alone. Pure, so the suite can hold
-- this to the shapes seen rather than to a live object.
function Suppress.hookPathFromFullName(fullName, event)
    local text = tostring(fullName or "")
    local path = text:match("^%S+%s+(/%S+)$") or text:match("^(/%S+)$")
    if path == nil then
        return nil
    end
    return path .. ":" .. tostring(event or "Construct")
end

local function collapse(widget)
    if widget == nil then
        return false
    end
    local valid = false
    pcall(function() valid = widget:IsValid() end)
    if not valid then
        return false
    end
    local visibility = nil
    local read = pcall(function() visibility = widget.Visibility end)
    -- An unreadable visibility is not evidence it is already hidden, so it is collapsed anyway.
    if read and visibility == COLLAPSED then
        return false
    end
    return pcall(function() widget:SetVisibility(COLLAPSED) end)
end

-- Registers a Construct hook for `className` off a live instance, so every future one of these
-- collapses while it is being built. Returns true once the hook is in place.
local function armHook(className, instance)
    if hookedClasses[className] then
        return true
    end
    if type(RegisterHook) ~= "function" then
        return false
    end
    local fullName = nil
    local ok = pcall(function() fullName = instance:GetClass():GetFullName() end)
    if not ok or fullName == nil then
        return false
    end
    local path = Suppress.hookPathFromFullName(fullName, "Construct")
    if path == nil then
        return false
    end
    local registered = pcall(function()
        RegisterHook(path, function(Context)
            pcall(function() collapse(HookParam.read(Context)) end)
        end)
    end)
    if not registered then
        return false
    end
    hookedClasses[className] = true
    hookedCount = hookedCount + 1
    log.info("hooked " .. path .. ": every one of these collapses as it is built")
    return true
end

-- One pass over every suppressed class. Returns how many widgets this pass actually collapsed.
-- Every engine call is pcall-guarded: a class that does not exist, an instance that went invalid
-- between the find and the set, or a build that renamed SetVisibility all degrade to zero.
function Suppress.sweep()
    if type(FindAllOf) ~= "function" then
        return 0
    end
    local collapsed = 0
    for _, className in ipairs(Config.suppress.classes or {}) do
        local ok, instances = pcall(FindAllOf, className)
        if ok and type(instances) == "table" and #instances > 0 then
            everFound = true
            if not loggedFound[className] then
                loggedFound[className] = true
                log.info("suppressing " .. className .. " (" .. #instances .. " instance(s)): "
                    .. "this mod is the only config menu while it is installed")
            end
            for _, widget in ipairs(instances) do
                if collapse(widget) then
                    collapsed = collapsed + 1
                end
            end
            armHook(className, instances[1])
        end
    end
    return collapsed
end

-- Whether the poll has finished its job: every class it has ever seen now collapses itself
-- through its own Construct hook, so nothing needs to be swept on a timer any more.
function Suppress.settled()
    if not everFound then
        return false
    end
    for className in pairs(loggedFound) do
        if not hookedClasses[className] then
            return false
        end
    end
    return true
end

-- Finds the classes, hands each one to a Construct hook, and stops. Two ways to end: everything
-- seen is hooked, or nothing was ever there to hook (the ordinary case of a player without that
-- framework, who should pay nothing for this).
function Suppress.start()
    if running or ExecuteInGameThreadWithDelay == nil then
        return
    end
    running = true
    local settings = Config.suppress
    local step
    step = function(passes)
        local ok, err = pcall(function()
            Suppress.sweep()
            if Suppress.settled() then
                running = false
                log.info("config-menu suppression is hook-driven now; the sweep has stopped after "
                    .. passes .. " pass(es)")
                return
            end
            local delay = settings.openingIntervalMs
            if passes >= settings.giveUpAfterPasses then
                -- Past the opening phase with nothing found. Keep watching slowly rather than
                -- giving up: the target widget only exists while the title screen is up, so a
                -- player who loaded straight into a world has simply not shown it to us yet.
                if not loggedAbsent then
                    loggedAbsent = true
                    log.info("no other config framework's interface found yet; watching slowly")
                end
                delay = settings.idleIntervalMs
            elseif passes >= settings.openingPasses then
                delay = settings.steadyIntervalMs
            end
            ExecuteInGameThreadWithDelay(delay, function() step(passes + 1) end)
        end)
        if not ok then
            running = false
            log.warn("suppression sweep stopped: " .. tostring(err))
        end
    end
    ExecuteInGameThreadWithDelay(settings.firstDelayMs, function() step(0) end)
end

-- Test seam: the offline suite drives these against fake widgets and needs a clean slate.
function Suppress.reset()
    everFound = false
    loggedFound = {}
    loggedAbsent = false
    running = false
    hookedClasses = {}
    hookedCount = 0
end

function Suppress.everFound()
    return everFound
end

function Suppress.hookedCount()
    return hookedCount
end

return Suppress
