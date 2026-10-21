-- Builds option rows. Switch and slider rows use the game's own WBP_OptionSettings_ListContent_C
-- frame (switch/slider child respectively). Multi-choice values (enum) and every
-- clickable row (the mod list, back button, and dropdowns) are built on the native
-- WBP_OptionSettings_MenuButton_C, since this game's own options screen has no dropdown/combobox
-- widget to build on. Section headers are BP_PalTextBlock_C raw widgets.
--
-- Interaction hooks are class-level and shared with vanilla's rows; RowTrack filters them. A
-- change only STAGES a value; nothing is committed until the screen's Apply.
local Clipboard = require("clipboard")
local Config = require("config")
local Controls = require("controls")
local Entries = require("entries")
local Gamepad = require("gamepad")
local HookParam = require("hook_param")
local RowTrack = require("rowtrack")
local Staging = require("staging")
local Widgets = require("widgets")
local log = require("logger")

local Rows = {}

local ui = Config.ui
local FRAME_ASSET = ui.listContentAsset
local FRAME_PATH = FRAME_ASSET .. ".WBP_OptionSettings_ListContent_C"
local SWITCH_CLASS = ui.switchClass
local SLIDER_CLASS = ui.sliderClass
local TEXT_PATH = ui.textBlockAsset .. ".BP_PalTextBlock_C"
local MENU_BUTTON_CLASS = ui.menuButtonAsset .. ".WBP_OptionSettings_MenuButton_C"
local BUTTON_BASE_CLASS = ui.buttonBaseAsset .. ".WBP_PalCommonButtonBase_C"
local INVISIBLE_BUTTON_CLASS = ui.invisibleButtonAsset .. ".WBP_PalInvisibleButton_C"

local labels = {}   -- [frame address] = caption, re-applied on every frame Construct
local controlsByAddress = {}   -- [frame address] = the Controls handle a combo-box row carries
local hooksInstalled = false

-- The live 14 pt label of a row frame this mod already built: the font reference every text
-- block we construct copies. A parented, rendered BP_PalTextBlock_C in the same widget tree is
-- a better reference than the screen's own variable (the first attempt read that variable and
-- text still rendered at UMG's default size in a 2026-09-03 22:51 screenshot).
local fontReference = nil
local fontResultLogged = false

local function rememberFontReference(frame)
    if fontReference ~= nil or frame == nil then
        return
    end
    pcall(function()
        local label = frame[ui.theme.frameLabel]
        if label ~= nil and label:IsValid() then
            fontReference = label
        end
    end)
    -- Anything built before this moment asked for the font and got nothing; give it to them now.
    if fontReference ~= nil then
        Rows.applyPendingFonts()
    end
end

-- Gives a text block the row label's font, copied verbatim (SetFont(reference.Font), the only
-- form proven on this build; a mutated copy aborted the game). Logs once
-- whether the copy actually happened, so a screenshot of oversized text has a matching log
-- line instead of silence. Off with theme.copyFont = false.
-- Text blocks built before any list row existed, so before there was a font to copy.
local pendingFont = {}
-- Bumped on every page teardown; a delayed callback that captured an older value does nothing.
local generation = 0

-- Applies the row-label font to everything that asked for it before the reference existed.
-- Called when the reference is first captured and again from the panel's poll.
function Rows.applyPendingFonts()
    if fontReference == nil then
        return
    end
    for index = #pendingFont, 1, -1 do
        local text = pendingFont[index]
        table.remove(pendingFont, index)
        Rows.copyFont(text)
    end
end

-- Drops every reference this file holds into a page's widgets. MUST run whenever a page is torn
-- down: `fontReference` is a live row label and the queues hold text blocks and buttons, so after
-- a teardown they are all dangling pointers. Touching one from the poll crashed the game leaving
-- the Presets page for All Mods (2026-09-04). IsValid() is not enough on its own, because a
-- destroyed UObject's slot can be reused by an unrelated live object; dropping the references at
-- the moment of teardown is what makes the later checks meaningful.
function Rows.resetTransient()
    generation = generation + 1
    fontReference = nil
    pendingFont = {}
end

function Rows.copyFont(text)
    local theme = ui.theme
    if not theme or not theme.copyFont or text == nil then
        return
    end
    -- The reference is a live row label, so it does not exist until the first list row is built.
    -- A page's file header row and its Copy caption are built BEFORE that, so they used to miss
    -- the font silently and render at UMG's default size, which is roughly 50 px against the
    -- rows' 30, with "Copy" towering over "Size Mode" (2026-09-04). Queue instead
    -- of giving up, and apply the moment there is a font to apply.
    if fontReference == nil then
        pendingFont[#pendingFont + 1] = text
        return
    end
    -- Both sides must still be alive. A pcall does NOT catch an access violation raised inside
    -- UE4SS while it walks a destroyed object, so the guard has to come first.
    local alive = false
    pcall(function() alive = text:IsValid() and fontReference:IsValid() end)
    if not alive then
        return
    end
    local ok, err = pcall(function() text:SetFont(fontReference.Font) end)
    if not fontResultLogged then
        fontResultLogged = true
        log.info("row-label font copy: " .. (ok and "applied" or ("failed: " .. tostring(err))))
    end
end

local labelRoutesLogged = {}

-- Sets a row or button's caption. FText() is required; a raw Lua string is rejected.
--
-- Two routes, because the direct field access works on the LIST ROW class but leaves the small
-- MenuButton blank: the Copy button rendered as an empty outlined box in every frame of the
-- 2026-09-04 session, caption set or not, glyph or word. `GetWidgetFromName` is how
-- `styleMenuButton` already reaches that same widget's parts on this build, so it is the proven
-- route here. Which one worked is logged once, so a blank caption is never a mystery again.
local function applyLabel(frame, caption)
    local route = nil
    pcall(function()
        local label = frame.BP_PalTextBlock_Name
        if label ~= nil and label:IsValid() then
            label:SetText(FText(caption))
            route = "field"
        end
    end)
    if route == nil then
        pcall(function()
            local name = ui.theme.menuButton and ui.theme.menuButton.label or "BP_PalTextBlock_Name"
            local label = frame:GetWidgetFromName(FName(name))
            if label ~= nil and label:IsValid() then
                label:SetText(FText(caption))
                route = "GetWidgetFromName"
            end
        end)
    end
    -- Once per distinct outcome, not once overall: the list rows resolve first and would
    -- otherwise mask a button that resolves differently or not at all.
    local outcome = route or "NEITHER, caption will be blank"
    if not labelRoutesLogged[outcome] then
        labelRoutesLogged[outcome] = true
        log.info("row caption route: " .. outcome)
    end
end

-- Sets a caption AND records it as the row's settled caption. The Construct hook below re-applies
-- `labels[address]` when the row joins the live tree, which happens after the builder finished,
-- so a caption applied without this is overwritten moments later by whatever createFrame recorded.
-- That is exactly what hid "Click to Copy" until the row had been clicked once (2026-09-04):
-- the click and its revert both run on an already-live row, where Construct no longer fires.
local function rememberLabel(frame, caption)
    local address = RowTrack.addressOf(frame)
    if address ~= nil then
        labels[address] = caption
    end
    applyLabel(frame, caption)
end

-- The caption the row's own Construct will re-apply when it joins the live tree - so the caption
-- a player actually ends up reading, not the one that was set last. The suite asserts on this,
-- because asserting on the applied text alone cannot see the overwrite that follows it.
function Rows.settledLabel(frame)
    local address = RowTrack.addressOf(frame)
    return address ~= nil and labels[address] or nil
end

-- An "option" switch whose Construct hook never fired for its instance would otherwise sit
-- permanently unarmed with no log. Once per session, not once per row: this is a single systemic
-- anomaly (a hook failed to register or an owner was never resolved), not a per-row event worth
-- repeating.
local optionArmFallbackWarned = false
local function logOptionArmFallbackOnce()
    if optionArmFallbackWarned then
        return
    end
    optionArmFallbackWarned = true
    log.warn("Advanced Mode switch event before arming; ignoring")
end

local function installHooks()
    if hooksInstalled then
        return
    end
    hooksInstalled = true

    -- The frame re-resolves its caption (to "None") in its own Construct, which fires when the
    -- row joins the live tree, after the builder finished. An "option" switch (Advanced Mode)
    -- also re-asserts its own settled state here and only then arms: the widget's switch child
    -- can fire configure events of its own before this Construct runs, and those must never be
    -- read as the player toggling the row (see the option branch in the switch hook below).
    local ok, err = pcall(function()
        RegisterHook(FRAME_PATH .. ":Construct", function(Context)
            local frame = HookParam.read(Context)
            local address = RowTrack.addressOf(frame)
            if address ~= nil and labels[address] ~= nil then
                applyLabel(frame, labels[address])
            end
            local switchChild = nil
            pcall(function() switchChild = frame.WBP_OptionSettings_ListContentSwitch end)
            if switchChild ~= nil then
                local owner = RowTrack.resolve(switchChild)
                if owner ~= nil and owner.kind == "option" then
                    pcall(function() frame:SetSwitcher(owner.expected and true or false) end)
                    owner.armed = true
                end
            end
        end)
    end)
    if not ok then
        log.warn("failed to hook ListContent Construct: " .. tostring(err))
    end

    -- Switch: each handler fires on configure/re-show too, not only clicks, so the widget's own
    -- settled CurrentIsOn is what gets staged; staging an unchanged value is a no-op upstream.
    for _, event in ipairs(ui.switchChangeEvents) do
        local switchOk, switchErr = pcall(function()
            RegisterHook(SWITCH_CLASS .. ":" .. event, function(Context)
                local instance = HookParam.read(Context)
                local owner = RowTrack.resolve(instance)
                if owner == nil then
                    return
                end
                if owner.kind == "option" then
                    local isOn = nil
                    pcall(function() isOn = instance.CurrentIsOn end)
                    if isOn == nil then
                        return
                    end
                    isOn = isOn and true or false
                    if not owner.armed then
                        -- The frame's own Construct normally arms this before any real event
                        -- reaches here. If Construct never fired for this instance (hook
                        -- registration failed, the switch child resolved differently, RowTrack
                        -- missed the owner), a settled no-change event still arrives and must not
                        -- leave the row permanently unresponsive: treat it as the arming signal.
                        -- A DIFFERENT value this early is not trustworthy as the player's intent,
                        -- so it is logged once and ignored rather than staged.
                        if isOn == owner.expected then
                            owner.armed = true
                        else
                            logOptionArmFallbackOnce()
                        end
                        return
                    end
                    if isOn == owner.expected then
                        return
                    end
                    owner.expected = isOn
                    if owner.onToggle ~= nil then
                        ExecuteInGameThreadWithDelay(0, function()
                            pcall(owner.onToggle, isOn)
                        end)
                    end
                    return
                end
                if owner.kind ~= "switch" and owner.kind ~= "switch01" then
                    return
                end
                local isOn = nil
                pcall(function() isOn = instance.CurrentIsOn end)
                if isOn ~= nil then
                    if owner.kind == "switch01" then
                        Staging.stage(owner.id, isOn and 1 or 0)
                    else
                        Staging.stage(owner.id, isOn and true or false)
                    end
                end
            end)
        end)
        if not switchOk then
            log.warn("failed to hook switch event: " .. tostring(switchErr))
        end
    end

    -- Slider: fires on every change during a drag; staging is cheap.
    local sliderOk, sliderErr = pcall(function()
        RegisterHook(SLIDER_CLASS .. ":" .. ui.sliderChangeEvent, function(Context, Value)
            local instance = HookParam.read(Context)
            local owner = RowTrack.resolve(instance)
            if owner == nil or owner.kind ~= "slider" then
                return
            end
            local numeric = tonumber(HookParam.read(Value))
            if numeric ~= nil then
                -- Snapped to the setting's own unit before it goes anywhere. A bar whose step
                -- resolved to 0 runs continuously, and a drag then staged 0.80525404214859 for a
                -- scale the author writes to one decimal.
                numeric = Rows.snapToUnit(numeric, owner)
                owner.value = numeric
                Staging.stage(owner.id, numeric)
                pcall(function()
                    instance[ui.theme.sliderValueText]:SetText(FText(Rows.numberString(numeric)))
                end)
                -- The box beside the bar reports the value the bar is on, so dragging and
                -- typing are two views of one number rather than two numbers. Never while the
                -- player is typing in it, though: overwriting a half-typed number would be the
                -- same fight as clamping per keystroke.
                if owner.valueBox ~= nil and owner.valueBox.set ~= nil
                    and not Controls.isFocused(owner.valueBox) then
                    owner.valueBox.set(Rows.numberString(numeric))
                end
            end
        end)
    end)
    if not sliderOk then
        log.warn("failed to hook slider value event: " .. tostring(sliderErr))
    end

    -- The D-pad does NOT reach the hook above. `OnFloatValueChanged` is the Slate widget's
    -- user-interaction delegate, raised by a drag; the row's edit mode moves the bar through its
    -- own `Gamepad_LeftPress` and `Gamepad_RightPress`, which set the value without broadcasting
    -- it. So on a controller nothing was staged, the value text kept the number it started with,
    -- and no Save or Revert row ever appeared (2026-09-07: a 0.8 scale read "1", moved
    -- invisibly, and could not be saved). The value is computed here rather than read back: the
    -- bar was given this same unit as its FixedChangeValue, so the two always agree.
    local function stepSliderRow(context, direction)
        local frame = HookParam.read(context)
        if frame == nil then
            return
        end
        local child = nil
        pcall(function() child = frame.WBP_OptionSettings_ListContentSlider end)
        if child == nil or not child:IsValid() then
            return
        end
        local owner = RowTrack.resolve(child)
        if owner == nil or owner.kind ~= "slider" or type(owner.value) ~= "number" then
            return
        end
        local unit = owner.unit
        if unit == nil or unit <= 0 then
            unit = owner.step
        end
        if unit == nil or unit <= 0 then
            return
        end
        local moved = Rows.snapToUnit(owner.value + direction * unit, owner)
        if moved == owner.value then
            return
        end
        owner.value = moved
        Staging.stage(owner.id, moved)
        -- The game's own value text renders whole numbers, so a 0.8 scale showed as "1" and every
        -- press looked like nothing had happened.
        pcall(function()
            child[ui.theme.sliderValueText]:SetText(FText(Rows.numberString(moved)))
        end)
    end

    for name, direction in pairs({ [ui.rowGamepadLeft] = -1, [ui.rowGamepadRight] = 1 }) do
        local padOk, padErr = pcall(function()
            RegisterHook(FRAME_PATH .. ":" .. name, function(Context)
                stepSliderRow(Context, direction)
            end)
        end)
        if not padOk then
            log.warn("failed to hook " .. name
                .. " (a controller cannot adjust a slider): " .. tostring(padErr))
        end
    end

    -- One press can arrive twice: a mouse click raises the invisible button's BP_OnClicked AND
    -- the row's own handler. Running a file header's toggle twice looks exactly like nothing
    -- happening, so whichever path arrives first wins and the other is dropped.
    -- Weak keys: a record belongs to a row, and a rebuilt page must not be held alive by the
    -- memory of a press.
    local lastRowPress = setmetatable({}, { __mode = "k" })
    -- One line per session per path, so the log says plainly which route a press actually took
    -- when a row does not respond. This is this mod's own behavior, not the game's.
    local pressPathLogged = {}
    local function logPressPath(path)
        if pressPathLogged[path] then
            return
        end
        pressPathLogged[path] = true
        log.info("row press arrived via " .. path)
    end
    local function dispatchRowPress(widget, owner, path)
        logPressPath(path .. (owner == nil and " (no owner)"
            or (owner.onClick == nil and " (no action)" or "")))
        if owner == nil or owner.kind ~= "button" or owner.onClick == nil then
            return
        end
        -- Keyed on the ACTION, not the widget: the two routes arrive with different widgets
        -- (the button, and the row that holds it) carrying one shared record, so a widget key
        -- would never see the duplicate it exists to catch.
        local now = os.clock()
        local previous = lastRowPress[owner]
        if previous ~= nil and (now - previous) < ui.rowPressDedupeSeconds then
            return
        end
        lastRowPress[owner] = now
        ExecuteInGameThreadWithDelay(0, function()
            pcall(owner.onClick)
        end)
    end

    -- A press from a CONTROLLER lands on the row, whose own handler broadcasts its OnClicked
    -- delegate; the invisible button's BP_OnClicked, which every mouse click raises and which
    -- this mod hooks above, never runs. That is why a file header collapsed under the mouse and
    -- did nothing under A (2026-09-07). Both paths are covered now, and a press already
    -- handled within `rowPressDedupeSeconds` is the same press arriving twice.
    local rowClickOk, rowClickErr = pcall(function()
        RegisterHook(FRAME_PATH .. ":" .. ui.rowClickEvent, function(Context)
            local frame = HookParam.read(Context)
            if frame == nil then
                return
            end
            -- The same fields resolveRowClickChild walks, inline: this hook is registered long
            -- before that helper is declared.
            local owner = nil
            for _, field in ipairs(ui.rowClickFields) do
                local child = nil
                pcall(function() child = frame[field] end)
                if child ~= nil and child:IsValid() then
                    owner = RowTrack.resolve(child)
                    break
                end
            end
            -- The frame carries the same record, and on a file header it is the only one that
            -- resolves from here.
            dispatchRowPress(frame, owner or RowTrack.resolve(frame), "the row's own handler")
        end)
    end)
    if not rowClickOk then
        log.warn("failed to hook the row's own click handler (a controller cannot press a row): "
            .. tostring(rowClickErr))
    end

    -- Clicks for mod-list and back buttons (WBP_OptionSettings_MenuButton_C instances this mod
    -- creates inside its own page; input lands on the invisible child).
    local buttonOk, buttonErr = pcall(function()
        RegisterHook(BUTTON_BASE_CLASS .. ":BP_OnClicked", function(Context)
            local widget = HookParam.read(Context)
            dispatchRowPress(widget, RowTrack.resolve(widget), "the button's click")
        end)
    end)
    if not buttonOk then
        log.warn("failed to hook button clicks: " .. tostring(buttonErr))
    end

    -- Focus, for a controller. WBP_PalCommonButtonBase_C derives from CommonUI's CommonButtonBase
    -- (its import table names /Script/CommonUI.CommonButtonBase, build 24575825), so every button
    -- this mod places is already focusable and actionable by a gamepad; what it had no way to show
    -- was WHERE the focus was. These are Blueprint functions on the same class whose BP_OnClicked
    -- is hooked above, so they cost nothing new to reach.
    --
    -- The game's own rows do not need this: WBP_OptionSettings_ListContent ships Base_Focus and an
    -- Anm_NormalToFocus animation and lights itself up. Only the buttons built here, out of a
    -- Border and a text block, had nothing.
    local function repaintFocus(context, focused)
        local owner = RowTrack.resolve(HookParam.read(context))
        if owner == nil or owner.kind ~= "button" or owner.focus == nil then
            return
        end
        local edge = owner.focus.edge
        if edge == nil or not edge:IsValid() then
            return
        end
        Rows.paintEdge(edge, focused and ui.controls.actionRow.focusEdge or owner.focus.restRole)
    end

    for event, focused in pairs({ OnAddedToFocusPath = true, OnRemovedFromFocusPath = false }) do
        local focusOk, focusErr = pcall(function()
            RegisterHook(BUTTON_BASE_CLASS .. ":" .. event, function(Context)
                repaintFocus(Context, focused)
            end)
        end)
        if not focusOk then
            log.warn("failed to hook " .. event .. " (no focus outline on a controller): "
                .. tostring(focusErr))
        end
    end

    -- Our buttons' captions reset in their own Construct, like row labels do.
    local buttonLabelOk, buttonLabelErr = pcall(function()
        RegisterHook(MENU_BUTTON_CLASS .. ":Construct", function(Context)
            local button = HookParam.read(Context)
            local address = RowTrack.addressOf(button)
            if address ~= nil and labels[address] ~= nil then
                applyLabel(button, labels[address])
            end
        end)
    end)
    if not buttonLabelOk then
        log.warn("failed to hook MenuButton Construct: " .. tostring(buttonLabelErr))
    end
end

-- `maxWidth` is the room the row's own control leaves for the caption. A caption longer than
-- that used to be drawn straight over the control beside it: measured 2026-09-06 over the 1464
-- catalogued settings, 74 ran under a text box or dropdown and 148 under a slider's value box,
-- the worst by 564 units. Nothing wraps in this panel, so it is trimmed (project rule: a
-- too-long caption is shortened at its source). Omitted means the row has no control to collide
-- with and the caption is left alone.
local function createFrame(worldContext, caption, maxWidth)
    if maxWidth ~= nil then
        caption = Rows.truncateToWidth(caption, maxWidth)
    end
    installHooks()
    local frame = Widgets.createUserWidget(worldContext, FRAME_PATH, FRAME_ASSET)
    if frame == nil then
        return nil
    end
    local address = RowTrack.addressOf(frame)
    if address ~= nil then
        labels[address] = caption
    end
    applyLabel(frame, caption)
    rememberFontReference(frame)
    return frame
end

-- ============================== Restyle ==============================

-- Once per session, the first time a restyle pass actually runs: evidence the pass executed.
-- Whether any individual setter took effect is in-game-only (config.lua's Config.ui.style
-- findings record what is proven vs. unproven per property).
local restyleAppliedLogged = false
local function logRestyleAppliedOnce()
    if restyleAppliedLogged then
        return
    end
    restyleAppliedLogged = true
    log.info("restyle applied")
end

-- The palette recorded in Config.ui.theme is sRGB (hex/255), the readable, checkable source of
-- truth. UMG color setters (SetColorAndOpacity, SetFillColorAndOpacity) take FLinearColor,
-- which is linear light, not gamma-encoded sRGB: feeding sRGB fractions straight in renders
-- visibly dull (the standard sRGB EOTF, IEC 61966-2-1).
Rows.linearColor = Widgets.linearColor

-- Converted once per role, not once per row: the theme palette never changes at runtime.
local linearColorCache = {}
local function linearColorFor(role, srgb)
    local cached = linearColorCache[role]
    if cached == nil then
        cached = Rows.linearColor(srgb)
        linearColorCache[role] = cached
    end
    return cached
end

-- Tints the row's exposed children toward the theme. Every setter is its own pcall: a property
-- this build does not expose leaves the vanilla look for that element, never an error. The
-- switch/slider child lookups are pcall-wrapped too (this file's convention: bare field access
-- on these widgets can throw on this build), and a nil child skips the rest of that kind's work.
-- Repaints one action button's outer border. Public so the focus hooks, which are installed
-- above this point in the file, reach it through the module table rather than as an upvalue that
-- is not in scope yet.
function Rows.paintEdge(widget, role)
    local theme = ui.theme
    if widget == nil or role == nil or theme == nil or not theme.enabled then
        return
    end
    pcall(function()
        widget:SetBrushColor(linearColorFor(role, theme.colors[role]))
    end)
end

function Rows.applyStyle(frame, kind)
    local theme = ui.theme
    if not theme or not theme.enabled or frame == nil then
        return
    end
    logRestyleAppliedOnce()
    local colors = theme.colors
    pcall(function()
        frame[theme.frameLabel]:SetColorAndOpacity({ SpecifiedColor = linearColorFor("champagne", colors.champagne) })
    end)
    pcall(function() frame[theme.frameBase]:SetColorAndOpacity(linearColorFor("graphite", colors.graphite)) end)
    if kind == "switch" then
        local child = nil
        pcall(function() child = frame.WBP_OptionSettings_ListContentSwitch end)
        if child == nil then
            return
        end
        local accent = linearColorFor("accent", colors.accent)
        for _, name in ipairs(theme.switchOn) do
            pcall(function() child[name]:SetColorAndOpacity(accent) end)
        end
        -- OFF is raised gray, never the game's blue (design system, Palworld UMG surface).
        local raised = linearColorFor("field", colors.field)
        for _, name in ipairs(theme.switchOff or {}) do
            pcall(function() child[name]:SetColorAndOpacity(raised) end)
        end
        -- The hover frames are not variables: fetched by name, tinted gold.
        for _, name in ipairs(theme.switchHover or {}) do
            pcall(function()
                local hover = child:GetWidgetFromName(FName(name))
                if hover ~= nil and hover:IsValid() then
                    hover:SetColorAndOpacity(accent)
                end
            end)
        end
        -- The two captions (pak dump: BP_PalTextBlock_C in CanvasPanelON, BP_PalTextBlock_C_41
        -- in CanvasPanelOFF, neither a variable). ON sits on the gold fill, so its caption is
        -- black; white on gold is light on light and unreadable.
        local captions = theme.switchCaptions
        if captions ~= nil then
            local function tintCaption(name, role)
                pcall(function()
                    local block = child:GetWidgetFromName(FName(name))
                    if block ~= nil and block:IsValid() then
                        block:SetColorAndOpacity({ SpecifiedColor = linearColorFor(role, colors[role]) })
                    end
                end)
            end
            tintCaption(captions.on, "black")
            tintCaption(captions.off, "steelGray")
        end
    elseif kind == "slider" then
        local child = nil
        pcall(function() child = frame.WBP_OptionSettings_ListContentSlider end)
        if child == nil then
            return
        end
        local accent = linearColorFor("accent", colors.accent)
        local champagne = linearColorFor("champagne", colors.champagne)
        pcall(function() child[theme.sliderFill]:SetFillColorAndOpacity(accent) end)
        pcall(function() child[theme.sliderValueText]:SetColorAndOpacity({ SpecifiedColor = champagne }) end)
        if theme.sliderHandle ~= nil then
            pcall(function() child[theme.sliderHandle]:SetSliderHandleColor(champagne) end)
        end
        if theme.sliderTrack ~= nil then
            -- The track is the bar style's background brush: the same WidgetStyle
            -- copy-mutate-write styleTextBox proved live on EditableTextBox.
            pcall(function()
                local bar = child[theme.sliderTrack]
                local style = bar.WidgetStyle
                local background = style.BackgroundImage
                background.TintColor = { SpecifiedColor = linearColorFor("hairline", colors.hairline), ColorUseRule = 0 }
                style.BackgroundImage = background
                bar:SetWidgetStyle(style)
            end)
        end
    end
end

-- The live 14 pt label of a row frame this mod already built: the font reference every text
-- block we construct copies. A parented, rendered BP_PalTextBlock_C in the same widget tree is
-- a better reference than the screen's own variable (the first attempt read
-- Config.ui.theme.fontReference off the options screen and text still rendered at UMG's
-- default size in a 2026-09-03 22:51 screenshot).
-- An arrow drawn from the game's own texture (Config.ui.theme.icon), rotated to `angle` and
-- tinted to `role`. Returns the Image widget, or nil when the texture or the Image class is
-- unavailable on this build (the caller then shows text only).
function Rows.createIcon(worldContext, angle, role)
    local theme = ui.theme
    if not theme or theme.icon == nil then
        return nil
    end
    local icon = theme.icon
    local texture = StaticFindObject(icon.textureObject)
    if texture == nil or not texture:IsValid() then
        pcall(function() LoadAsset(icon.texturePath) end)
        texture = StaticFindObject(icon.textureObject)
    end
    if texture == nil or not texture:IsValid() then
        return nil
    end
    local image = Widgets.construct("/Script/UMG.Image", worldContext)
    if image == nil then
        return nil
    end
    local ok = pcall(function() image:SetBrushFromTexture(texture, true) end)
    if not ok then
        pcall(function() image:RemoveFromParent() end)
        return nil
    end
    pcall(function() image:SetDesiredSizeOverride({ X = icon.width, Y = icon.height }) end)
    pcall(function() image:SetRenderTransformAngle(angle or 0) end)
    if theme.enabled then
        pcall(function() image:SetColorAndOpacity(linearColorFor(role or "steelGray", theme.colors[role or "steelGray"])) end)
    end
    return image
end

-- Places `icon` in a row frame's canvas at the label column (leading) or the right inset
-- (trailing); a leading icon shifts the label right by rowIconInset so they never overlap.
local function placeRowIcon(frame, icon, trailing)
    local canvas = nil
    pcall(function() canvas = frame[ui.controls.canvasField] end)
    if canvas == nil or icon == nil then
        return
    end
    local theme = ui.theme
    local size = theme.icon
    if trailing then
        Widgets.placeInCanvas(canvas, icon, { anchorMinX = 1, anchorMinY = 0.5, anchorMaxX = 1,
            anchorMaxY = 0.5, alignX = 1, alignY = 0.5, x = -theme.rowIconInset, y = 0,
            w = size.width, h = size.height })
    else
        Widgets.placeInCanvas(canvas, icon, { anchorMinX = 0, anchorMinY = 0.5, anchorMaxX = 0,
            anchorMaxY = 0.5, alignX = 0, alignY = 0.5, x = theme.rowLabelOriginX, y = 0,
            w = size.width, h = size.height })
        pcall(function()
            local slot = frame[theme.frameLabel].Slot
            local position = slot:GetPosition()
            slot:SetPosition({ X = position.X + theme.rowIconInset, Y = position.Y })
        end)
    end
end

-- A steel-gray note after a row's label (a setting count, a request count), placed at the
-- label's estimated end at the 14 pt label size.
-- RIGHT-ALIGNED at the row's right inset, so it can never run into the label however long the
-- mod's name is (seen 2026-09-03 22:51: a note placed after an estimated label
-- width printed straight through the name). `rightInset` leaves room for a trailing icon.
local function placeRowNote(frame, worldContext, note, rightInset)
    local canvas = nil
    pcall(function() canvas = frame[ui.controls.canvasField] end)
    if canvas == nil or note == nil or note == "" then
        return
    end
    local text = Rows.createSection(worldContext, note, "muted")
    if text == nil then
        return
    end
    -- An AUTO-SIZED slot, so the slot takes the text's own desired size and the right alignment
    -- can then offset by it. A 0x0 fixed slot has nothing to offset by, so the note began at the
    -- row's right edge and ran off it: the copy request's "2068 settings still lack a description
    -- or entries" rendered as "205" and every mod's count was sliced the same way (2026-09-04).
    -- SetAutoSize is a UCanvasPanelSlot method, the same native slot this file already calls
    -- SetAnchors, SetAlignment and SetPosition on. Do NOT reach for SetJustification here:
    -- BP_PalTextBlock_C is a Blueprint UserWidget, not a UTextBlock, and calling that function
    -- on it took the game down with an access violation inside UE4SS (2026-09-04).
    Widgets.placeInCanvas(canvas, text, { anchorMinX = 1, anchorMinY = 0.5, anchorMaxX = 1,
        anchorMaxY = 0.5, alignX = 1, alignY = 0.5,
        x = -(rightInset or ui.theme.rowIconInset), y = 0, w = 0, h = 0, autoSize = true })
end

-- Styles one WBP_OptionSettings_MenuButton_C instance this mod placed (a strip headline, a
-- preset action) to a design-system button variant: "quiet" (no box, steel gray caption),
-- "secondary" (no fill, hairline frame, champagne caption), "danger" (amber fill and frame,
-- black caption). The box, frame and tab decorations are not variables on the widget, so they
-- are fetched by name through GetWidgetFromName (config.lua records the evidence); every call
-- is its own pcall and a refused one leaves that part vanilla. A no-op when the theme is off.
function Rows.styleMenuButton(button, variant, worldContext)
    local theme = ui.theme
    if not theme or not theme.enabled or button == nil or theme.menuButton == nil then
        return
    end
    pcall(function() Rows.copyFont(button[theme.menuButton.label]) end)
    local names = theme.menuButton
    local colors = theme.colors
    local function child(name)
        local found = nil
        pcall(function() found = button:GetWidgetFromName(FName(name)) end)
        if found == nil or not found:IsValid() then
            return nil
        end
        return found
    end
    local function tint(name, role)
        local widget = child(name)
        if widget ~= nil then
            pcall(function() widget:SetColorAndOpacity(linearColorFor(role, colors[role])) end)
        end
    end
    local function collapse(name)
        local widget = child(name)
        if widget ~= nil then
            pcall(function() widget:SetVisibility(ui.pageInactiveVisibility) end)
        end
    end
    local function caption(role)
        pcall(function()
            button[names.label]:SetColorAndOpacity({ SpecifiedColor = linearColorFor(role, colors[role]) })
        end)
    end
    collapse(names.tabEffects)
    if variant == "invisible" then
        -- Input only: every painted part collapsed and the caption emptied, so the widget
        -- contributes a hit area and nothing else. The visible text is then ours, placed exactly
        -- where we want it. This exists because the game's menu button bakes in its own frame art
        -- AND centres its caption, and neither can be changed from here: left-justifying needs a
        -- UTextBlock method the Blueprint does not have, and calling it crashed the game
        -- (2026-09-04). Its hit area lives on the WBP_PalInvisibleButton child, which is left
        -- alone, so clicks keep working through the same hook as every other button here.
        collapse(names.base)
        collapse(names.frame)
        collapse(names.focusFrame)
        pcall(function() button[names.label]:SetText(FText("")) end)
        -- Collapsing the parts we can name was not enough: the box still painted, with Copy
        -- rendering ON it (2026-09-04). Tinting the widget itself with a zero alpha
        -- multiplies the WHOLE subtree, including any part this file has no name for, so nothing
        -- it draws can survive. SetColorAndOpacity is the setter this file already uses on rows,
        -- images and captions; our own caption is a sibling in the row's canvas, not a child of
        -- this button, so it is unaffected.
        pcall(function()
            button:SetColorAndOpacity(linearColorFor("transparent", colors.transparent))
        end)
    elseif variant == "quiet" then
        collapse(names.base)
        collapse(names.frame)
        caption("steelGray")
    elseif variant == "secondary" then
        tint(names.base, "transparent")
        tint(names.frame, "hairline")
        caption("champagne")
    elseif variant == "danger" then
        tint(names.base, "amber")
        tint(names.frame, "amber")
        caption("black")
    end
end

-- The slider value text's canvas slot is re-laid so the number ends where the bar begins
-- (geometry in Config.ui.theme.valueTextSlot): a fixed-size, right-justified box instead of
-- vanilla's left-anchored auto-size one. A layout fix, not a theme tint: applied
-- unconditionally so it holds with theme.enabled = false, each setter its own pcall.
local function applySliderValueLayout(child)
    local theme = ui.theme
    if not theme or child == nil or theme.valueTextSlot == nil then
        return
    end
    local box = theme.valueTextSlot
    local text = nil
    pcall(function() text = child[theme.sliderValueText] end)
    if text == nil then
        return
    end
    local slot = nil
    pcall(function() slot = text.Slot end)
    if slot ~= nil then
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetPosition({ X = box.x, Y = box.y }) end)
        pcall(function() slot:SetSize({ X = box.w, Y = box.h }) end)
    end
    pcall(function() text:SetJustification(2) end)
end

-- ============================== Builders ==============================

-- Collapses every control child the row frame can carry (switch, slider, LR selector, button,
-- checkbox) except `keepChild`, so a full-width row shows only its caption and click target
-- instead of every control the frame's Blueprint defines at once (seen 2026-09-01:
-- an uncollapsed row showed a slider, a switch, an LR selector, and a checkbox simultaneously).
-- Each child is only ever touched through pcall: a name absent on this build is a silent no-op.
local function collapseUnusedRowChildren(frame, keepChild)
    for _, field in ipairs(ui.rowButtonCollapsedChildren) do
        pcall(function()
            local child = frame[field]
            if child ~= nil and child ~= keepChild and child:IsValid() then
                child:SetVisibility(ui.pageInactiveVisibility)
            end
        end)
    end
end

-- `asNumber` marks a 0/1 flag stored as a number: the row shows a switch but stages 1/0.
function Rows.createSwitch(worldContext, id, caption, value, asNumber)
    local frame = createFrame(worldContext, caption)
    if frame == nil then
        return nil
    end
    local child = nil
    pcall(function() child = frame.WBP_OptionSettings_ListContentSwitch end)
    if child == nil or not child:IsValid() then
        pcall(function() frame:RemoveFromParent() end)
        return nil
    end
    local on = asNumber and value ~= 0 or (not asNumber and value)
    pcall(function() frame:SetSwitcher(on and true or false) end)
    RowTrack.track(child, { kind = asNumber and "switch01" or "switch", id = id })
    Rows.applyStyle(frame, "switch")
    return frame
end

-- Bounds come from the caller (bounds.lua derives them from comments, the mod's own code, the
-- key's name, or the value, in that order).
function Rows.createSlider(worldContext, id, caption, value, minValue, maxValue, step, unit)
    local frame = createFrame(worldContext, caption,
        Rows.labelRoom(ui.controls.sliderValueLayout))
    if frame == nil then
        return nil
    end
    local child = nil
    pcall(function() child = frame.WBP_OptionSettings_ListContentSlider end)
    if child == nil or not child:IsValid() then
        pcall(function() frame:RemoveFromParent() end)
        return nil
    end
    -- Every OTHER control child collapsed, the slider kept. This is what lets the row be edited
    -- with a controller, and it is not cosmetic: the row's own click handler dispatches on child
    -- VISIBILITY, and if the switch, the clickable button or the key-config button is visible it
    -- branches there and returns. Only a row that reaches the end of that chain flips `Editing`,
    -- and flipping `Editing` is what registers the SettingLeft, SettingRight and SettingBack
    -- bindings that move the bar (bytecode of WBP_OptionSettings_ListContent, 2026-09-07).
    -- Left and right are D-pad only, in vanilla too.
    collapseUnusedRowChildren(frame, child)
    -- SetSlider(CurrentValue, Min, Max, FixedChangeValue, UseFixedValue). Its own last act is
    -- BackToList, so it must never be re-called on a row the player is editing: that would
    -- unregister those bindings mid-edit and make left and right die under their hands.
    --
    -- An empty range is refused rather than passed on: SetSlider computes its step as
    -- FixedChangeValue / (Max - Min), so Max == Min divides by zero and every press then moves
    -- the bar by a value that is not a number.
    if maxValue <= minValue then
        pcall(function() frame:RemoveFromParent() end)
        return nil
    end
    -- A controller moves the bar by the VALUE'S OWN unit, not by the drag grid: one press goes
    -- 1 to 2 on a whole-numbered setting, 1.0 to 1.1 on one written to a decimal. The grid a
    -- mouse drags on is sized for roughly fifty stops across the range, so on a pad it meant
    -- many presses before the number beside the bar changed at all (seen 2026-09-07). A mouse
    -- keeps the grid, and keeps the typed box for anything the grid cannot reach.
    local barStep = step
    if Gamepad.isActive() and unit ~= nil and unit > 0 then
        barStep = unit
    end
    pcall(function() frame:SetSlider(value, minValue, maxValue, barStep, barStep > 0) end)
    -- The game's own value text renders whole numbers, so a 0.8 scale sat there reading "1" until
    -- something moved it, and a mouse drag walked "1", "2", "3" while the real value moved in
    -- hundredths (2026-09-07). It is written here at build and on every change, both
    -- devices, so the number beside a bar is never the game's rounding of it.
    pcall(function()
        child[ui.theme.sliderValueText]:SetText(FText(Rows.numberString(value)))
    end)
    local record = { kind = "slider", id = id, min = minValue, max = maxValue, step = step,
        unit = (unit ~= nil and unit > 0) and unit or nil, value = value }
    RowTrack.track(child, record)
    applySliderValueLayout(child)
    Rows.applyStyle(frame, "slider")

    -- On a controller the row stays EXACTLY as vanilla builds it: the game's own value text, and
    -- no editable box. That is what makes it work with a pad at all - the frame already owns
    -- Gamepad_LeftPress, Gamepad_RightPress, AddValue and SubtractValue and drives the slider it
    -- was given by SetSlider above, and our box was sitting on top of that, swallowing the A press
    -- and trapping the player in a field a pad cannot type into.
    --
    -- On a mouse and keyboard the box is what it always was: a continuous bar (step 0) cannot be
    -- nudged onto a round value at all, and even a stepped one only reaches its own grid, so the
    -- number is typed as well as dragged. Rows are rebuilt when the input device changes, so a
    -- player who puts the pad down gets the box straight back.
    if Gamepad.isActive() then
        return frame
    end
    local handle = Controls.createTextBox(frame, Rows.numberString(value), nil,
        ui.controls.sliderValueLayout)
    if handle ~= nil then
        record.valueBox = handle
        -- The game's own value text would otherwise sit under the box showing a stale number.
        pcall(function() child[ui.theme.sliderValueText]:SetVisibility(ui.pageInactiveVisibility) end)
        Rows.attachControl(frame, handle)
    end
    return frame
end

-- The value a slider row commits when the player types into its box: the number they entered,
-- pulled back inside the bar's own range, and put on the bar's grid when it has one so the
-- number and the bar can never disagree. Returns nil for anything that is not a number, which
-- the caller shows as the unchanged value rather than staging a guess.
--
-- Pure, and the suite drives it: pulling a typed value into the slider's range is arithmetic,
-- so it belongs where it can be checked without a widget.
function Rows.normalizeSliderValue(text, minValue, maxValue, step)
    local numeric = tonumber((tostring(text):gsub(",", "."):match("^%s*(.-)%s*$")))
    if numeric == nil then
        return nil
    end
    if minValue ~= nil and numeric < minValue then
        numeric = minValue
    end
    if maxValue ~= nil and numeric > maxValue then
        numeric = maxValue
    end
    if step ~= nil and step > 0 and minValue ~= nil then
        local grid = minValue + math.floor((numeric - minValue) / step + 0.5) * step
        -- Rounding to the grid must never push the value back out of the range it was just
        -- pulled into.
        if maxValue ~= nil and grid > maxValue then
            grid = grid - step
        end
        if grid >= minValue then
            numeric = grid
        end
    end
    -- Float arithmetic leaves 50.000000000000007 behind; a player typed "50".
    local rounded = tonumber(string.format("%.6f", numeric))
    return rounded or numeric
end

-- A switch that drives one of this mod's OWN options (Advanced Mode) rather than staging a
-- config value: its change calls onToggle(isOn) on the game thread. `expected` is the settled
-- state the switch must show; `armed` stays false until the frame's own Construct re-asserts it
-- (see installHooks), so a configure-time event that fires before then is never mistaken for the
-- player toggling the row.
function Rows.createOptionSwitch(worldContext, caption, isOn, onToggle)
    local frame = createFrame(worldContext, caption)
    if frame == nil then
        return nil
    end
    local child = nil
    pcall(function() child = frame.WBP_OptionSettings_ListContentSwitch end)
    if child == nil or not child:IsValid() then
        pcall(function() frame:RemoveFromParent() end)
        return nil
    end
    local expected = isOn and true or false
    pcall(function() frame:SetSwitcher(expected) end)
    RowTrack.track(child, { kind = "option", onToggle = onToggle, expected = expected, armed = false })
    Rows.applyStyle(frame, "switch")
    return frame
end

-- Which of Config.ui.rowClickFields actually resolved on this build, logged once per session
-- (evidence the in-game log can confirm which path is live), and the fallback-to-menu-button
-- case logged once if every field lookup failed.
local rowClickFieldLogged = false
local rowButtonFallbackWarned = false

-- Takes a row OUT of the game's editing mode. Pressing A on a row whose control children are all
-- hidden sets `Editing = true`, and that registers SettingLeft, SettingRight and SettingBack on the
-- SCREEN, pointing back at the row (bytecode, 2026-09-07). `BackToList` is what
-- unregisters them. A row destroyed while still editing leaves those bindings on the screen
-- forever, and SettingBack is Escape and B: that is why the options screen could not be left after
-- using this tab, even after switching to a vanilla tab (2026-09-07). Every row this mod
-- destroys is taken out of edit mode first, and every click we handle on a row's own target leaves
-- it immediately, so the state never outlives the press.
local function leaveEditMode(frame)
    pcall(function() frame:BackToList() end)
end

local function resolveRowClickChild(frame)
    for _, field in ipairs(ui.rowClickFields) do
        local child = nil
        pcall(function() child = frame[field] end)
        if child ~= nil and child:IsValid() then
            if not rowClickFieldLogged then
                rowClickFieldLogged = true
                log.info("full-width row click target resolved via " .. field)
            end
            return child
        end
    end
    return nil
end

local function logRowButtonFallbackOnce()
    if rowButtonFallbackWarned then
        return
    end
    rowButtonFallbackWarned = true
    log.warn("no full-width row click target resolved (checked "
        .. table.concat(ui.rowClickFields, ", ") .. ") - using the fallback menu button")
end


-- A full-width clickable row (the mod list and the back row): the game's own row frame with
-- its click target tracked as a button owner, so it reads like every setting row instead of a
-- narrow category-button copy. Falls back to the menu button when none of Config.ui.rowClickFields
-- resolves on this build.
-- `options`: { leadingIcon = angle, trailingIcon = angle, note = text }: an arrow before the
-- label (the back row), an arrow at the row's right edge (a row that opens a page), a
-- steel-gray note after the label (a count). Each is optional and degrades to nothing.
function Rows.createRowButton(worldContext, caption, onClick, options)
    local frame = createFrame(worldContext, caption)
    if frame == nil then
        return Rows.createModButton(worldContext, caption, onClick)
    end
    local clickChild = resolveRowClickChild(frame)
    if clickChild == nil then
        pcall(function() frame:RemoveFromParent() end)
        logRowButtonFallbackOnce()
        return Rows.createModButton(worldContext, caption, onClick)
    end
    collapseUnusedRowChildren(frame, clickChild)
    -- SetConfigButton is NOT called. It is the key-rebind setter, and its real signature takes
    -- three arguments (FName ActionName, ECommonInputType, EPalKeyConfigAxisFilterType), which is
    -- why calling it bare logged "failed" for months. Called properly it would show the row's
    -- key-config child and make every press broadcast OnKeyConfigClicked instead, so this row
    -- could never be used (bytecode, 2026-09-07).
    local record = { kind = "button", onClick = function()
        -- The press that ran this also put the row into the game's editing mode; leave it before
        -- doing anything, so nothing is registered on the screen once this row is gone.
        leaveEditMode(frame)
        if onClick ~= nil then
            onClick()
        end
    end }
    RowTrack.track(clickChild, record)
    -- The FRAME carries the same record. A controller press runs the row's own handler, which
    -- reaches this mod with the row rather than the button, and on a file header the button's
    -- record could not be resolved from there at all: the log read "row press arrived via the
    -- row's own handler (no owner)" while the same press on a plain row resolved fine
    -- (2026-09-07). Whichever widget the press arrives with, the action is now found.
    RowTrack.track(frame, record)
    Rows.applyStyle(frame, "button")
    options = options or {}
    if options.leadingIcon ~= nil then
        local icon = Rows.createIcon(worldContext, options.leadingIcon, "champagne")
        placeRowIcon(frame, icon, false)
        -- A caller that toggles (a file header) keeps the icon so it can rotate it.
        if options.iconOut ~= nil then
            options.iconOut.widget = icon
        end
    end
    if options.trailingIcon ~= nil then
        placeRowIcon(frame, Rows.createIcon(worldContext, options.trailingIcon, "steelGray"), true)
    end
    if options.note ~= nil then
        -- A trailing chevron owns the right inset; the note sits clear of it.
        local inset = ui.theme.rowIconInset
        if options.trailingIcon ~= nil then
            inset = inset + (ui.theme.icon and ui.theme.icon.width or 12) + ui.theme.rowNoteGap
        end
        placeRowNote(frame, worldContext, options.note, inset)
    end
    return frame
end

-- A dropdown row's closed-state caption ("Caption:  Value   [change]"). The one place this text
-- is built, so the initial row and every later re-label (a fresh selection, Apply, Restore to
-- Default) can never drift apart. Used only by the inline-expansion fallback; a combo-mode row
-- never shows this text, the game's own combo box carries the caption instead.
local function dropdownLabel(caption, value)
    return caption .. ":  " .. tostring(value) .. "   [change]"
end

-- Ties a live control handle (from Controls.createComboBox) to the row frame that carries it.
-- Address-keyed rather than a field on the widget: UE4SS userdata may refuse an arbitrary field,
-- and this keeps the lookup identical to every other RowTrack-adjacent table in this file.
function Rows.attachControl(frame, handle)
    local address = RowTrack.addressOf(frame)
    if address ~= nil then
        controlsByAddress[address] = handle
    end
end

function Rows.controlOf(frame)
    local address = RowTrack.addressOf(frame)
    if address == nil then
        return nil
    end
    return controlsByAddress[address]
end

-- Once per session: which dropdown mode is actually live on this build, so the in-game log
-- states plainly whether the game's own combo box built or the inline fallback took over.
local dropdownModeLogged = false
local function logDropdownModeOnce(mode)
    if dropdownModeLogged then
        return
    end
    dropdownModeLogged = true
    log.info("dropdown rows: " .. (mode == "combo" and "native combo box"
        or "inline expansion fallback"))
end

-- A dropdown row. Combo mode: the game's own PalComboBoxString built into the row frame right
-- where the switch and slider sit; the panel's poll loop stages selection changes, and no click
-- handler is involved. Inline mode (the combo could not be built on this run): today's clickable
-- closed row whose choices the caller inserts directly under it via onToggle.
-- Two shapes. With a mouse, the game's own PalComboBoxString: one row, a list that drops over the
-- page. With a controller, the INLINE shape instead - a row that opens its choices as rows beneath
-- it - because a combo box is a mouse control: its popup is not part of the focus path, so a pad
-- can open it and then reach nothing inside it. Inline choices are ordinary rows, which a pad
-- already navigates.
function Rows.createDropdown(worldContext, id, caption, choices, value, onToggle)
    local frame = not Gamepad.isActive() and createFrame(worldContext, caption,
        Rows.labelRoom(ui.controls.comboLayout)) or nil
    if frame ~= nil then
        collapseUnusedRowChildren(frame, nil)
        local handle = Controls.createComboBox(frame, choices, value)
        if handle ~= nil then
            Rows.attachControl(frame, handle)
            logDropdownModeOnce("combo")
            Rows.applyStyle(frame, "control")
            return frame, "combo"
        end
        pcall(function() frame:RemoveFromParent() end)
    end
    logDropdownModeOnce("inline")
    return Rows.createModButton(worldContext, dropdownLabel(caption, value), function()
        pcall(onToggle)
    end), "inline"
end

-- One choice row inside an open dropdown: clicking stages the value and asks the caller to
-- collapse. `isCurrent` marks the presently-set choice with a "> " prefix; every other row gets
-- matching indentation so the open list reads as subordinate to the closed row above it.
function Rows.createDropdownChoice(worldContext, label, isCurrent, onSelect)
    local prefix = isCurrent and "> " or "    "
    return Rows.createModButton(worldContext, prefix .. label, function()
        pcall(onSelect)
    end)
end

-- Section header: the same text block vanilla heads its settings groups with. Wrapping is off,
-- as on every text this mod builds: a caption that cannot fit the list width is shortened at
-- its source, never folded onto a second line.
-- `role` picks the design-system treatment: "title" (Forged Gold, upper case: a mod's name, a
-- page's heading), "muted" (Steel Gray: a file path, a notice, an empty-state line), nil
-- (Soft Champagne body text). Upper-casing touches ASCII letters only, so a name in another
-- script is left as written. The tint is a no-op when the theme is off.
function Rows.createSection(worldContext, caption, role)
    if StaticFindObject(TEXT_PATH) == nil then
        pcall(function() LoadAsset(ui.textBlockAsset) end)
    end
    local text = Widgets.construct(TEXT_PATH, worldContext)
    if text == nil then
        return nil
    end
    local shown = caption
    if role == "title" then
        shown = tostring(caption):upper()
    end
    pcall(function() text:SetText(FText(shown)) end)
    pcall(function() text:SetWrapTextWidth(0) end)
    pcall(function() text:SetAutoWrapText(false) end)
    local theme = ui.theme
    if theme and theme.enabled then
        local colorRole = role == "title" and "accent" or role == "muted" and "steelGray" or "champagne"
        pcall(function()
            text:SetColorAndOpacity({ SpecifiedColor = linearColorFor(colorRole, theme.colors[colorRole]) })
        end)
    end
    Rows.copyFont(text)
    return text
end

-- Rewrites a text block built by Rows.createSection. The on-screen keyboard repaints its preview
-- on every key rather than rebuilding the page, which would tear down the key the player is
-- standing on.
function Rows.setSectionText(widget, caption)
    if widget == nil then
        return false
    end
    return pcall(function() widget:SetText(FText(tostring(caption))) end)
end

-- A read-only value line ("key = value"), used only when Rows.createTextEntry could not build a
-- control on this run (no canvas field, or the text box class failed to construct).
function Rows.createText(worldContext, caption)
    return Rows.createSection(worldContext, "    " .. caption)
end

-- A string is shown the way it is written in the file (a Lua "\27[31m" reads as \27[31m in the
-- box) and parsed back the same way, so escapes survive an edit; the format serializer then
-- writes it correctly. Single-pass in both directions: a chained sequence of gsub calls would
-- re-scan output from an earlier pass (a literal backslash escaped by the first gsub would then
-- be matched again by a later one), corrupting any value that already contains a backslash -
-- "C:\temp" would show as "C:\\temp" and parse back to "C:<TAB>emp" once the "\t" pass ran over
-- the doubled backslash's second character.
local DISPLAY_ESCAPES = {
    ["\\"] = "\\\\",
    ["\27"] = "\\27",
    ["\n"] = "\\n",
    ["\t"] = "\\t",
    ["\r"] = "\\r",
}

function Rows.displayString(value)
    return (tostring(value):gsub("[\\\27\n\t\r]", DISPLAY_ESCAPES))
end

-- A number as a player would write it: "50", not "50.0" and not "49.999999999999996". The same
-- %.14g the parsers use to write a number back into a config file, so what the box shows is what
-- the file will say.
function Rows.numberString(value)
    if type(value) ~= "number" then
        return tostring(value)
    end
    return (string.format("%.14g", value))
end

-- Puts a number on the setting's own grid: whole numbers for a whole-numbered setting, tenths for
-- one the author wrote to one decimal. The bar itself cannot be relied on for this, since a range
-- no step divides runs continuously, and a drag then produces 0.80525404214859 for a scale whose
-- every documented value has one decimal place (2026-09-07). Snapping happens once, on the
-- way into staging, so the number staged, the number shown and the number written all agree.
function Rows.snapToUnit(value, record)
    local unit = record ~= nil and record.unit or nil
    if type(value) ~= "number" or type(unit) ~= "number" or unit <= 0 then
        return value
    end
    local snapped = math.floor(value / unit + 0.5) * unit
    -- Float multiplication leaves 0.7000000000000001; the unit's own precision is the answer's.
    local places = 0
    local scale = unit
    while places < 6 and math.abs(scale - math.floor(scale + 0.5)) > 1e-9 do
        scale = scale * 10
        places = places + 1
    end
    snapped = tonumber(string.format("%." .. places .. "f", snapped)) or snapped
    if record.min ~= nil and snapped < record.min then
        snapped = record.min
    end
    if record.max ~= nil and snapped > record.max then
        snapped = record.max
    end
    return snapped
end

-- A filesystem path, shown and copied the way Windows writes one: single backslashes, all the way
-- along. displayString is wrong for a path in two ways at once - it escapes each backslash into
-- two, because for a config VALUE a backslash really is an escape character - and the paths
-- themselves arrive mixed, since UE4SS reports the script directory with forward slashes while
-- its directory walker returns backslashes. Both showed in the same panel (2026-09-04:
-- the presets folder read "D:/Steam/.../UniversalConfigManagerDev\presets" while a config file's
-- folder read "D:\Steam\...\AntiPhatPalResizing\Scripts"). The copied text is normalized too:
-- what the player pastes should be what the player was shown.
function Rows.displayPath(value)
    local path = tostring(value):gsub("/", "\\")
    -- A leading "\\" is a UNC server prefix and is the one run of separators that means something,
    -- so it is put back after the rest are collapsed.
    local unc = path:sub(1, 2) == "\\\\"
    path = path:gsub("\\\\+", "\\")
    if unc then
        path = "\\" .. path
    end
    return path
end

-- Manual scanner, not gsub: walks the string once, so an escape sequence is only ever consumed
-- by the branch that recognizes it, never re-matched by a later pass.
function Rows.parseDisplayString(text)
    local out = {}
    local i = 1
    local len = #text
    while i <= len do
        local ch = text:sub(i, i)
        if ch == "\\" and i < len then
            local rest = text:sub(i + 1)
            local digits = rest:match("^(%d%d?%d?)")
            local next = text:sub(i + 1, i + 1)
            if digits ~= nil then
                local n = tonumber(digits)
                if n <= 255 then
                    out[#out + 1] = string.char(n)
                    i = i + 1 + #digits
                else
                    out[#out + 1] = "\\" .. next
                    i = i + 2
                end
            elseif next == "\\" then
                out[#out + 1] = "\\"
                i = i + 2
            elseif next == "n" then
                out[#out + 1] = "\n"
                i = i + 2
            elseif next == "t" then
                out[#out + 1] = "\t"
                i = i + 2
            elseif next == "r" then
                out[#out + 1] = "\r"
                i = i + 2
            else
                out[#out + 1] = "\\" .. next
                i = i + 2
            end
        else
            out[#out + 1] = ch
            i = i + 1
        end
    end
    return table.concat(out)
end

-- An editable free-text row, built on the game's own row frame with a plain EditableTextBox
-- dropped into its canvas (Controls.createTextBox). Falls back to nil when the control could
-- not be built, so the caller keeps the read-only Rows.createText line.
function Rows.createTextEntry(worldContext, id, caption, value)
    local frame = createFrame(worldContext, caption,
        Rows.labelRoom(ui.controls.textLayout))
    if frame == nil then
        return nil
    end
    collapseUnusedRowChildren(frame, nil)
    local handle = Controls.createTextBox(frame, Rows.displayString(value))
    if handle == nil then
        pcall(function() frame:RemoveFromParent() end)
        return nil
    end
    Rows.attachControl(frame, handle)
    Rows.applyStyle(frame, "control")
    return frame
end

-- A free-text search box: the same frame/EditableTextBox build as Rows.createTextEntry, but a
-- thin wrapper that never touches Staging - it carries no `id` and never calls Controls.register
-- itself, because the home view's search row is not a staged setting. The caller registers its
-- own onChange against the returned handle. Returns frame, handle; nil, nil when the control
-- could not be built (the caller then falls back to showing the mod list unfiltered).
function Rows.createSearchEntry(worldContext, caption, text, hintText)
    local frame = createFrame(worldContext, caption,
        Rows.labelRoom(ui.controls.textLayout))
    if frame == nil then
        return nil, nil
    end
    collapseUnusedRowChildren(frame, nil)
    local handle = Controls.createTextBox(frame, Rows.displayString(text), hintText)
    if handle == nil then
        pcall(function() frame:RemoveFromParent() end)
        return nil, nil
    end
    Rows.attachControl(frame, handle)
    Rows.applyStyle(frame, "control")
    return frame, handle
end

-- A one-line header: the same text block as createSection, but with wrapping disabled so a short
-- notice never breaks across two lines. Used for the relaunch notice only.
function Rows.createHeaderLine(worldContext, caption)
    if StaticFindObject(TEXT_PATH) == nil then
        pcall(function() LoadAsset(ui.textBlockAsset) end)
    end
    local text = Widgets.construct(TEXT_PATH, worldContext)
    if text == nil then
        return nil
    end
    pcall(function() text:SetText(FText(caption)) end)
    -- A notice line WRAPS, where a row's caption never does. It is a sentence rather than a
    -- label, it has no control beside it to collide with, and there is nothing to trim it back
    -- to: the reload notice ran off the end of its line and stopped mid-word at "No game restart
    -- n" (seen 2026-09-07). Measured at the 14 pt row font that sentence is 915 units wide and
    -- it was cut at 849, so the line is wrapped at `Config.ui.noticeWidth`, which is inside what
    -- the screen proved it has. Longer translations wrap onto a further line rather than vanish.
    pcall(function() text:SetWrapTextWidth(ui.noticeWidth) end)
    pcall(function() text:SetAutoWrapText(true) end)
    local theme = ui.theme
    if theme and theme.enabled then
        pcall(function()
            text:SetColorAndOpacity({ SpecifiedColor = linearColorFor("steelGray", theme.colors.steelGray) })
        end)
    end
    Rows.copyFont(text)
    return text
end

-- Hover text for a row. The only place a setting's description is ever shown: nothing renders
-- inline. A widget that refuses the call simply has no tooltip.
function Rows.setTooltip(widget, text)
    if widget == nil or text == nil or text == "" then
        return
    end
    pcall(function() widget:SetToolTipText(FText(text)) end)
end

-- A clickable button (the mod list and the back button), built from the same native menu
-- button the category tabs use.
function Rows.createModButton(worldContext, label, onClick)
    installHooks()
    local button = Widgets.createUserWidget(worldContext, MENU_BUTTON_CLASS,
        ui.menuButtonAsset)
    if button == nil then
        return nil
    end
    local address = RowTrack.addressOf(button)
    if address ~= nil then
        labels[address] = label
    end
    applyLabel(button, label)
    local owner = { kind = "button", onClick = onClick }
    local invisible = nil
    pcall(function() invisible = button.WBP_PalInvisibleButton end)
    if invisible ~= nil and invisible:IsValid() then
        RowTrack.track(invisible, owner)
    end
    RowTrack.track(button, owner)
    return button
end

-- ============================== Embedded buttons ==============================

-- [container address] = { button, ... }: menu buttons living inside a container this mod built
-- (a preset row's three action buttons, a Possible Entries panel's toggle), so Rows.destroy can
-- untrack each one when the container is torn down. RemoveFromParent on the container detaches
-- the whole subtree; this table only exists so RowTrack never keeps a stale owner mapping alive
-- under a freed address (the same concern controlsByAddress exists for).
local embeddedButtonsByAddress = {}

-- Rows whose OWN click target this mod collapsed, which is every action row and nothing else.
-- Focus has to go to the buttons inside one of those, since focusing a collapsed widget focuses
-- nothing at all. Every other row keeps its own target, its vanilla highlight and its own press,
-- and reaches an embedded button through left and right instead.
local collapsedOwnTargetByAddress = {}

local function relabel(widget, caption)
    local address = RowTrack.addressOf(widget)
    if address ~= nil then
        labels[address] = caption
    end
    applyLabel(widget, caption)
end
Rows.relabel = relabel

-- ============================== Possible Entries strip ==============================

-- One body line: the game's own text block at its default size. NEVER SetFont here: reading
-- `block.Font` and handing the copy back aborted the game inside UE4SS.dll at the main menu
-- (2026-09-03, Workshop dll), and a pcall cannot catch an abort. Champagne for an entry the
-- player can type, steel gray for a line that is this mod's inference. Wrapping off, as on
-- every text this mod builds; the caller pre-splits lines (Entries.fit).
local function stripLine(worldContext, text, dim, inferredTip)
    local block = Rows.createSection(worldContext, text)
    if block == nil then
        return nil
    end
    -- A dim line ends with " (?)": it is this mod's reading of the code, not the author's word.
    -- Its tooltip says so, since the marker alone explains nothing.
    if dim and inferredTip ~= nil then
        Rows.setTooltip(block, inferredTip)
    end
    local theme = ui.theme
    if theme and theme.enabled then
        local role = dim and "steelGray" or "champagne"
        pcall(function()
            block:SetColorAndOpacity({ SpecifiedColor = linearColorFor(role, theme.colors[role]) })
        end)
    end
    return block
end

-- Marks this mod's category tab as the active one (Forged Gold caption and a gold bar on its
-- left edge, the design system's active nav item) or returns it to the game's look. The bar
-- is an Image placed once in the button's own canvas (fetched by name) and toggled by
-- visibility; `state` is a table the caller keeps so the bar is built only once.
function Rows.markTab(button, active, state, worldContext)
    local theme = ui.theme
    if not theme or not theme.enabled or button == nil or theme.menuButton == nil then
        return
    end
    local role = active and "accent" or "champagne"
    pcall(function()
        button[theme.menuButton.label]:SetColorAndOpacity({ SpecifiedColor = linearColorFor(role, theme.colors[role]) })
    end)
    if state.bar == nil and worldContext ~= nil then
        local bar = Widgets.construct("/Script/UMG.Image", worldContext)
        local canvas = nil
        pcall(function() canvas = button:GetWidgetFromName(FName(theme.menuButton.canvas)) end)
        if bar ~= nil and canvas ~= nil and canvas:IsValid() then
            pcall(function() bar:SetColorAndOpacity(linearColorFor("accent", theme.colors.accent)) end)
            if Widgets.placeInCanvas(canvas, bar, { anchorMinX = 0, anchorMinY = 0, anchorMaxX = 0,
                anchorMaxY = 1, alignX = 0, alignY = 0, x = 0, y = 0, w = 3, h = 0 }) ~= nil then
                state.bar = bar
            end
        end
    end
    if state.bar ~= nil then
        pcall(function()
            state.bar:SetVisibility(active and ui.pageActiveVisibility or ui.pageInactiveVisibility)
        end)
    end
end

local function untrackButton(button)
    if button == nil then
        return
    end
    local address = RowTrack.addressOf(button)
    if address ~= nil then
        labels[address] = nil
    end
    RowTrack.untrack(button)
    pcall(function() RowTrack.untrack(button.WBP_PalInvisibleButton) end)
end

-- The Possible Entries strip under a text box: text on the page background, no border, no
-- fill, never a row frame - a row frame reads as a setting and a filled box reads as a second
-- input. A VerticalBox holding the headline (Rows.createModButton: the one click primitive this
-- mod can hook) and a body VerticalBox of a filter text box followed by one text block per
-- line, collapsed until toggled; expanding flips the body's visibility in place, so no row is
-- inserted and no label repeats.
-- Every entry is shown, never truncated: the filter box narrows the list instead, hiding the
-- blocks whose entry does not contain what was typed.
-- `lines` is { { text, dim, group }, ... } already wrapped to fit (Entries.fit); `group` ties
-- the pieces of one entry together so a filter shows or hides an entry whole. Returns { root,
-- button, filter (a Controls text handle the caller registers, or nil), expanded,
-- setExpanded(expanded, caption), setFilter(query) }, or nil when any part could not be
-- built, with every constructed widget detached (an unparented widget can be reclaimed by the
-- engine's GC, inject.lua).
function Rows.createHintPanel(worldContext, caption, lines, onToggle, filterHint, inferredTip)
    local strip = Widgets.construct("/Script/UMG.VerticalBox", worldContext)
    local body = Widgets.construct("/Script/UMG.VerticalBox", worldContext)
    local button = Rows.createModButton(worldContext, caption, onToggle)
    Rows.styleMenuButton(button, "quiet", worldContext)
    local blocks = {}
    local filterBox = nil
    -- The headline is a chevron (the game's arrow texture, right when collapsed, down when
    -- expanded) beside the quiet button, in a HorizontalBox; without the texture the button
    -- stands alone.
    local header = Widgets.construct("/Script/UMG.HorizontalBox", worldContext)
    local chevron = Rows.createIcon(worldContext, ui.theme.icon and ui.theme.icon.angleRight or 0, "steelGray")
    local function abandon()
        for _, item in ipairs(blocks) do
            pcall(function() item.widget:RemoveFromParent() end)
        end
        for _, widget in ipairs({ filterBox, chevron, button, header, body, strip }) do
            pcall(function() widget:RemoveFromParent() end)
        end
        untrackButton(button)
        return nil
    end
    if strip == nil or body == nil or button == nil then
        return abandon()
    end
    local assembled = pcall(function()
        if header ~= nil then
            if chevron ~= nil then
                local slot = header:AddChildToHorizontalBox(chevron)
                slot:SetVerticalAlignment(2)
                slot:SetPadding({ Left = 0, Top = 0, Right = 8, Bottom = 0 })
            end
            header:AddChildToHorizontalBox(button)
            strip:AddChildToVerticalBox(header)
        else
            strip:AddChildToVerticalBox(button)
        end
        strip:AddChildToVerticalBox(body)
    end)
    if not assembled then
        return abandon()
    end
    local indent = ui.controls.hint.indent
    -- The filter box: the same EditableTextBox every other text box is, held in a SizeBox of
    -- the text box width (both calls proven by the page container and the row controls). Its
    -- absence degrades to an unfiltered list, never to a missing strip.
    local filter = nil
    filterBox = Widgets.construct("/Script/UMG.SizeBox", worldContext)
    if filterBox ~= nil then
        filter = Controls.createBareTextBox(worldContext, "", filterHint)
        local placed = filter ~= nil and pcall(function()
            filterBox:SetWidthOverride(ui.controls.textLayout.w)
            filterBox:SetContent(filter.widget)
            local slot = body:AddChildToVerticalBox(filterBox)
            slot:SetHorizontalAlignment(1)
            slot:SetPadding({ Left = indent, Top = 2, Right = 0, Bottom = 6 })
        end)
        if not placed then
            pcall(function() filterBox:RemoveFromParent() end)
            filter = nil
        end
    end
    for _, line in ipairs(lines) do
        local block = stripLine(worldContext, line.text, line.dim, inferredTip)
        if block ~= nil then
            local ok, slot = pcall(function() return body:AddChildToVerticalBox(block) end)
            if ok then
                blocks[#blocks + 1] = { widget = block, group = line.group }
                if slot ~= nil then
                    pcall(function()
                        slot:SetPadding({ Left = indent, Top = 0, Right = 0, Bottom = 0 })
                    end)
                end
            end
        end
    end
    if #blocks == 0 then
        return abandon()
    end
    pcall(function() body:SetVisibility(ui.pageInactiveVisibility) end)
    -- ClipToBounds, a belt over the width estimate: unproven on this build, its own pcall.
    pcall(function() strip:SetClipping(1) end)
    local address = RowTrack.addressOf(strip)
    if address ~= nil then
        embeddedButtonsByAddress[address] = { button }
    end
    local handle = { root = strip, button = button, filter = filter, expanded = false }
    function handle.setExpanded(expanded, newCaption)
        handle.expanded = expanded and true or false
        pcall(function()
            body:SetVisibility(handle.expanded and ui.pageActiveVisibility
                or ui.pageInactiveVisibility)
        end)
        if chevron ~= nil and ui.theme.icon ~= nil then
            pcall(function()
                chevron:SetRenderTransformAngle(handle.expanded and ui.theme.icon.angleDown
                    or ui.theme.icon.angleRight)
            end)
        end
        if newCaption ~= nil then
            relabel(button, newCaption)
        end
    end
    function handle.setFilter(query)
        local visible = Entries.filterGroups(lines, query)
        for _, item in ipairs(blocks) do
            local show = visible[item.group] == true
            pcall(function()
                item.widget:SetVisibility(show and ui.pageActiveVisibility
                    or ui.pageInactiveVisibility)
            end)
        end
    end
    return handle
end




-- ============================== action rows ==============================

-- Where a row's buttons go, right to left, as pure arithmetic over the CAPTIONS. Returns one
-- { x, w } per caption in the order given, `x` being the slot position for a right-anchored,
-- right-aligned slot (so the button's right edge sits |x| from the row's right edge).
--
-- Widths come from the caption, because that is the only thing that actually decides how wide a
-- button has to be. `available` is the room the buttons may use; when the pack would exceed it
-- every width is scaled down together, so the set stays inside the row instead of the leftmost
-- button sliding out of it. Nothing here touches a widget, so the whole layout is checkable
-- offline - which is the point: every earlier version of this was fixed pixel offsets guessed
-- against a widget that ignores them.
-- The width `text` renders at in a row, as opposed to the strip estimate Entries.width returns.
-- Every caption in a row goes through Rows.copyFont to the 14 pt label font; see
-- Config.ui.labelFontScale for where the factor comes from.
-- The room a row's caption has before it reaches the control at the row's right. `layout` is one
-- of the control layouts in Config.ui.controls; its left edge is the row's real width plus its
-- (negative) right-anchored position, minus its own width.
function Rows.labelRoom(layout)
    if layout == nil then
        return nil
    end
    local theme = ui.theme
    return (ui.rowWidth + layout.x - layout.w) - theme.rowLabelOriginX - theme.rowNoteGap
end

function Rows.labelWidth(text)
    return Entries.width(text) * ui.labelFontScale
end

function Rows.packRight(captions, opts)
    opts = opts or {}
    local row = ui.controls.actionRow
    local inset = opts.inset or row.inset
    local gap = opts.gap or row.gap
    local padX = opts.padX or row.padX
    local minWidth = opts.minWidth or row.minWidth
    local maxWidth = opts.maxWidth or row.maxWidth

    -- `inner` is the room the caption has, carried out rather than recovered later as
    -- `w - padX * 2`: that subtraction does not round-trip in floating point, and coming back one
    -- ten-trillionth short made truncateToWidth cut "Save" down to "..." (measured 2026-09-06).
    local widths, inners = {}, {}
    for index, caption in ipairs(captions) do
        local caption_width = Rows.labelWidth(caption)
        local width = caption_width + padX * 2
        if width < minWidth then
            width, caption_width = minWidth, minWidth - padX * 2
        elseif width > maxWidth then
            width, caption_width = maxWidth, maxWidth - padX * 2
        end
        widths[index] = width
        inners[index] = caption_width
    end

    local count = #widths
    if count == 0 then
        return {}
    end
    -- Buttons are never shrunk to fit. The widest set this mod ships is three at maxWidth, which
    -- with its gaps and inset comes to 768 of a 1173 row, so a pack always fits; what has to give
    -- when a caption is long is the LABEL beside it, which createActionRow trims.
    -- Rows.actionRowFits proves that in every language before any of it reaches a screen.
    local placed = {}
    local right = inset
    for index = count, 1, -1 do
        placed[index] = { x = -right, w = widths[index], inner = inners[index] }
        right = right + widths[index] + gap
    end
    return placed
end

-- Does this label plus these captions actually fit one row? The offline suite asks this for every
-- action row in all 17 languages, so a translation that would push a button off the right edge is
-- a failing check here rather than a surprise in game (2026-09-06). Returns the fit, the
-- width the row would need, and the width it has.
-- The same pack, from the LEFT, with an indent. A keyboard has to look like a keyboard: rows
-- right-packed against the edge put q under 0 and a under w, which is unreadable as a layout
-- (2026-09-07: the layout was unreadable as a keyboard). Returns { x, w, inner }
-- where `x` is measured from the row's left edge.
function Rows.packLeft(captions, opts)
    opts = opts or {}
    local row = ui.controls.actionRow
    local gap = opts.gap or row.gap
    local indent = opts.indent or 0
    local placed = Rows.packRight(captions, opts)
    local left = (opts.originX or ui.theme.rowLabelOriginX) + indent
    for index = 1, #placed do
        placed[index] = { x = left, w = placed[index].w, inner = placed[index].inner,
            fromLeft = true }
        left = left + placed[index].w + gap
    end
    return placed
end

function Rows.actionRowFits(label, captions, rowWidth)
    local row = ui.controls.actionRow
    local width = rowWidth or ui.rowWidth
    local needed = Rows.labelWidth(label or "") + row.labelGap + Rows.actionRowOccupied(captions)
    return needed <= width, needed, width
end

-- How much of a row a set of buttons takes, right edge to left edge, including the inset.
function Rows.actionRowOccupied(captions)
    local rects = Rows.packRight(captions)
    if #rects == 0 then
        return 0
    end
    return -rects[1].x + rects[1].w
end

-- Shortens `text` until it fits `room`, in the same UMG units Entries.width reports, ending in
-- an ellipsis when anything was dropped. A row label is the one caption this mod cannot keep
-- short at its source: a preset's label is the name the player typed, of any length. Nothing
-- wraps in this panel (project rule), so a label that does not fit is trimmed rather than left to
-- run under the buttons beside it. Pure.
function Rows.truncateToWidth(text, room)
    text = tostring(text or "")
    if room <= 0 then
        return ""
    end
    if Rows.labelWidth(text) <= room then
        return text
    end
    local ok, points = pcall(function()
        local list = {}
        for _, cp in utf8.codes(text) do
            list[#list + 1] = cp
        end
        return list
    end)
    if not ok or points == nil then
        return text
    end
    local ellipsis = "..."
    local budget = room - Rows.labelWidth(ellipsis)
    if budget <= 0 then
        return ellipsis
    end
    local kept, width = {}, 0
    for _, cp in ipairs(points) do
        local glyph = utf8.char(cp)
        local next = width + Rows.labelWidth(glyph)
        if next > budget then
            break
        end
        kept[#kept + 1] = glyph
        width = next
    end
    if #kept == 0 then
        return ellipsis
    end
    -- A trailing space before the ellipsis reads as a typo.
    while #kept > 0 and kept[#kept] == " " do
        table.remove(kept)
    end
    return table.concat(kept) .. ellipsis
end

-- Trims a PATH to `room`, from the LEFT. The tail is what identifies a path - the folder or file
-- you are actually looking at - so trimming the tail the way truncateToWidth does would leave
-- every path on screen reading "D:" and the same first three folders. Pure.
function Rows.truncatePathToWidth(text, room)
    text = tostring(text or "")
    if room <= 0 then
        return ""
    end
    if Rows.labelWidth(text) <= room then
        return text
    end
    local ok, points = pcall(function()
        local list = {}
        for _, cp in utf8.codes(text) do
            list[#list + 1] = cp
        end
        return list
    end)
    if not ok or points == nil then
        return text
    end
    local ellipsis = "..."
    local budget = room - Rows.labelWidth(ellipsis)
    if budget <= 0 then
        return ellipsis
    end
    local kept, width = {}, 0
    for index = #points, 1, -1 do
        local glyph = utf8.char(points[index])
        local next = width + Rows.labelWidth(glyph)
        if next > budget then
            break
        end
        table.insert(kept, 1, glyph)
        width = next
    end
    if #kept == 0 then
        return ellipsis
    end
    return ellipsis .. table.concat(kept)
end

-- One button of an action row, built from parts that each honor the rect they are given:
--   * an outer Border, the button's edge (Warm Gold Shadow on gold, amber on danger, hairline on
--     the quiet variant - the design system's three button edges);
--   * an inner Border inset by one unit, the fill;
--   * the caption, in its OWN auto-sized slot centered on the pill, which is what actually turns
--     `padX` into visible padding. It cannot be centered any other way: a fixed slot has nothing
--     to offset by, and SetJustification is UTextBlock-only and took the game down with an access
--     violation when it was tried on BP_PalTextBlock_C (2026-09-04);
--   * WBP_PalInvisibleButton_C on top, the click target.
-- Returns the parts, so the caller can relabel the caption later (the Delete confirmation does).
local function placeActionButton(worldContext, canvas, rect, action)
    local row = ui.controls.actionRow
    local theme = ui.theme
    local themed = theme ~= nil and theme.enabled
    -- A filled pill takes Obsidian Black text; the quiet variant takes Soft Champagne on the
    -- raised field gray. Never a fill's own brush for its caption (design system: light on light
    -- is a defect). With the theme off nothing is tinted gold, but the pill still has to be a
    -- pill rather than a stock white box, so it falls back to the row's own graphite.
    local fills = { primary = "accent", danger = "amber" }
    local edges = { primary = "accentShadow", danger = "amber" }
    local fill = fills[action.variant] or "field"
    local edge = edges[action.variant] or "hairline"
    local filled = fills[action.variant] ~= nil
    if not themed then
        fill, edge = "graphite", "hairline"
        filled = false
    end

    -- A rect is right-anchored by default and left-anchored when the pack says so, which is how
    -- the keyboard lays its rows out as a keyboard rather than against the right edge.
    local anchor = rect.fromLeft and 0 or 1
    local function box(inset)
        local x = rect.fromLeft and (rect.x + inset) or (rect.x - inset)
        return { anchorMinX = anchor, anchorMinY = 0.5, anchorMaxX = anchor, anchorMaxY = 0.5,
            alignX = anchor, alignY = 0.5, x = x, y = 0,
            w = rect.w - inset * 2, h = row.height - inset * 2 }
    end

    local built = {}
    local function border(inset, role)
        local widget = Widgets.construct("/Script/UMG.Border", worldContext)
        if widget == nil then
            return nil
        end
        if Widgets.placeInCanvas(canvas, widget, box(inset)) == nil then
            pcall(function() widget:RemoveFromParent() end)
            return nil
        end
        pcall(function()
            widget:SetBrushColor(linearColorFor(role, (theme and theme.colors or {})[role]))
        end)
        built[#built + 1] = widget
        return widget
    end

    local outerEdge = border(0, edge)
    border(row.borderWidth, fill)

    if StaticFindObject(TEXT_PATH) == nil then
        pcall(function() LoadAsset(ui.textBlockAsset) end)
    end
    local label = Widgets.construct(TEXT_PATH, worldContext)
    if label ~= nil then
        -- Auto-sized and centered on the pill: alignX 0.5 against the pill's own center line.
        local centre = rect.fromLeft and (rect.x + rect.w / 2) or (rect.x - rect.w / 2)
        local placed = Widgets.placeInCanvas(canvas, label, {
            anchorMinX = anchor, anchorMinY = 0.5, anchorMaxX = anchor, anchorMaxY = 0.5,
            alignX = 0.5, alignY = 0.5, x = centre, y = 0,
            w = 0, h = 0, autoSize = true })
        if placed == nil then
            pcall(function() label:RemoveFromParent() end)
            label = nil
        else
            pcall(function() label:SetAutoWrapText(false) end)
            if themed then
                local role = filled and "black" or "champagne"
                pcall(function()
                    label:SetColorAndOpacity({
                        SpecifiedColor = linearColorFor(role, theme.colors[role]) })
                end)
            end
            Rows.copyFont(label)
            built[#built + 1] = label
        end
    end

    -- Last, so it sits above the pill and the caption and is what the cursor actually hits.
    local button = Widgets.createUserWidget(worldContext, INVISIBLE_BUTTON_CLASS,
        ui.invisibleButtonAsset)
    if button == nil or Widgets.placeInCanvas(canvas, button, box(0)) == nil then
        if button ~= nil then
            pcall(function() button:RemoveFromParent() end)
        end
        for _, part in ipairs(built) do
            pcall(function() part:RemoveFromParent() end)
        end
        return nil
    end
    -- `focus` is what the focus hooks below repaint. Kept on the RowTrack owner rather than in
    -- a table of our own, so it dies with the row exactly like the click handler does.
    RowTrack.track(button, { kind = "button", onClick = action.onClick,
        focus = { edge = outerEdge, restRole = edge } })
    Rows.setTooltip(button, action.tooltip)

    -- The caption is never wider than the pill it sits in: the slot is auto-sized, so nothing
    -- clips it, and a caption that outgrew its pill would draw over the button beside it.
    local innerWidth = rect.inner or (rect.w - row.padX * 2)
    local handle = { button = button, label = label, width = innerWidth }
    function handle.setCaption(text)
        if label == nil then
            return
        end
        pcall(function() label:SetText(FText(Rows.truncateToWidth(text, innerWidth))) end)
    end
    handle.setCaption(action.caption)
    return handle
end

-- A row with a caption on the left and one or more action buttons packed against its right
-- edge. `actions` is { { caption, tooltip, onClick, variant }, ... } left to right.
-- Puts a read-only path box and a Copy button on an EXISTING row, to the right of its caption:
--
--     Scripts\config.lua  [ D:\Steam\...\Scripts\config.lua ] [ Copy ]
--
-- The 2026-09-06 shape, and it replaces the separate "<label> - Click to Copy" rows that
-- used to carry a folder or file location. Those showed the path in a 400-unit box that cut
-- "D:\Steam\steamapps\com" off mid-word; a box sized from what the row actually has left is
-- several times wider, and being a text box it scrolls and stays selectable for the rest.
--
-- This was recorded as impossible on 2026-09-04 ("every such widget drew outside the row") when
-- the only button available was the game's own, which ignores the slot it is given. An action-row
-- button honors its rect, so the affordance fits now.
--
-- Returns true when both landed. `copy` is { caption, copiedCaption, tooltip }; `leftOffset` is
-- how far the row's own label has been pushed right, which a leading icon does by rowIconInset.
-- The geometry of that row, on its own so it can be checked without a screen: the button's rect,
-- and how wide the path box between it and the caption comes out. Pure.
function Rows.pathFieldGeometry(caption, copy, leftOffset)
    local row = ui.controls.actionRow
    local theme = ui.theme
    -- The button is sized for the longer of "Copy" and "Copied", so the confirmation fits it.
    local widest = copy.caption
    if Rows.labelWidth(copy.copiedCaption) > Rows.labelWidth(widest) then
        widest = copy.copiedCaption
    end
    local rect = Rows.packRight({ widest })[1]
    local captionEnd = theme.rowLabelOriginX + (leftOffset or 0) + Rows.labelWidth(caption)
        + theme.rowNoteGap
    local fieldRight = row.inset + rect.w + row.gap
    return rect, fieldRight, ui.rowWidth - fieldRight - captionEnd
end

function Rows.addPathField(frame, worldContext, caption, fullPath, copy, leftOffset, rowActivates)
    local canvas = nil
    pcall(function()
        local field = frame[ui.controls.canvasField]
        if field ~= nil and field:IsValid() then
            canvas = field
        end
    end)
    if canvas == nil then
        return false
    end
    local row = ui.controls.actionRow
    local rect, fieldRight, fieldWidth = Rows.pathFieldGeometry(caption, copy, leftOffset)
    if fieldWidth < ui.controls.pathFieldMinWidth then
        return false
    end

    local handle = Controls.createTextBox(frame, Rows.displayPath(fullPath), nil,
        { anchorMinX = 1, anchorMinY = 0.5, anchorMaxX = 1, anchorMaxY = 0.5,
            alignX = 1, alignY = 0.5, x = -fieldRight, y = 0,
            w = fieldWidth, h = row.height })
    if handle == nil then
        return false
    end
    pcall(function() handle.widget:SetIsReadOnly(true) end)
    -- A pad must never land on this box. It cannot be typed into, it draws no focus of its own,
    -- and while it holds the focus the row's own press goes nowhere: the file header showed no
    -- selection and would not expand, while right still reached the Copy button beyond it
    -- (2026-09-07). Read-only is not the same as unfocusable, so both spellings are tried
    -- and neither is required to exist.
    pcall(function() handle.widget:SetIsFocusable(false) end)
    pcall(function() handle.widget.IsFocusable = false end)
    pcall(function() handle.widget.bIsFocusable = false end)
    Rows.attachControl(frame, handle)

    local button = nil
    local function performCopy()
        if not Clipboard.copy(fullPath) or button == nil then
            return
        end
        button.setCaption(copy.copiedCaption)
        -- Back to the invitation shortly, so the button says what it does rather than what it last
        -- did. The page may be gone by then: the generation guard rejects a rebuilt page, because
        -- a pcall does NOT catch an access violation raised inside UE4SS on a dead object.
        local era = generation
        if type(ExecuteInGameThreadWithDelay) == "function" then
            ExecuteInGameThreadWithDelay(ui.controls.copiedRevertMs, function()
                if era == generation then
                    pcall(function() button.setCaption(copy.caption) end)
                end
            end)
        end
    end
    button = placeActionButton(worldContext, canvas, rect, {
        caption = copy.caption,
        tooltip = copy.tooltip,
        variant = "secondary",
        onClick = performCopy,
    })
    if button == nil then
        return false
    end
    -- On a controller the WHOLE ROW copies. Navigation moves between rows, not between the
    -- widgets inside one, so a pad lands on the row's own click target and never on the small
    -- button at its end: the row showed no selection and would not copy (2026-09-07).
    -- The row's own target also gets vanilla's focus highlight for free. Only when the caller
    -- says the row has nothing else to do with a press: a file header collapses its file.
    if rowActivates then
        local clickChild = resolveRowClickChild(frame)
        if clickChild ~= nil then
            RowTrack.track(clickChild, { kind = "button", onClick = function()
                leaveEditMode(frame)
                performCopy()
            end })
        end
    end
    -- Right from the row reaches the Copy button, left from the button comes back. Without this
    -- the button is unreachable on a pad, since navigation moves between ROWS and the button
    -- lives inside one; it is the same left/right stepping an action row's buttons already have.
    local rowTarget = resolveRowClickChild(frame)
    if rowTarget ~= nil then
        Rows.linkRowNavigation({ rowTarget, button.button })
    end
    local address = RowTrack.addressOf(frame)
    if address ~= nil then
        local existing = embeddedButtonsByAddress[address] or {}
        existing[#existing + 1] = button.button
        embeddedButtonsByAddress[address] = existing
    end
    return true
end

-- A standalone path row: a label, the path in a box, and a Copy button - the same shape a file
-- header carries, for the two places that have no file header to hang it on (the presets folder
-- and the compiled request list).
function Rows.createPathEntry(worldContext, label, text, copy)
    local frame = createFrame(worldContext, label)
    if frame == nil then
        return nil
    end
    collapseUnusedRowChildren(frame, nil)
    if not Rows.addPathField(frame, worldContext, label, text, copy, nil, true) then
        pcall(function() frame:RemoveFromParent() end)
        return nil
    end
    Rows.applyStyle(frame, "control")
    return frame
end

-- Whether this build accepts an explicit navigation rule, reported once: it is the difference
-- between a usable keyboard and one where only the first key of each row can be reached.
local navigationLogged = false
local function logNavigationOnce(linked)
    if navigationLogged then
        return
    end
    navigationLogged = true
    if linked then
        log.info("row navigation: left and right linked between a row's buttons")
    else
        log.warn("row navigation: SetNavigationRuleExplicit was refused; only the first button "
            .. "in a row can be reached with a controller")
    end
end

-- Links a row's buttons to each other for controller navigation, so left and right step along the
-- row instead of leaving the page. `SetNavigationRuleExplicit` is a UWidget method, unproven on
-- this build, so every call is guarded: a build that refuses it keeps today's behaviour rather
-- than breaking the row.
function Rows.linkRowNavigation(buttons)
    local nav = ui.controls.navigation
    if nav == nil or #buttons < 2 then
        return false
    end
    local linked = false
    for index, button in ipairs(buttons) do
        local previous, following = buttons[index - 1], buttons[index + 1]
        if previous ~= nil and pcall(function()
            button:SetNavigationRuleExplicit(nav.left, previous)
        end) then
            linked = true
        end
        if following ~= nil and pcall(function()
            button:SetNavigationRuleExplicit(nav.right, following)
        end) then
            linked = true
        end
    end
    return linked
end

-- `options.trimFromLeft` keeps the END of the label when it does not fit, for a path.
-- `options.packLeft` lays the buttons out from the left with `options.indent`, for the keyboard.
function Rows.createActionRow(worldContext, caption, actions, options)
    -- A button is sized for the WIDEST caption it will ever show, not the one it starts with: the
    -- Delete action swaps to a longer confirm caption on its first click, and a pill sized for
    -- "Delete" cannot hold "Confirm Delete" in any of the 17 languages.
    local captions = {}
    for index, action in ipairs(actions) do
        local widest = action.caption
        if action.confirmCaption ~= nil
            and Rows.labelWidth(action.confirmCaption) > Rows.labelWidth(widest) then
            widest = action.confirmCaption
        end
        captions[index] = widest
    end
    -- Buttons first, label second: a button squeezed by a long label cannot be read or aimed at,
    -- while a label that is too long can simply be trimmed. It was the other way round until
    -- 2026-09-06.
    options = options or {}
    local rects = options.packLeft
        and Rows.packLeft(captions, { indent = options.indent })
        or Rows.packRight(captions)
    local room = (ui.rowWidth - ui.controls.actionRow.labelGap) - Rows.actionRowOccupied(captions)
    local trim = options.trimFromLeft and Rows.truncatePathToWidth or Rows.truncateToWidth
    local frame = createFrame(worldContext, trim(caption, room))
    if frame == nil then
        return nil
    end
    local frameAddress = RowTrack.addressOf(frame)
    local canvas = nil
    pcall(function()
        local field = frame[ui.controls.canvasField]
        if field ~= nil and field:IsValid() then
            canvas = field
        end
    end)
    -- No canvas, or no address to file the buttons under: without the address Rows.destroy has no
    -- route to untrack them, and a tracked button outliving its row dispatches a stale click when
    -- the engine reuses the address (the hazard embeddedButtonsByAddress exists to prevent).
    if canvas == nil or frameAddress == nil then
        pcall(function() frame:RemoveFromParent() end)
        return nil
    end
    collapseUnusedRowChildren(frame, nil)

    local built = {}
    for index, action in ipairs(actions) do
        local handle = placeActionButton(worldContext, canvas, rects[index], action)
        if handle ~= nil then
            built[#built + 1] = handle.button
            if action.attach ~= nil then
                pcall(action.attach, handle)
            end
        end
    end
    if #built == 0 then
        pcall(function() frame:RemoveFromParent() end)
        return nil
    end
    -- The row's OWN click target is collapsed. It is what a controller lands on otherwise, which
    -- made a row of five buttons read as one selectable line, sent left and right escaping to the
    -- category menu instead of stepping along the row, and put the row into the game's editing
    -- mode on every press (2026-09-07). With it gone, the only things a pad can focus in
    -- this row are the buttons this mod placed, which carry their own outline and their own
    -- left/right links.
    local ownTarget = resolveRowClickChild(frame)
    if ownTarget ~= nil then
        pcall(function() ownTarget:SetVisibility(ui.pageInactiveVisibility) end)
        if frameAddress ~= nil then
            collapsedOwnTargetByAddress[frameAddress] = true
        end
    end
    embeddedButtonsByAddress[frameAddress] = built
    -- Left and right step along the row rather than escaping it to the category buttons.
    if Gamepad.isActive() then
        logNavigationOnce(Rows.linkRowNavigation(built))
    end
    -- Explicitly hit-testable: the row carries buttons, and every other path that places buttons
    -- in a row canvas says so rather than inheriting whatever the frame defaulted to.
    pcall(function() frame:SetVisibility(ui.controls.pendingVisibleVisibility) end)
    Rows.applyStyle(frame, "control")
    return frame
end

-- The widget on `frame` a controller can put focus on: the row's own click target when it has
-- one (every full-width row), else the first action button embedded in it (a Save, Revert or Copy
-- row has no row-level click of its own). Returns nil for a row that is only text.
function Rows.focusTargetOf(frame)
    local address = RowTrack.addressOf(frame)
    local function firstEmbedded()
        local embedded = address ~= nil and embeddedButtonsByAddress[address] or nil
        if embedded == nil or embedded[1] == nil then
            return nil
        end
        local alive = false
        pcall(function() alive = embedded[1]:IsValid() end)
        return alive and embedded[1] or nil
    end
    -- Only an ACTION row hands focus to its buttons first, because its own target is collapsed.
    -- A row that kept its target keeps it as the focus target too, even when a Copy button sits
    -- at its end: a file header is selected as a whole row and pressing A expands or collapses
    -- it, exactly as a mouse click does, and the Copy button is reached with left and right
    -- (2026-09-07: the header showed no selection and would not collapse on a pad,
    -- because the Copy button embedded in it was taking the focus the row should have had).
    if address ~= nil and collapsedOwnTargetByAddress[address] then
        local embedded = firstEmbedded()
        if embedded ~= nil then
            return embedded
        end
    end
    local child = resolveRowClickChild(frame)
    if child ~= nil then
        return child
    end
    return firstEmbedded()
end

-- ============================== Reaffirm and destroy ==============================

-- Pushes a committed value back onto a row after Apply or reset. Returns the list of widgets it
-- destroyed (an open dropdown's choice rows, collapsed here), or nil when it destroyed nothing -
-- every caller must prune those addresses from its own live-widget bookkeeping (this function has
-- none of its own to prune), or a later destroy of the same stale reference can silently untrack
-- an unrelated widget that has since reused the freed address (RowTrack is address-keyed).
function Rows.reaffirm(rowRecord, value)
    if rowRecord.rowKind == "switch" or rowRecord.rowKind == "switch01" then
        local frame = rowRecord.frame
        if frame == nil or not frame:IsValid() then
            return
        end
        local child = nil
        pcall(function() child = frame.WBP_OptionSettings_ListContentSwitch end)
        if child ~= nil and child:IsValid() then
            local on = value
            if rowRecord.rowKind == "switch01" then
                on = value ~= 0
            end
            pcall(function() child:Setup(on and true or false, true) end)
        end
    elseif rowRecord.rowKind == "slider" then
        local frame = rowRecord.frame
        if frame == nil or not frame:IsValid() then
            return
        end
        local child = nil
        pcall(function() child = frame.WBP_OptionSettings_ListContentSlider end)
        if child ~= nil and child:IsValid() then
            pcall(function() child:SetValue(value, rowRecord.min, rowRecord.max) end)
            -- Restore to Default and preset Load move the bar, so the D-pad must step from
            -- where the bar now is rather than from where the row was built.
            local owner = RowTrack.resolve(child)
            if owner ~= nil and owner.kind == "slider" and type(value) == "number" then
                owner.value = value
                pcall(function()
                    child[ui.theme.sliderValueText]:SetText(FText(Rows.numberString(value)))
                end)
            end
        end
        -- Restore to Default and preset Load both come through here, and the typed value must
        -- follow the bar rather than keep showing what the player last entered.
        local handle = Rows.controlOf(frame)
        if handle ~= nil and handle.set ~= nil then
            handle.set(Rows.numberString(value))
        end
    elseif rowRecord.rowKind == "enum" then
        local frame = rowRecord.frame
        if frame == nil or not frame:IsValid() then
            return nil
        end
        local handle = Rows.controlOf(frame)
        if handle ~= nil then
            handle.set(value)
            return nil
        end
        -- An inline-mode enum row: collapse it if open, then re-label the closed row from the
        -- value that was just committed or restored.
        local destroyed = nil
        if rowRecord.expanded and rowRecord.choiceWidgets ~= nil then
            destroyed = rowRecord.choiceWidgets
            for _, widget in ipairs(destroyed) do
                Rows.destroy(widget, false)
            end
            rowRecord.choiceWidgets = {}
            rowRecord.expanded = false
        end
        rememberLabel(frame, dropdownLabel(rowRecord.caption or "", value))
        return destroyed
    elseif rowRecord.rowKind == "text" then
        local frame = rowRecord.frame
        if frame == nil or not frame:IsValid() then
            return nil
        end
        local handle = Rows.controlOf(frame)
        if handle ~= nil then
            local shown = Rows.displayString(value)
            handle.set(shown)
            handle.last = shown
        end
        return nil
    end
    return nil
end

-- Detaches a row (or raw section widget) and clears its bookkeeping. `bookkeepingOnly` skips
-- RemoveFromParent when the whole tree is already being torn down.
function Rows.destroy(widget, bookkeepingOnly)
    if widget == nil then
        return
    end
    leaveEditMode(widget)
    local address = RowTrack.addressOf(widget)
    if address ~= nil then
        labels[address] = nil
        controlsByAddress[address] = nil
        collapsedOwnTargetByAddress[address] = nil
        local embedded = embeddedButtonsByAddress[address]
        if embedded ~= nil then
            embeddedButtonsByAddress[address] = nil
            for _, button in ipairs(embedded) do
                local buttonAddress = RowTrack.addressOf(button)
                if buttonAddress ~= nil then
                    labels[buttonAddress] = nil
                end
                RowTrack.untrack(button)
                -- createModButton tracks the invisible child too; a freed address left
                -- tracked dispatches a stale onClick when the engine reuses it.
                pcall(function() RowTrack.untrack(button.WBP_PalInvisibleButton) end)
            end
        end
    end
    RowTrack.untrack(widget)
    local childFields = { "WBP_OptionSettings_ListContentSwitch",
        "WBP_OptionSettings_ListContentSlider" }
    for _, field in ipairs(ui.rowClickFields) do
        childFields[#childFields + 1] = field
    end
    for _, field in ipairs(childFields) do
        local child = nil
        pcall(function() child = widget[field] end)
        if child ~= nil then
            RowTrack.untrack(child)
        end
    end
    if not bookkeepingOnly then
        pcall(function() widget:RemoveFromParent() end)
    end
end

return Rows
