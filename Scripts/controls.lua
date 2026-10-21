-- Our own controls inside the game's row frame: the native PalComboBoxString dropdown and an
-- EditableTextBox. UE4SS Lua cannot bind UMG delegates, so a small poll (Controls.poll, driven
-- by panel.lua while a page is open) reads each control's current value and reports changes.
local Config = require("config")
local Gamepad = require("gamepad")
local Widgets = require("widgets")
local log = require("logger")

local Controls = {}

local ui = Config.ui.controls
local registered = {}
local warned = {}

-- EVERY text box this mod builds, registered or not. The Backspace gate used to consult
-- `registered` only, so the boxes that carry no staged setting - a read-only folder path, the
-- request-file path, a Possible Entries filter - were invisible to it and Backspace closed the
-- screen from inside them (seen 2026-09-04). The gate has to hold inside ALL text boxes, so a
-- box joins this list the moment it is constructed; the list is dropped when the page is torn
-- down, and a dead widget is pruned on the next pass rather than being read again.
local textWidgets = {}
-- The gate is only meaningful while this mod's own page is on screen. On any other tab the
-- player is using vanilla's own rows, which have no text box of ours to protect.
local pageActive = false
local gateHoldPolls = 0
local gateSuspended = false

function Controls.trackTextWidget(widget)
    if widget ~= nil then
        textWidgets[#textWidgets + 1] = widget
        Controls.applyInputMode()
    end
end

-- On a controller, every text box this mod places stops being a focus target: a pad has no way to
-- type into one and no reliable way back out of one, and landing in a slider row's value box left
-- the player stuck there, unable to edit it or leave (first controller pass, 2026-09-06).
-- The box still draws and still shows its value, so nothing disappears from the row; it just
-- cannot be navigated into. Restored the moment the player uses a mouse or keyboard again, so for
-- them nothing changes at all.
--
-- This is the honest state of text entry on a pad today: read it, do not edit it. Editing needs a
-- virtual keyboard, which is the open half of controller support.
local textInputMode = nil
function Controls.applyInputMode()
    local pad = Gamepad.isActive()
    if pad == textInputMode then
        return
    end
    textInputMode = pad
    -- Changing device drops any hold: the player has just picked up something else, and a gate
    -- armed by the device they put down is exactly how Escape stopped working (seen 2026-09-07).
    gateSuspended = false
    gateHoldPolls = 0
    Controls.releaseTypingGate()
    local visibility = pad and ui.textBoxGamepadVisibility or ui.textBoxVisibility
    local changed = 0
    for index = #textWidgets, 1, -1 do
        local widget = textWidgets[index]
        local alive = false
        pcall(function() alive = widget:IsValid() end)
        if not alive then
            table.remove(textWidgets, index)
        elseif pcall(function() widget:SetVisibility(visibility) end) then
            changed = changed + 1
        end
    end
    log.info("text boxes are " .. (pad and "read-only for a controller" or "editable")
        .. " (" .. changed .. " box(es))")
end
local trackTextWidget = Controls.trackTextWidget

local function warnOnce(key, message)
    if not warned[key] then
        warned[key] = true
        log.warn(message)
    end
end

function Controls.diff(last, current)
    if last == nil and current == nil then
        return false
    end
    return last ~= current
end

-- UComboBoxString.SetSelectedOption is a silent no-op when the string is not an exact option: it
-- neither errors nor changes the selection. Seeding a combo from a file value that is not in the
-- game's own option list (a stale/custom entry, or a case difference from the vanilla list) would
-- otherwise leave the widget reading "" while the caller believes `current` is showing, and the
-- next poll would stage that "" as a real edit. This reads the selection back after setting it,
-- and if the readback does not match `current` (case-insensitively - keynames canonicalize case),
-- adds `current`'s own exact spelling as an option and retries once. Returns the string that
-- should seed `handle.last`: the readback (even an unwanted "" or a mismatch, when that is what
-- the widget genuinely, stably reports - substituting `wanted` there would make handle.last claim
-- a selection the widget does not actually hold, and the very next poll would see the true "" and
-- stage it as a change, exactly what this function exists to prevent). `wanted` is returned only
-- when the readback itself could not be taken at all (a throwing getter, a destroyed widget) - a
-- genuine failure to observe, not an observed-but-undesired value.
function Controls.seedSelection(widget, current)
    local wanted = tostring(current)
    local function readback()
        local value = nil
        pcall(function() value = widget:GetSelectedOption() end)
        if value ~= nil and type(value) ~= "string" then
            pcall(function() value = value:ToString() end)
        end
        return value
    end
    pcall(function() widget:SetSelectedOption(wanted) end)
    local got = readback()
    if got == nil or got == "" or got:lower() ~= wanted:lower() then
        pcall(function() widget:AddOption(wanted) end)
        pcall(function() widget:SetSelectedOption(wanted) end)
        got = readback()
    end
    if got == nil then
        return wanted
    end
    return got
end

-- The open dropdown's rows draw the game's near-black text on a near-black menu background,
-- which is very nearly unreadable (seen 2026-09-03). UComboBoxString builds each row's text with
-- its own ForegroundColor and row style, so both are set to the theme: champagne text, raised
-- fill, gold behind the hovered and selected row. Every write is its own pcall and only ever a
-- flat FSlateColor (SpecifiedColor plus rule), never a font or brush struct read back from the
-- widget.
local function styleComboBox(widget)
    local theme = Config.ui.theme
    if not theme or not theme.enabled or theme.colors == nil then
        return
    end
    local colors = theme.colors
    local function slate(srgb)
        return { SpecifiedColor = Widgets.linearColor(srgb), ColorUseRule = 0 }
    end
    pcall(function() widget.ForegroundColor = slate(colors.champagne) end)
    for _, field in ipairs({ "TextColor", "SelectedTextColor" }) do
        pcall(function() widget.ItemStyle[field] = slate(colors.champagne) end)
    end
end

local function canvasOf(frame)
    local canvas = nil
    pcall(function() canvas = frame[ui.canvasField] end)
    if canvas == nil or not canvas:IsValid() then
        return nil
    end
    return canvas
end

function Controls.createComboBox(frame, choices, current)
    local canvas = canvasOf(frame)
    if canvas == nil then
        warnOnce("combo-canvas", "row frame has no " .. ui.canvasField .. "; dropdowns fall back")
        return nil
    end
    local widget = Widgets.construct(ui.comboBoxClass, frame)
    if widget == nil then
        warnOnce("combo-class", ui.comboBoxClass .. " cannot be constructed; dropdowns fall back")
        return nil
    end
    local ok = pcall(function()
        for _, choice in ipairs(choices) do
            widget:AddOption(choice)
        end
    end)
    if not ok then
        pcall(function() widget:RemoveFromParent() end)
        warnOnce("combo-options", "PalComboBoxString rejected AddOption; dropdowns fall back")
        return nil
    end
    styleComboBox(widget)
    if Widgets.placeInCanvas(canvas, widget, ui.comboLayout) == nil then
        pcall(function() widget:RemoveFromParent() end)
        return nil
    end
    -- Declared before it is built, because the `set` closure below refers to `handle`: inside a
    -- table constructor the name is not a local yet, so it resolved to a nil GLOBAL and every
    -- call to set() threw "attempt to index a nil value (global 'handle')". Observed in game
    -- 2026-09-04. It made Restore to Default and preset Load silently fail on text and dropdown
    -- rows for as long as those have existed, and only became loud when the slider's value box
    -- started calling set() on every drag.
    local handle
    handle = {
        kind = "combo",
        widget = widget,
        last = Controls.seedSelection(widget, current),
        read = function()
            local value = nil
            pcall(function() value = widget:GetSelectedOption() end)
            if value ~= nil and type(value) ~= "string" then
                pcall(function() value = value:ToString() end)
            end
            return value
        end,
        set = function(value)
            handle.last = Controls.seedSelection(widget, value)
        end,
    }
    handle.replaceOptions = function(choices, current)
        pcall(function() widget:ClearOptions() end)
        pcall(function()
            for _, choice in ipairs(choices) do
                widget:AddOption(choice)
            end
        end)
        handle.last = Controls.seedSelection(widget, current)
    end
    return handle
end

-- Colors the text box to the theme: dark background, champagne text, gold while focused. The
-- vanilla EditableTextBox style is light gray on light gray, unreadable (2026-09-02). The
-- WidgetStyle struct is mutated in place and written back through SetWidgetStyle,
-- then SetForegroundColor on top, the pattern PalModOptions proved on this build
-- (Config.ui.style.editableTextBoxWidgetStyle); every step its own pcall, so a field this build
-- refuses leaves that element vanilla.
local function styleTextBox(widget)
    local theme = Config.ui.theme
    if not theme or not theme.enabled or theme.colors == nil then
        return
    end
    local function slate(srgb)
        return { SpecifiedColor = Widgets.linearColor(srgb), ColorUseRule = 0 }
    end
    local colors = theme.colors
    pcall(function()
        local style = widget.WidgetStyle
        style.ForegroundColor = slate(colors.champagne)
        style.FocusedForegroundColor = slate(colors.accent)
        style.ReadOnlyForegroundColor = slate(colors.steelGray)
        style.BackgroundColor = slate(colors.field or colors.graphite)
        local textStyle = style.TextStyle
        textStyle.ColorAndOpacity = slate(colors.champagne)
        style.TextStyle = textStyle
        widget:SetWidgetStyle(style)
    end)
    pcall(function() widget:SetForegroundColor(Widgets.linearColor(colors.champagne)) end)
end

-- `hintText`, when given, is the placeholder shown while the box is empty (SetHintText: its
-- own pcall; without it the box is simply empty). `layout` overrides the canvas placement
-- (Config.ui.controls.textLayout by default: a path box beside a Copy button is narrower).
function Controls.createTextBox(frame, text, hintText, layout)
    local canvas = canvasOf(frame)
    if canvas == nil then
        warnOnce("text-canvas", "row frame has no " .. ui.canvasField .. "; text entry stays read-only")
        return nil
    end
    local widget = Widgets.construct(ui.textBoxClass, frame)
    trackTextWidget(widget)
    if widget == nil then
        warnOnce("text-class", ui.textBoxClass .. " cannot be constructed; strings stay read-only")
        return nil
    end
    styleTextBox(widget)
    pcall(function() widget:SetText(FText(tostring(text))) end)
    if hintText ~= nil and hintText ~= "" then
        pcall(function() widget:SetHintText(FText(hintText)) end)
    end
    if Widgets.placeInCanvas(canvas, widget, layout or ui.textLayout) == nil then
        pcall(function() widget:RemoveFromParent() end)
        return nil
    end
    local function readback()
        local value = nil
        pcall(function() value = widget:GetText():ToString() end)
        return value
    end
    local seeded = readback()
    -- Declared before it is built, because the `set` closure below refers to `handle`: inside a
    -- table constructor the name is not a local yet, so it resolved to a nil GLOBAL and every
    -- call to set() threw "attempt to index a nil value (global 'handle')". Observed in game
    -- 2026-09-04. It made Restore to Default and preset Load silently fail on text and dropdown
    -- rows for as long as those have existed, and only became loud when the slider's value box
    -- started calling set() on every drag.
    local handle
    handle = {
        kind = "text",
        widget = widget,
        last = (seeded ~= nil) and seeded or tostring(text),
        read = readback,
        set = function(value)
            pcall(function() widget:SetText(FText(tostring(value))) end)
            local got = readback()
            handle.last = (got ~= nil) and got or tostring(value)
        end,
    }
    return handle
end

-- A text box that lives in a container this mod built (the Possible Entries strip's filter),
-- not in a row frame's canvas: the caller places it. Same style and handle shape as
-- Controls.createTextBox. `hintText` is the placeholder shown while the box is empty
-- (SetHintText: unproven on this build, its own pcall; without it the box is simply empty).
function Controls.createBareTextBox(outer, text, hintText)
    local widget = Widgets.construct(ui.textBoxClass, outer)
    trackTextWidget(widget)
    if widget == nil then
        warnOnce("bare-text-class", ui.textBoxClass .. " cannot be constructed; strip filters are absent")
        return nil
    end
    styleTextBox(widget)
    pcall(function() widget:SetText(FText(tostring(text or ""))) end)
    if hintText ~= nil and hintText ~= "" then
        pcall(function() widget:SetHintText(FText(hintText)) end)
    end
    local function readback()
        local value = nil
        pcall(function() value = widget:GetText():ToString() end)
        return value
    end
    local seeded = readback()
    -- Declared before it is built, because the `set` closure below refers to `handle`: inside a
    -- table constructor the name is not a local yet, so it resolved to a nil GLOBAL and every
    -- call to set() threw "attempt to index a nil value (global 'handle')". Observed in game
    -- 2026-09-04. It made Restore to Default and preset Load silently fail on text and dropdown
    -- rows for as long as those have existed, and only became loud when the slider's value box
    -- started calling set() on every drag.
    local handle
    handle = {
        kind = "text",
        widget = widget,
        last = (seeded ~= nil) and seeded or tostring(text or ""),
        read = readback,
        set = function(value)
            pcall(function() widget:SetText(FText(tostring(value))) end)
            local got = readback()
            handle.last = (got ~= nil) and got or tostring(value)
        end,
    }
    return handle
end

-- `options.commitOnBlur` holds a control's changes back until the player leaves the box, instead
-- of firing on every keystroke the poll happens to catch. A slider's value box needs this: its
-- change handler pulls the number into the bar's range and onto its step, so committing per
-- keystroke rewrote "5" into the range minimum before the "0" of "50" could be typed - the box
-- fought the player (seen 2026-09-04). Everything else still commits as it changes, which is
-- what a search box or a plain string field wants.
function Controls.register(handle, id, onChange, options)
    registered[id] = { handle = handle, onChange = onChange,
        commitOnBlur = options ~= nil and options.commitOnBlur or false,
        pending = nil, wasFocused = false, everFocused = false, settleTicks = 0 }
end

function Controls.unregister(id)
    registered[id] = nil
end

function Controls.clear()
    registered = {}
    textWidgets = {}
    Controls.releaseTypingGate()
end

-- True when any registered text control reports keyboard focus, so Panel.stepMod can decline to
-- page mods on a q/e keypress the player meant as text (a widget missing HasKeyboardFocus reads
-- as not focused, never as an error).
-- All three tests, not just the first: an EditableTextBox is a wrapper whose INNER editable
-- text holds the focus, so HasKeyboardFocus alone reports false while the player is typing and
-- the Backspace gate never closes, which is why Backspace still left the screen (2026-09-03).
-- The same three tests are what Palpedia Enhancer's search box uses live on this build.
local FOCUS_TESTS = { "HasKeyboardFocus", "HasAnyUserFocus", "HasFocusedDescendants" }

-- Whether this one control holds keyboard focus right now. Same three tests as the gate below,
-- for the same reason: the wrapper reports false while its inner editable text holds the focus.
function Controls.isFocused(handle)
    if handle == nil or handle.widget == nil then
        return false
    end
    for _, test in ipairs(FOCUS_TESTS) do
        local ok, focused = pcall(function() return handle.widget[test](handle.widget) end)
        if ok and focused then
            return true
        end
    end
    return false
end

-- Both lists, never one: every box built (which is what "ALL text boxes" needs) AND every
-- registered text control (which is what the q/e paging gate has always relied on). A superset
-- of the old behavior, so nothing that used to close the gate stops closing it.
-- Told by the screen when this mod's page is shown or hidden. Hiding releases the gate, because
-- a text box of ours can still be reporting focus long after the player has moved to another tab.
function Controls.setPageActive(active)
    active = active and true or false
    if pageActive == active then
        return
    end
    pageActive = active
    if not active then
        gateSuspended = false
        gateHoldPolls = 0
        Controls.releaseTypingGate()
    end
end

function Controls.anyTextFocused()
    for index = #textWidgets, 1, -1 do
        local widget = textWidgets[index]
        local alive = false
        pcall(function() alive = widget:IsValid() end)
        if not alive then
            table.remove(textWidgets, index)
        else
            for _, test in ipairs(FOCUS_TESTS) do
                local ok, focused = pcall(function() return widget[test](widget) end)
                if ok and focused then
                    return true
                end
            end
        end
    end
    for _, entry in pairs(registered) do
        if entry.handle.kind == "text" and Controls.isFocused(entry.handle) then
            return true
        end
    end
    return false
end

-- Backspace closing the whole Options screen while a text box is focused is not a UMG
-- input-mode concern (Palpedia Enhancer tried UIOnly/GameAndUI input modes in-game and neither
-- stopped it, and both corrupted unrelated engine state on release - see that project's
-- SetTypingInputMode). It is a CommonUI action (cancel/close mappings), gated off by
-- PalUIUtility.SetEnableCommonUIInput(worldContext, flagName, isEnable), the same lever Palpedia
-- Enhancer's search box uses, called from Lua the same way i18n.lua already calls a static
-- library method. The flag name is unique to this mod so nothing else's gate is touched, and the
-- call is only ever made on a state change, never every poll.
local TYPING_GATE_FLAG = "UniversalConfigManagerTyping"
local typingGateHeld = false

-- Every outcome is logged once, because the previous version returned SILENTLY when the library
-- or the game instance could not be found: pcall reported success, nothing was written to the
-- log, and "no warning" was mistaken for "the gate is working". A gate that cannot be reached
-- has to say so.
local gateOutcomeLogged = {}
local function logGateOutcome(outcome)
    if gateOutcomeLogged[outcome] then
        return
    end
    gateOutcomeLogged[outcome] = true
    if outcome == "called" then
        log.info("Backspace gate: SetEnableCommonUIInput reached")
    else
        log.warn("Backspace gate: " .. outcome .. " - Backspace may still close the screen while typing")
    end
end

-- The world context the call needs. FindFirstOf is the documented way to reach the game instance,
-- but it is not present in every UE4SS Lua environment, so a HUD found the same way inject.lua
-- already finds one, and finally the options screen itself, stand in. Any live UObject in the
-- world satisfies a WorldContextObject parameter.
local function worldContextForGate()
    local found = nil
    if FindFirstOf == nil then
        return nil, "FindFirstOf is not available in this UE4SS Lua environment"
    end
    -- Real live instances only. A class object is not a world context, and handing the engine
    -- the wrong kind of object is the same unproven native call this file just learned not to
    -- make.
    for _, finder in ipairs({
        function() return FindFirstOf("PalGameInstance") end,
        function() return FindFirstOf("PalPlayerController") end,
        function() return FindFirstOf("PalHUDInGame") end,
    }) do
        local ok, candidate = pcall(finder)
        if ok and candidate ~= nil then
            local alive = false
            pcall(function() alive = candidate:IsValid() end)
            if alive then
                found = candidate
                break
            end
        end
    end
    if found == nil then
        return nil, "no live world context object was found"
    end
    return found
end

local function setCommonUiInputGate(enabled)
    -- Each global named separately: "one of these three is missing" told us nothing useful the
    -- first time this fired in game (2026-09-04), which is the whole reason the gate had never
    -- once run without anyone knowing.
    local missing = {}
    for _, name in ipairs({ "StaticFindObject", "FindFirstOf", "FName" }) do
        if _G[name] == nil then
            missing[#missing + 1] = name
        end
    end
    if StaticFindObject == nil then
        logGateOutcome("StaticFindObject is missing (" .. table.concat(missing, ", ") .. ")")
        return
    end
    local outcome = nil
    local ok = pcall(function()
        local library = StaticFindObject("/Script/Pal.Default__PalUIUtility")
        if library == nil or not library:IsValid() then
            outcome = "PalUIUtility not found"
            return
        end
        local context, reason = worldContextForGate()
        if context == nil then
            outcome = reason
            return
        end
        -- A REAL FName or nothing. Passing a Lua string where the engine expects an FName is a
        -- native write of the wrong shape, and a pcall does not catch the access violation that
        -- follows. Doing exactly that killed the game mid-test on 2026-09-04:
        -- the missing-global check had been relaxed, so the call went ahead without one.
        -- Tested by CALLING it, not by its Lua type. UE4SS exposes these constructors as callable
        -- tables, not functions, so `type(FName) ~= "function"` rejected a perfectly good FName
        -- and the gate reported it missing for the whole life of this file. The same guard was
        -- wrong about FText, which this file's own neighbours have been calling successfully all
        -- along (in game, 2026-09-04: the build reports FAnsiString, FString, FUtf8String as
        -- functions and neither FName nor FText, yet row captions render).
        local flag = nil
        local built = FName ~= nil and pcall(function() flag = FName(TYPING_GATE_FLAG) end)
        if not built or flag == nil then
            outcome = "FName would not build the flag (" .. type(FName) .. ")"
            return
        end
        library:SetEnableCommonUIInput(context, flag, enabled)
        outcome = "called"
        if #missing > 0 then
            outcome = "called, working around missing " .. table.concat(missing, ", ")
        end
    end)
    if not ok then
        outcome = "SetEnableCommonUIInput raised"
    end
    logGateOutcome(outcome or "the call returned without reaching the game")
end

-- Called every poll tick while a page is open: holds the CommonUI gate closed (Backspace
-- suppressed) for as long as any registered text control has keyboard focus, and releases it the
-- instant none do. A no-op when the held state already matches, so this never calls the engine
-- function on every tick, only on the actual transition.
-- Closed the instant any box reports focus; released only after focus has been gone for
-- Config.ui.controls.typingGateReleasePolls consecutive checks. The close action fires on key
-- RELEASE, so a Backspace let go of just as focus drops has to land while the gate is still
-- shut - the same reason Palpedia Enhancer holds its own session until the key is physically up.
local gateReleaseCountdown = 0

-- The gate exists for ONE keyboard problem: Palworld's close action fires on Backspace release,
-- so deleting a character used to shut the options screen. It is wrong on a controller, where
-- CommonUI input is what moves focus and presses B to leave a field: holding it there left the
-- player locked inside a text box, unable to type in it or get out (first controller pass,
-- 2026-09-06; the log shows the gate closing at 23:23:57, exactly then). A pad has no
-- Backspace, so there is nothing to guard against and the gate does not run.
function Controls.updateTypingGate()
    if Gamepad.isActive() then
        if typingGateHeld then
            typingGateHeld = false
            gateReleaseCountdown = 0
            setCommonUiInputGate(true)
            log.info("typing gate released: input moved to a controller")
        end
        return
    end
    if not pageActive then
        if typingGateHeld then
            typingGateHeld = false
            gateReleaseCountdown = 0
            setCommonUiInputGate(true)
        end
        return
    end
    local focused = Controls.anyTextFocused()
    -- One clean poll with nothing focused re-arms the gate after a suspension.
    if not focused then
        gateSuspended = false
    end
    if focused and not gateSuspended then
        gateReleaseCountdown = ui.typingGateReleasePolls or 6
    elseif gateReleaseCountdown > 0 then
        gateReleaseCountdown = gateReleaseCountdown - 1
    end
    local shouldHold = gateReleaseCountdown > 0 and not gateSuspended
    if shouldHold then
        gateHoldPolls = gateHoldPolls + 1
        if gateHoldPolls > (ui.typingGateMaxHoldPolls or 120) then
            -- A box that reports focus forever, with the player unable to blur it, used to leave
            -- the game's own Back action dead. Whatever the cause, the gate lets go.
            gateSuspended = true
            shouldHold = false
            gateReleaseCountdown = 0
            log.warn("typing gate held for too long with a text box still reporting focus; "
                .. "releasing it so Escape and Back keep working")
        end
    else
        gateHoldPolls = 0
    end
    if shouldHold == typingGateHeld then
        return
    end
    typingGateHeld = shouldHold
    setCommonUiInputGate(not shouldHold)
end

-- Releases a held gate immediately (page torn down, panel destroyed): never leave Backspace
-- suppressed for the rest of the session because the page that held it stopped polling.
function Controls.releaseTypingGate()
    if typingGateHeld then
        typingGateHeld = false
        setCommonUiInputGate(true)
    end
end

-- How many settled polls a blur-commit control waits before committing on a build where focus
-- can never be read. Only reachable when the three focus tests never once returned true for that
-- control; on a build where they work, focus loss is the trigger and this is never consulted.
local SETTLE_POLLS = 3

-- Fires a blur-commit control's held value. Safe to call when there is nothing held.
local function commit(entry)
    if entry.pending == nil then
        return false
    end
    local value = entry.pending
    entry.pending = nil
    entry.settleTicks = 0
    pcall(entry.onChange, value)
    return true
end

-- Commits every held value now, whatever the focus says: the page is closing, or the player has
-- pressed Apply. MUST run before the widgets are destroyed - reading a dead one is not something
-- a pcall can save - so the caller flushes first and tears down second.
function Controls.commitPending()
    local committed = 0
    for _, entry in pairs(registered) do
        if entry.commitOnBlur and commit(entry) then
            committed = committed + 1
        end
    end
    return committed
end

function Controls.poll()
    local changed = 0
    local snapshot = {}
    for id, entry in pairs(registered) do
        snapshot[#snapshot + 1] = { id = id, entry = entry }
    end
    for _, item in ipairs(snapshot) do
        local id, entry = item.id, item.entry
        if registered[id] == entry then
            local ok, value = pcall(entry.handle.read)
            if ok and value ~= nil and Controls.diff(entry.handle.last, value) then
                entry.handle.last = value
                changed = changed + 1
                if entry.commitOnBlur then
                    entry.pending = value
                    entry.settleTicks = 0
                else
                    pcall(entry.onChange, value)
                end
            end
            if entry.commitOnBlur then
                local focused = Controls.isFocused(entry.handle)
                entry.everFocused = entry.everFocused or focused
                if entry.wasFocused and not focused then
                    commit(entry)
                elseif entry.pending ~= nil and not focused and not entry.everFocused then
                    -- Focus has never once been readable on this control, so there is no blur to
                    -- wait for; commit once the typing has stopped rather than never at all.
                    entry.settleTicks = entry.settleTicks + 1
                    if entry.settleTicks >= SETTLE_POLLS then
                        commit(entry)
                    end
                end
                entry.wasFocused = focused
            end
        end
    end
    return changed
end

return Controls
