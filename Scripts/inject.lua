-- Adds a "Mod Configs" category to WBP_OptionSettings_C (the ESC menu and title menu share the
-- class, so one hook covers both) and shows this mod's panel when it is clicked.
--
-- Mechanics: vanilla keeps its five category pages as permanent children of one shared ScrollBox
-- and switches tabs by toggling Visibility; our page joins as an extra permanent child driven the
-- same way. The content area is not laid out until vanilla's own tab-switch handler has run for
-- the screen instance, so showing our page invokes the Control tab's bound event first, swaps our
-- page in for the one it activated, and re-asserts on short delays because the switch's animation
-- callbacks can re-show the activated page.
--
-- Coexistence: NativeModOptions injects its own category the same way. Both filter class-level
-- hooks by address, so state stays separate; the visible-page handoff is handled here by
-- collapsing any foreign (non-vanilla, non-ours) visible sibling page when our page shows,
-- remembering it, and restoring it when a category button that is neither ours nor vanilla's is
-- clicked (that click is the other mod's, and its own early-out logic will not re-show its page).
local Config = require("config")
local Controls = require("controls")
local Frameworks = require("frameworks")
local HookParam = require("hook_param")
local I18n = require("i18n")
local Panel = require("panel")
local Present = require("present")
local Rows = require("rows")
local RowTrack = require("rowtrack")
local Scanner = require("scanner")
local Staging = require("staging")
local Widgets = require("widgets")
local log = require("logger")

local ui = Config.ui
local OPTION_SETTINGS_CLASS = ui.optionSettingsAsset .. ".WBP_OptionSettings_C"
local MENU_BUTTON_CLASS = ui.menuButtonAsset .. ".WBP_OptionSettings_MenuButton_C"
-- Clicks land on the button's invisible child; MenuButton_C itself has no OnClicked UFunction.
local BUTTON_BASE_CLASS = ui.buttonBaseAsset .. ".WBP_PalCommonButtonBase_C"

local Inject = {}

local addressOf = RowTrack.addressOf

local injected = {}      -- [screen address] = true
local screens = {}       -- [screen address] = screenState
-- Ours and the five real category buttons (and their invisible children), per screen.
local buttonOwner = {}   -- [button address] = screenState
local epochs = {}
local escHooksInstalled = false
local inject   -- forward declared; installHooks needs it
local onEscButtonClicked   -- forward declared; installHooks' shared click hook needs it
-- Forward declared: inject() (defined ahead of the "Our own ESC-menu button" section below,
-- where the real definition lives) needs this to log a confirmed open, and Lua's lexical
-- scoping otherwise binds a `local function` defined later in the file to a fresh, unrelated
-- upvalue instead of the one inject() closes over.
local logEscOptionTriggerMethodOnce

-- Our own ESC-menu "Mod Configs" button (see the "Our own ESC-menu button" section below).
-- Declared here, ahead of both hidePalModOptionsButton (which excludes ours by address) and
-- installHooks (whose shared click hook resolves a click on ours through escClickTargets), and
-- ahead of clearInstance below (which drops a menu's entries from all three when its poll chain
-- stops - cap, not-alive, or a throw - the only teardown path the ESC-menu path has).
local escButtonState = {}       -- [menu address] = { ourButtonAddress, invisibleAddress }
local escButtonAddresses = {}   -- [address] = true, both button and invisible click child
local escClickTargets = {}      -- [address] = { menu = menu }, both button and invisible child
-- The pending-select handoff (a click on our ESC button opens the vanilla options screen, then
-- this arms inject() to select our category once that screen has settled). Declared here, ahead
-- of both inject() (which reads and clears them) and clearInstance (which also clears them when
-- the ARMING ESC-menu instance's own poll chain stops, so a request whose trigger silently
-- no-op'd cannot outlive the menu that armed it). nil/nil means not armed.
local pendingSelectArmedAtMs = nil
local pendingSelectSourceMenuAddress = nil

-- Honest-success tracking for the Mod Configs ESC button's open trigger (see "Our own ESC-menu
-- button" section further down for where these are set and read - onEscButtonClicked/
-- attemptEscOpen write them, inject() reads them). escOpenEpoch increments on every attempt so a
-- scheduled retry can tell whether it has been superseded by a newer attempt or a confirmed
-- success by the time it fires; escOpenActiveEpoch is nil once resolved (confirmed or all
-- methods exhausted). escOpenClickedAtMs/escOpenAttemptIndex describe the in-flight attempt
-- inject() compares its own screenSeenAtMs against. escOpenConfirmedMethodIndex remembers which
-- method actually worked, once known, so a later click reuses it directly instead of re-cycling
-- through methods that already failed this session.
local escOpenEpoch = 0
local escOpenActiveEpoch = nil
local escOpenClickedAtMs = nil
local escOpenAttemptIndex = nil
local escOpenConfirmedMethodIndex = nil
local escOpenExhausted = false

-- Why the anomaly WARN below is throttled (added 2026-09-01): the hide attempt itself runs
-- on every screen construction (a legitimate framework-absent-this-pass case is not rare - the
-- very first screen open of a session, before the other framework has injected its own button,
-- looks identical to a genuine anomaly). Logging that every time is exactly the log spam the
-- workspace's log-a-degradation-once doctrine forbids, so the WARN is throttled to once per
-- (frameworkSource, screen kind) per session; the hide attempt itself is never throttled.
--
-- Exported on Inject and returns true when it actually logged (first time for this key) or
-- false when suppressed, so the dedup behavior itself is directly testable offline with no
-- logger stub or fake UE4SS state needed: a test over the config data's shape alone never
-- reached this.
local anomalyLogged = {}   -- [frameworkSource .. "|" .. screenKind] = true

function Inject.logAnomalyOnce(frameworkSource, screenKind, message)
    local key = tostring(frameworkSource) .. "|" .. tostring(screenKind)
    if anomalyLogged[key] then
        return false
    end
    anomalyLogged[key] = true
    log.warn(message)
    return true
end

-- Found in a live session on 2026-09-01: PalModOptions consumers register
-- IN MEMORY, and only get a saved-value FILE after the player changes one of their settings
-- through PalModOptions' own panel. On an install where nobody has ever opened that panel,
-- PalModOptions\Scripts\config\ holds nothing but its own README.txt - the file-coverage gate
-- below can then never be satisfied, so the button stayed visible forever even though every
-- consumer is, in fact, fully present. PalModOptions is therefore judged from its live consumer
-- REGISTRY instead (Frameworks.registeredConsumers, over the same shared-variable channel its
-- schema reads already use), never from file coverage. NativeModOptions keeps the original
-- file-coverage gate unchanged: it never publishes a live registry a third party can read, so the
-- boot-scan file coverage remains the only signal available for it.
local PALMODOPTIONS_SOURCE = Config.frameworks.buttonIdentity.palModOptions.frameworkSource

-- Code-review fix, 2026-09-01 (Important finding): the verdict used to be cached permanently on
-- the first successful read, so a consumer that registered AFTER the first ESC-menu open never
-- changed it - an install where PalModOptions gains a second consumer mid-session would keep
-- hiding the button on the strength of a now-stale "absorbed" reading. The registry read is one
-- shared-variable get plus a newline split, cheap enough to repeat: it is now re-read and
-- recomputed on every call (every ESC-menu construction and poll tick), and only the LOGGED line
-- is deduplicated, by comparing the current ids/unmatched sets against the last ones actually
-- logged (first time, and whenever either set differs from that last logged state) - the verdict
-- itself always reflects the freshest read. A failed read (framework not booted yet) still
-- retries every call and is never logged as a verdict.
local palModOptionsLastLoggedIdsKey = nil
local palModOptionsLastLoggedUnmatchedKey = nil

-- Sorted, comma-joined signature of a plain string list, used only to detect whether the logged
-- verdict actually changed since last time - order-independent, so re-reading the same registry
-- in a different enumeration order never triggers a spurious re-log.
local function sortedKey(list)
    local copy = {}
    for index, value in ipairs(list or {}) do
        copy[index] = tostring(value)
    end
    table.sort(copy)
    return table.concat(copy, ",")
end

-- Every entry across every file this session's scan attributed to a mod, keyed by lowercase mod
-- name - "has at least one entry" covers both a visible row and one only surfaced as advanced
-- (Scripts/scanner.lua's entry.advanced flag marks the latter; both count as real coverage here).
local function modNamesWithEntries(model)
    local set = {}
    if model == nil or model.mods == nil then
        return set
    end
    for _, mod in ipairs(model.mods) do
        local total = 0
        for _, file in ipairs(mod.files or {}) do
            total = total + #(file.entries or {})
        end
        if total > 0 and mod.name ~= nil then
            set[mod.name:lower()] = true
        end
    end
    return set
end

-- The pure decision PalModOptions absorption reduces to, once the registry has actually been
-- read: every registered consumer id must match (case-insensitively) a mod the scan found at
-- least one entry for. Exported and pure (plain lists/sets in, two plain values out) so this is
-- directly testable without a live registry read. Returns (absorbed, unmatchedIds); a nil or
-- empty id list is never absorbed (registry unreadable, or genuinely nobody registered yet).
function Inject.registryAbsorbed(ids, modNamesWithEntries)
    if ids == nil or #ids == 0 then
        return false, {}
    end
    modNamesWithEntries = modNamesWithEntries or {}
    local unmatched = {}
    for _, id in ipairs(ids) do
        if not modNamesWithEntries[tostring(id):lower()] then
            unmatched[#unmatched + 1] = id
        end
    end
    return #unmatched == 0, unmatched
end

local function logPalModOptionsRegistryVerdictIfChanged(ids, unmatched)
    local idsKey = sortedKey(ids)
    local unmatchedKey = sortedKey(unmatched)
    if idsKey == palModOptionsLastLoggedIdsKey
        and unmatchedKey == palModOptionsLastLoggedUnmatchedKey then
        return
    end
    palModOptionsLastLoggedIdsKey = idsKey
    palModOptionsLastLoggedUnmatchedKey = unmatchedKey
    local count = tostring(#ids)
    if #unmatched == 0 then
        log.info("PalModOptions registry: " .. count
            .. " consumer(s), all shown here - hiding its button")
    else
        log.warn("PalModOptions registry: " .. count .. " consumer(s), unmatched: "
            .. table.concat(unmatched, ", ") .. " - leaving its button visible")
    end
end

-- The live half: reads the registry (real shared-variable getter by default; `getter` exists so
-- this is testable with a fake one) and resolves it against this session's scan model, fresh on
-- every call - see the comment above palModOptionsLastLoggedIdsKey for why nothing here is
-- cached across calls any more, only the LOGGED line is deduplicated.
local function resolvePalModOptionsAbsorption(model, getter)
    local ids = Frameworks.registeredConsumers("palmodoptions", getter)
    if ids == nil then
        return false
    end
    local absorbed, unmatched = Inject.registryAbsorbed(ids, modNamesWithEntries(model))
    logPalModOptionsRegistryVerdictIfChanged(ids, unmatched)
    return absorbed
end

-- A framework is fully absorbed when every consumer it currently claims was matched to a mod
-- this session's scan found at least one entry for. For NativeModOptions that claim is still the
-- boot-scan's saved-value FILE coverage (pure over `model`, no engine call inside - unchanged).
-- For PalModOptions it is the live consumer REGISTRY instead (see the block above this function
-- for why); `getter` is passed through for offline testing only, and is nil in production so the
-- real shared-variable getter is used.
function Inject.frameworkFullyAbsorbed(model, frameworkSource, getter)
    if model == nil or frameworkSource == nil then
        return false
    end
    if frameworkSource == PALMODOPTIONS_SOURCE then
        return resolvePalModOptionsAbsorption(model, getter)
    end
    local coverage = model.frameworkCoverage and model.frameworkCoverage[frameworkSource]
    if coverage == nil or coverage.consumers == nil or next(coverage.consumers) == nil then
        return false
    end
    for _, ok in pairs(coverage.consumers) do
        if not ok then
            return false
        end
    end
    return true
end

-- Whether a framework's own button should be hidden this pass, and whether that verdict was
-- CONFIRMED. Absorption is the confirmation, never the condition: a verdict that comes back
-- unconfirmed is a read that failed, not evidence the framework covers something this mod does
-- not. Both frameworks have now produced one on a real install, for two unrelated reasons
-- (Config.frameworks.hideFrameworkButtonWhenUnconfirmed records both), and each time the visible
-- result was a duplicate button on screen. A caller that hides unconfirmed logs it.
--
-- Pure apart from the absorption read it delegates, so every case is drivable from the suite -
-- which is the point: the NativeModOptions gate failed silently past a green suite twice,
-- because the decision only existed inside a matcher no test could reach.
function Inject.shouldHideFrameworkButton(model, frameworkSource, getter)
    if Inject.frameworkFullyAbsorbed(model, frameworkSource, getter) then
        return true, true
    end
    return Config.frameworks.hideFrameworkButtonWhenUnconfirmed == true, false
end

local function invisibleChildOf(menuButton)
    local child = nil
    pcall(function() child = menuButton.WBP_PalInvisibleButton end)
    return child
end

local function relabel(button)
    pcall(function() button.BP_PalTextBlock_Name:SetText(FText(I18n.t("category_label"))) end)
end

local function setVisibility(widget, visibility)
    if widget == nil or not widget:IsValid() then
        return
    end
    pcall(function() widget:SetVisibility(visibility) end)
end

-- Hides `widget` only when it is currently visible, and reports whether it actually did so - the
-- signal the per-instance poll (below) needs to tell a genuine re-hide event apart from a no-op
-- pass over a button that is already collapsed.
local function hideIfVisible(widget)
    if widget == nil or not widget:IsValid() then
        return false
    end
    local visibility = nil
    pcall(function() visibility = widget.Visibility end)
    if visibility ~= nil and visibility == ui.pageInactiveVisibility then
        return false
    end
    setVisibility(widget, ui.pageInactiveVisibility)
    return true
end

local function detach(widget)
    if widget ~= nil then
        pcall(function() widget:RemoveFromParent() end)
    end
end

-- Enumerates a panel widget's children through the reflected UPanelWidget API.
local function panelChildren(panel)
    local children = {}
    if panel == nil or not panel:IsValid() then
        return children
    end
    local count = nil
    pcall(function() count = panel:GetChildrenCount() end)
    count = tonumber(count)
    if count == nil then
        return children
    end
    for index = 0, count - 1 do
        local child = nil
        pcall(function() child = panel:GetChildAt(index) end)
        if child ~= nil and child:IsValid() then
            children[#children + 1] = child
        end
    end
    return children
end

-- Reads a text-widget field's rendered caption, or nil when the field or the widget is missing.
local function captionOf(widget, field)
    local text = nil
    pcall(function() text = widget[field]:GetText():ToString() end)
    return text
end

-- The short class name (trailing segment only, e.g. "WBP_MenuESC_Button_C") a widget's own class
-- reports, or nil. Same idiom NativeModOptions' native_style.lua uses to identify a child widget.
local function shortClassOf(widget)
    local class = nil
    pcall(function() class = widget:GetClass():GetFName():ToString() end)
    return class
end

-- Whether the apply prompt is OURS to answer. Editing a mod config must not raise the game's
-- "apply changed settings?" prompt at all, because that prompt carries a "a restart is required"
-- note that is wrong for a mod which reloads with the world. The one exception is a mod the
-- catalog RECORDS as needing a relaunch: then the note is true, the prompt is wanted, and its
-- answer saves or reverts our edits. Everything else saves on the way out with no prompt at all.
--
-- Deliberately a question about the pending set, not about who raised the flag: if the player also
-- changed a real game setting, vanilla prompts for its own reason, and the restart note on screen
-- is still the right thing to answer for a restart-required mod.
local function ourPromptGoverns()
    return Present.anyRequiresGameRestart(Staging.pendingModNames())
end

-- Whether WE raised the flag, so reverting the last restart-required edit puts the screen back the
-- way it was instead of leaving a prompt with nothing behind it. Vanilla's own dirty state is never
-- lowered: only a flag this mod raised is ever cleared.
local raisedByUs = false

-- Keeps the screen's prompt in step with our pending set. Called whenever a value is staged.
local function syncPrompt(instance)
    local wanted = ourPromptGoverns()
    if wanted == raisedByUs then
        return
    end
    if wanted then
        local before = nil
        pcall(function() before = instance[ui.dirtyPageField].SomethingChanged end)
        if before ~= false then
            -- Vanilla is already dirty for its own reason; its prompt appears either way.
            return
        end
        local ok = pcall(function() instance[ui.dirtyPageField].SomethingChanged = true end)
        if ok then
            raisedByUs = true
        else
            log.warn("could not raise " .. ui.dirtyPageField .. ".SomethingChanged - leaving the "
                .. "options screen will not prompt for a mod that needs a relaunch")
        end
        return
    end
    pcall(function() instance[ui.dirtyPageField].SomethingChanged = false end)
    raisedByUs = false
end

-- Hides all five real pages rather than detecting the active one: on the first click of a session
-- none is marked active. At most one is ever visible, so hiding all five is equivalent.
local function hideAllRealPages(instance)
    for _, field in ipairs(ui.realPageFields) do
        local ok, page = pcall(function() return instance[field] end)
        if ok and page ~= nil and page:IsValid() then
            setVisibility(page, ui.pageInactiveVisibility)
        end
    end
end

local function realPageAddresses(instance)
    local set = {}
    for _, field in ipairs(ui.realPageFields) do
        local ok, page = pcall(function() return instance[field] end)
        if ok and page ~= nil then
            local address = addressOf(page)
            if address ~= nil then
                set[address] = true
            end
        end
    end
    return set
end

-- Collapses any visible sibling page that is neither vanilla's nor ours (another mod's injected
-- page), remembering its visibility for the handoff back.
local function collapseForeignPages(screenState)
    local instance = screenState.instance
    local realSet = realPageAddresses(instance)
    local ourAddress = addressOf(screenState.ourPage)
    screenState.foreignRestore = screenState.foreignRestore or {}
    for _, child in ipairs(panelChildren(screenState.scrollBox)) do
        local address = addressOf(child)
        if address ~= nil and not realSet[address] and address ~= ourAddress then
            local visibility = nil
            pcall(function() visibility = child.Visibility end)
            if visibility ~= nil and visibility ~= ui.pageInactiveVisibility then
                screenState.foreignRestore[address] = { widget = child,
                    visibility = visibility }
            end
            setVisibility(child, ui.pageInactiveVisibility)
        end
    end
end

local function restoreForeignPages(screenState)
    for _, remembered in pairs(screenState.foreignRestore or {}) do
        setVisibility(remembered.widget, remembered.visibility)
    end
    screenState.foreignRestore = nil
    -- The shared tab header goes back to how it was before our takeover; whichever owner needs it
    -- differently reconfigures it on its own next interaction.
    if screenState.headerWasVisible then
        local header = nil
        pcall(function() header = screenState.instance.WBP_OptionSettings_Tab end)
        setVisibility(header, ui.pageActiveVisibility)
    end
end

-- The shared sub-tab header (Keyboard/Controller on vanilla's Controls page; NativeModOptions
-- repurposes it) draws above our page; it is collapsed while ours shows.
local function collapseHeader(screenState, remember)
    local header = nil
    pcall(function() header = screenState.instance.WBP_OptionSettings_Tab end)
    if header == nil or not header:IsValid() then
        return
    end
    if remember then
        local visibility = nil
        pcall(function() visibility = header.Visibility end)
        screenState.headerWasVisible = visibility ~= nil
            and visibility ~= ui.pageInactiveVisibility
    end
    setVisibility(header, ui.pageInactiveVisibility)
end

local function assertOurPage(screenState)
    hideAllRealPages(screenState.instance)
    collapseForeignPages(screenState)
    collapseHeader(screenState, false)
    setVisibility(screenState.ourPage, ui.pageActiveVisibility)
    Rows.markTab(screenState.ourButton, true, screenState.tabMark, screenState.instance)
end

-- Builds the page content on first use. Cheap and idempotent afterwards, so every later tab
-- switch costs nothing; a failure logs once and leaves an empty page rather than blocking the
-- switch, exactly as the eager build did.
local function ensurePageBuilt(screenState)
    if screenState.panelState ~= nil or screenState.buildList == nil then
        return
    end
    local list = screenState.buildList
    screenState.buildList = nil
    local builtOk, builtState = pcall(Panel.build, screenState.instance, list)
    if builtOk then
        screenState.panelState = builtState
    else
        log.warn("Panel.build failed - Mod Configs will show no content: " .. tostring(builtState))
    end
end

local function showOurs(screenState)
    if screenState.showing == "ours" or screenState.showing == "switching" then
        return
    end
    ensurePageBuilt(screenState)
    screenState.showing = "switching"
    -- Captured before the tab switch repaints anything.
    collapseHeader(screenState, true)
    collapseForeignPages(screenState)
    local switchOk = pcall(function()
        screenState.instance[ui.controlTabEvent](screenState.instance)
    end)
    if not switchOk then
        log.warn("Control tab handler unavailable - the Mod Configs page may not lay out")
    end
    -- Applied in the same frame: any delay is a visible flash of the page vanilla activated.
    if screenState.torndown then
        return
    end
    assertOurPage(screenState)
    screenState.showing = "ours"
    pcall(Controls.setPageActive, true)
    -- On a controller, put focus on the page we just brought up: without it the pad is still on
    -- whatever vanilla page is now hidden, and nothing this mod draws can be reached. Gated on
    -- the controller being the live input, so a mouse player's focus is never moved. Deferred a
    -- frame because the rows are laid out by the tab switch above.
    ExecuteInGameThreadWithDelay(0, function()
        if not screenState.torndown and screenState.showing == "ours" then
            pcall(Panel.focusFirstRow, screenState.panelState)
        end
    end)
    for _, delay in ipairs(ui.switchReassertMs) do
        ExecuteInGameThreadWithDelay(delay, function()
            if not screenState.torndown and screenState.showing == "ours" then
                assertOurPage(screenState)
            end
        end)
    end
end

-- `restoreForeign` is true when the handoff target is another mod's injected category, whose own
-- logic will not re-show its page (it never saw itself hidden).
local function showVanilla(screenState, restoreForeign)
    if screenState.showing == "vanilla" then
        return
    end
    -- Off our page, the typing gate has nothing of ours to protect and must not be holding the
    -- game's own Back action down.
    pcall(Controls.setPageActive, false)
    setVisibility(screenState.ourPage, ui.pageInactiveVisibility)
    Rows.markTab(screenState.ourButton, false, screenState.tabMark, screenState.instance)
    if restoreForeign then
        restoreForeignPages(screenState)
    else
        screenState.foreignRestore = nil
    end
    screenState.showing = "vanilla"
end

-- Addresses of every category button (and its invisible child) currently in the button
-- container, whoever added it. Recomputed on demand: another mod can inject after us.
local function categorySiblingAddresses(screenState)
    local set = {}
    for _, child in ipairs(panelChildren(screenState.buttonContainer)) do
        local address = addressOf(child)
        if address ~= nil then
            set[address] = true
        end
        local invisibleAddress = addressOf(invisibleChildOf(child))
        if invisibleAddress ~= nil then
            set[invisibleAddress] = true
        end
    end
    return set
end

-- Matches (and hides) NativeModOptions' shared category button among our sibling buttons, once
-- every consumer claiming its saved-value store parsed clean at boot. Ours and vanilla's five
-- real buttons are already known via buttonOwner (populated in buildScreenState): a candidate is
-- only considered when buttonOwner does not already claim it, so neither can ever be matched.
-- RAW matcher: no scheduling of its own. hideNativeModOptionsButton below is the one place that
-- schedules a re-run, so this can never chain into an unbounded retry loop.
--
-- Returns "hidden", "ambiguous", "zero" (button container reached but no candidate matched - the
-- caller may retry once), or nil (not applicable this call: gate false, or a missing identity
-- field), mirroring hidePalModOptionsButton below. A second return value, `wasVisible`, is true
-- only on a "hidden" result where the button was actually visible and got collapsed this call -
-- the per-instance poll (below) uses that to tell a genuine re-hide apart from a no-op pass over
-- a button that was already collapsed. Evidence logging for a successful hide lives in the poll
-- driver now (per-instance, not per-session); this function only matches and hides.
local function matchNativeModOptionsButton(screenState, model)
    local identity = Config.frameworks.buttonIdentity
        and Config.frameworks.buttonIdentity.nativeModOptions
    if identity == nil or identity.frameworkSource == nil or identity.captionField == nil
        or identity.captionLiteral == nil then
        return nil
    end
    -- Same rule the ESC-menu path uses: an unconfirmed verdict no longer VETOES the hide, it is
    -- logged. NativeModOptions' verdict comes from saved-value file coverage, and a framework no
    -- consumer has saved a value through yet ships no such files, so the gate read false on an
    -- install where it is in fact fully covered - silently, because the anomaly log below sat
    -- behind this same return (2026-09-04). See Config.frameworks.
    -- hideFrameworkButtonWhenUnconfirmed for the full reasoning.
    local hide, confirmed = Inject.shouldHideFrameworkButton(model, identity.frameworkSource)
    if not hide then
        return nil
    end
    if not confirmed then
        Inject.logAnomalyOnce(identity.frameworkSource, "optionsUnconfirmed",
            "hiding NativeModOptions' options-screen button without confirming every consumer "
            .. "it claims is covered here: its saved-value coverage could not be read this "
            .. "session. Set Config.frameworks.hideFrameworkButtonWhenUnconfirmed = false to "
            .. "keep the button instead.")
    end
    local matches = {}
    for _, child in ipairs(panelChildren(screenState.buttonContainer)) do
        local address = addressOf(child)
        if address ~= nil and buttonOwner[address] == nil
            and captionOf(child, identity.captionField) == identity.captionLiteral then
            matches[#matches + 1] = child
        end
    end
    if #matches == 1 then
        local wasVisible = hideIfVisible(matches[1])
        return "hidden", wasVisible
    elseif #matches > 1 then
        Inject.logAnomalyOnce(identity.frameworkSource, "options",
            "multiple options-screen buttons matched NativeModOptions' caption - leaving all "
            .. "visible")
        return "ambiguous"
    end
    Inject.logAnomalyOnce(identity.frameworkSource, "options",
        "NativeModOptions is fully absorbed but its options-screen button was not found on "
        .. "at least one screen open - leaving nothing hidden that pass")
    return "zero"
end

-- Found in game on 2026-09-01: a single delayed re-run only ever caught the FIRST time the
-- framework's button appeared after ours hid it. Both frameworks re-assert their own button on
-- their own hooks/re-shows, so persistent hiding needs a bounded poll that keeps re-hiding it
-- for as long as the instance stays open, not a one-shot re-check.
--
-- Pure: given how many polls have already run in a chain (0 when asking for the delay before the
-- very first poll), returns the delay in ms to wait before the NEXT poll, or nil when the hard
-- cap has been reached (the caller must stop scheduling). `schedule` entries are offsets from the
-- TRIGGER (the moment the chain started), so the delay returned for the Nth scheduled entry is
-- the gap from the (N-1)th, not the raw offset itself; once the schedule is exhausted every later
-- poll is spaced `intervalMs` apart. Exported and pure (no engine call) so the scheduling
-- decision is directly testable with plain fixtures.
function Inject.nextPollDelayMs(pollsRun, schedule, intervalMs, cap)
    schedule = schedule or {}
    if cap ~= nil and pollsRun >= cap then
        return nil
    end
    if pollsRun < #schedule then
        local previousOffset = pollsRun > 0 and schedule[pollsRun] or 0
        return schedule[pollsRun + 1] - previousOffset
    end
    return intervalMs
end

-- Added 2026-09-01 after a run in game: pure boundary check backing the
-- ESC-menu liveness grace period (Config.frameworks.pollVisibilityGracePolls). `pollsRun` is the
-- same 0-based "polls already run" count nextPollDelayMs above takes. True while the chain is
-- still inside the scheduled phase (the first `#schedule` polls, spaced at the schedule's own
-- offsets while a freshly constructed menu is still playing its open animation) or within
-- `gracePolls` further steady-state polls after that; false once genuinely steady-state visibility
-- readings should be trusted. Exported and pure (no engine call) so the boundary itself is
-- directly testable without a live menu widget.
function Inject.withinVisibilityGracePeriod(pollsRun, schedule, gracePolls)
    local scheduleLength = schedule ~= nil and #schedule or 0
    gracePolls = gracePolls or 0
    return pollsRun < scheduleLength + gracePolls
end

-- One poll chain per live instance, keyed by the instance's own address: a new trigger for an
-- address already chained is a no-op, so a framework's button can never be double-polled.
local pollChains = {}    -- [address] = true while a chain is running
-- Evidence bookkeeping is per instance, not per session: `n` is a small log-correlation id,
-- `firstHidLogged` gates the one "hid" log, `reHideCount` is the `k` the stop summary reports.
local instanceLog = {}   -- [address] = { n = <int>, firstHidLogged = false, reHideCount = 0 }
local nextInstanceId = 0

local function instanceEntry(address)
    local entry = instanceLog[address]
    if entry == nil then
        nextInstanceId = nextInstanceId + 1
        entry = { n = nextInstanceId, firstHidLogged = false, reHideCount = 0,
            invisibleStreak = 0 }
        instanceLog[address] = entry
    end
    return entry
end

-- Code-review fix, 2026-09-01 (Important finding): instanceLog used to survive a chain stopping,
-- so a UObject address the engine later reuses for a genuinely different instance inherited the
-- stale entry - its firstHidLogged was already true, so that NEW instance's first hide was
-- misreported as a re-hide, and the entry lived for the rest of the session either way. Both
-- tables are always cleared together, here, and again from teardown() for the options-screen
-- path (the ESC-menu path has no teardown hook; its own liveness check clears them when the menu
-- stops being usable). nextInstanceId itself is never reset, so a fresh entry for a reused
-- address still gets a brand new, monotonically increasing `n`.
-- Code-review fix, 2026-09-01 (Critical finding): escButtonState/escButtonAddresses/
-- escClickTargets used to be populated in buildEscButton and never cleared, so a stale entry
-- survived after the engine freed and later reused that address for something unrelated -
-- misattributing a click, or wrongly excluding an unrelated widget from the PalModOptions
-- matcher. Every address this menu's own ESC button ever used is dropped here too, at exactly
-- the same points (cap reached, not-alive, or a throw) clearInstance already runs at for both
-- poll-chain paths - the ESC-menu path has no other teardown hook. Also drops the pending-select
-- arm if THIS address is the one that armed it (see the top-of-file comment on
-- pendingSelectArmedAtMs): once the arming ESC menu's own chain stops, a request whose trigger
-- silently no-op'd can never hijack a later, unrelated options-screen open.
local function clearInstance(address)
    pollChains[address] = nil
    instanceLog[address] = nil
    local escState = escButtonState[address]
    if escState ~= nil then
        if escState.ourButtonAddress ~= nil then
            escButtonAddresses[escState.ourButtonAddress] = nil
            escClickTargets[escState.ourButtonAddress] = nil
        end
        if escState.invisibleAddress ~= nil then
            escButtonAddresses[escState.invisibleAddress] = nil
            escClickTargets[escState.invisibleAddress] = nil
        end
        escButtonState[address] = nil
    end
    if pendingSelectSourceMenuAddress ~= nil and pendingSelectSourceMenuAddress == address then
        pendingSelectArmedAtMs = nil
        pendingSelectSourceMenuAddress = nil
    end
end

-- Generic poll driver, shared by the NativeModOptions options-screen path and the PalModOptions
-- ESC-menu path below. `isAliveFn` decides whether the instance is still worth polling (a
-- pcall-guarded IsValid check, plus screen-teardown state where that concept applies); `passFn`
-- runs one match-and-hide pass; `stopFn` runs once, when the chain ends, to emit the summary log.
-- Every scheduled body is pcall-guarded so a throw degrades to one log line, never crashes the
-- chain silently or the game loudly.
local function startPollChain(address, isAliveFn, passFn, stopFn)
    if address == nil or pollChains[address] then
        return
    end
    pollChains[address] = true

    local schedule = Config.frameworks.pollScheduleMs
    local intervalMs = Config.frameworks.pollIntervalMs
    local cap = Config.frameworks.pollCap

    local schedulePoll
    schedulePoll = function(pollsRun)
        local delay = Inject.nextPollDelayMs(pollsRun, schedule, intervalMs, cap)
        if delay == nil then
            clearInstance(address)
            pcall(stopFn)
            return
        end
        ExecuteInGameThreadWithDelay(delay, function()
            local ok, err = pcall(function()
                local aliveOk, alive = pcall(isAliveFn, pollsRun)
                if not aliveOk or alive ~= true then
                    clearInstance(address)
                    pcall(stopFn)
                    return
                end
                passFn()
                schedulePoll(pollsRun + 1)
            end)
            if not ok then
                log.warn("poll chain threw: " .. tostring(err))
                clearInstance(address)
                pcall(stopFn)
            end
        end)
    end
    schedulePoll(0)
end

local function isNativeModOptionsAlive(screenState)
    if screenState.torndown then
        return false
    end
    local ok, valid = pcall(function()
        return screenState.instance ~= nil and screenState.instance:IsValid()
    end)
    return ok and valid == true
end

-- Runs one NativeModOptions match-and-hide pass, updating `entry`'s evidence bookkeeping. Used
-- both for the immediate trigger call and every later poll, so the FIRST successful hide across
-- the whole chain (trigger or poll) is the one that gets the "hid" log, wherever it lands.
local function passNativeModOptions(screenState, model, entry)
    local result, wasVisible = matchNativeModOptionsButton(screenState, model)
    if result == "hidden" and wasVisible then
        if not entry.firstHidLogged then
            entry.firstHidLogged = true
            log.info("hid NativeModOptions' options-screen button (instance " .. entry.n .. ")")
        else
            entry.reHideCount = entry.reHideCount + 1
        end
    end
    return result
end

-- The trigger: matches (and hides) once immediately, then - if the matcher applied at all (gate
-- true, identity present) - starts the bounded poll that keeps re-hiding the button for as long
-- as this screen instance stays open.
local function hideNativeModOptionsButton(screenState, model)
    local address = addressOf(screenState.instance)
    if address == nil then
        return matchNativeModOptionsButton(screenState, model)
    end
    local entry = instanceEntry(address)
    local result = passNativeModOptions(screenState, model, entry)
    if result ~= nil then
        startPollChain(address,
            function() return isNativeModOptionsAlive(screenState) end,
            function() passNativeModOptions(screenState, model, entry) end,
            function()
                if entry.reHideCount > 0 then
                    log.info("NativeModOptions' options-screen button re-hidden "
                        .. entry.reHideCount .. " time(s) on instance " .. entry.n)
                end
            end)
    end
    return result
end

-- Addresses of the ESC menu's own stock named button fields (Config.frameworks.buttonIdentity.
-- palModOptions.vanillaStockButtonFields - a documented PARTIAL roster, honestly, since only one
-- name was ever confirmed from source; see the comment there for the residual risk this leaves).
-- Excluded from PalModOptions matching before caption comparison even runs, so a caption
-- collision with a listed vanilla button can never misfire regardless of what its localized text
-- happens to read.
local function vanillaEscButtonAddresses(menu, fieldNames)
    local set = {}
    for _, field in ipairs(fieldNames or {}) do
        local widget = nil
        pcall(function() widget = menu[field] end)
        local address = addressOf(widget)
        if address ~= nil then
            set[address] = true
        end
    end
    return set
end

-- The pure half of the exclusion step above: given `candidates` (a list of tables each carrying
-- an `address` field - real button widgets in production, plain fixtures in a test) and a set of
-- excluded addresses, returns the candidates that survive. Factored out and exported on Inject
-- so the exclusion behavior itself is directly testable without faking a live UMG widget - only
-- `vanillaEscButtonAddresses` above needs one, to resolve field names to addresses in the first
-- place.
function Inject.filterExcludedAddresses(candidates, excludedAddresses)
    excludedAddresses = excludedAddresses or {}
    local kept = {}
    for _, candidate in ipairs(candidates or {}) do
        if candidate.address ~= nil and not excludedAddresses[candidate.address] then
            kept[#kept + 1] = candidate
        end
    end
    return kept
end

-- Hides PalModOptions' ESC-menu button once every consumer claiming its saved-value store parsed
-- clean at boot. This is a DIFFERENT screen than the options menu (Config.frameworks.
-- buttonIdentity.palModOptions records why: PalModOptions never touches WBP_OptionSettings_C at
-- all). The button group is reached through vanilla's own "Option" button plus GetParent() - the
-- same anchor-and-walk idiom this file already uses for the options screen's buttonContainer -
-- never a recursive tree walk (NativeModOptions' own native_style.lua: "a recursive walk of
-- these pages crashes the game natively, uncatchably").
--
-- Returns "hidden", "ambiguous", "zero" (button group reached but no candidate matched - the
-- caller may retry once), or nil (not applicable this call: gate false, a missing identity
-- field, or a missing symbol that prevented even reaching the button group). A second return
-- value, `wasVisible`, is true only on a "hidden" result where the button was actually visible
-- and got collapsed this call - see matchNativeModOptionsButton's own comment for why.
local function hidePalModOptionsButton(menu, model)
    local identity = Config.frameworks.buttonIdentity
        and Config.frameworks.buttonIdentity.palModOptions
    if identity == nil or identity.frameworkSource == nil or identity.anchorField == nil
        or identity.buttonClassName == nil or identity.captionField == nil
        or identity.captionLiterals == nil then
        return nil
    end
    -- The registry verdict is still computed, because it is the honest record of whether this
    -- mod covers everything PalModOptions does. It no longer VETOES the hide: the read goes
    -- through ModRef, whose surface changes between UE4SS builds, so a failed read used to leave
    -- two mod-settings buttons on the ESC menu with no way for the player to tell why.
    local hide, confirmed = Inject.shouldHideFrameworkButton(model, identity.frameworkSource)
    if not hide then
        return nil
    end
    if not confirmed then
        Inject.logAnomalyOnce(identity.frameworkSource, "escMenuUnconfirmed",
            "hiding PalModOptions' ESC-menu button without confirming every consumer it claims "
            .. "is covered here: its registry could not be read or listed a mod this scan has no "
            .. "entries for. Set Config.frameworks.hideFrameworkButtonWhenUnconfirmed = false to keep "
            .. "its button while that is true")
    end
    if menu == nil or not menu:IsValid() then
        return nil
    end
    local anchor = nil
    pcall(function() anchor = menu[identity.anchorField] end)
    if anchor == nil or not anchor:IsValid() then
        Inject.logAnomalyOnce(identity.frameworkSource, "escMenu",
            "PalModOptions is fully absorbed but the ESC menu's own Option button (anchor for "
            .. "its button group) was not found on at least one open - leaving its button "
            .. "visible that pass")
        return nil
    end
    local group = nil
    pcall(function() group = anchor:GetParent() end)
    if group == nil or not group:IsValid() then
        Inject.logAnomalyOnce(identity.frameworkSource, "escMenu",
            "PalModOptions is fully absorbed but its ESC-menu button group could not be reached "
            .. "on at least one open - leaving its button visible that pass")
        return nil
    end
    local excluded = vanillaEscButtonAddresses(menu, identity.vanillaStockButtonFields)
    -- Ours must never be matched by this matcher, the same way buttonOwner already excludes
    -- ours from matchNativeModOptionsButton on the options screen.
    for address in pairs(escButtonAddresses) do
        excluded[address] = true
    end
    local candidates = {}
    for _, child in ipairs(panelChildren(group)) do
        candidates[#candidates + 1] = { address = addressOf(child), widget = child }
    end
    local matches = {}
    for _, candidate in ipairs(Inject.filterExcludedAddresses(candidates, excluded)) do
        if shortClassOf(candidate.widget) == identity.buttonClassName then
            local caption = captionOf(candidate.widget, identity.captionField)
            if caption ~= nil and identity.captionLiterals[caption] ~= nil then
                matches[#matches + 1] = candidate.widget
            end
        end
    end
    if #matches == 1 then
        local wasVisible = hideIfVisible(matches[1])
        return "hidden", wasVisible
    elseif #matches > 1 then
        Inject.logAnomalyOnce(identity.frameworkSource, "escMenu",
            "multiple ESC-menu buttons matched PalModOptions' class and caption - leaving all "
            .. "visible")
        return "ambiguous"
    end
    Inject.logAnomalyOnce(identity.frameworkSource, "escMenu",
        "PalModOptions is fully absorbed but its ESC-menu button was not found on at least one "
        .. "open - leaving nothing hidden that pass")
    return "zero"
end

local function findRealScrollBox(instance)
    for _, field in ipairs(ui.realPageFields) do
        local ok, page = pcall(function() return instance[field] end)
        if ok and page ~= nil and page:IsValid() then
            local parent = nil
            local parentOk = pcall(function() parent = page:GetParent() end)
            if parentOk and parent ~= nil and parent:IsValid() then
                return parent
            end
        end
    end
    return nil
end

-- Builds the page content and adds it as an extra permanent child of the shared ScrollBox.
local function tryBuildOurPage(screenState, attempt)
    attempt = attempt or 0
    local scrollBox = findRealScrollBox(screenState.instance)
    if scrollBox == nil or not scrollBox:IsValid() then
        if attempt < 3 then
            ExecuteInGameThreadWithDelay(300, function()
                if not screenState.torndown then
                    tryBuildOurPage(screenState, attempt + 1)
                end
            end)
        else
            log.warn("could not find the shared ScrollBox after " .. (attempt + 1)
                .. " attempts - the Mod Configs tab will show no content")
        end
        return
    end
    screenState.scrollBox = scrollBox

    -- ONE VerticalBox, straight into vanilla's own shared ScrollBox, exactly as vanilla composes
    -- its five pages. This page used to build its own WBP_PalCommonScrollList and put the rows in
    -- THAT, which nested a second scroll box inside the screen's own: two scrollbars, an outer one
    -- that barely moved because it was scrolling a fixed-height wrapper, and an inner one holding
    -- every row. A mouse hides the fault, because the wheel scrolls whichever box is under the
    -- pointer; a controller cannot, because the stick drives the outer one and never reaches the
    -- rows. Unacceptable on a controller and on mouse and keyboard alike (2026-09-06).
    local list = Widgets.construct("/Script/UMG.VerticalBox", screenState.instance)
    if list == nil then
        log.warn("failed to construct the list container - Mod Configs will show no content")
        return
    end

    -- The CONTENT is not built here. Panel.build re-reads and re-parses every installed mod's
    -- config, re-derives every label and tooltip, and builds a row per mod; doing that while the
    -- Options screen constructs made the whole Settings menu stall on open even for a player who
    -- never opens this tab (seen 2026-09-04). The container is cheap and stays eager, so the
    -- tab and page exist immediately; the content is built the first time the tab is shown.
    screenState.buildList = list
    screenState.panelState = nil

    -- A SizeBox wrapper for the WIDTH and for visibility: Collapsed removes a widget from layout
    -- regardless of size overrides, and toggling it on the wrapper is how the tab switch works.
    -- NO height override any more. The page is as tall as its rows and vanilla's ScrollBox scrolls
    -- it, which is the whole point of dropping our own scroll box; overriding the height here
    -- would clip every row past the first screenful with nothing left to scroll them.
    screenState.ourPage = Widgets.construct("/Script/UMG.SizeBox", scrollBox)
    if screenState.ourPage ~= nil then
        local wrapped = pcall(function()
            screenState.ourPage:SetWidthOverride(ui.listWidth)
            screenState.ourPage:SetContent(list)
        end)
        if not wrapped then
            screenState.ourPage = list
        end
    else
        screenState.ourPage = list
    end
    -- Attached immediately: an unparented widget can be reclaimed by the engine's GC.
    pcall(function() scrollBox:AddChild(screenState.ourPage) end)
    setVisibility(screenState.ourPage, ui.pageInactiveVisibility)
end

local function buildScreenState(instance, ourButton, buttonContainer)
    local screenState = {
        instance = instance,
        ourButton = ourButton,
        tabMark = {},
        ourButtonAddress = addressOf(ourButton),
        ourInvisibleAddress = addressOf(invisibleChildOf(ourButton)),
        buttonContainer = buttonContainer,
        showing = "vanilla",
    }

    tryBuildOurPage(screenState)

    -- Fired by Staging.stage when a value first diverges; nothing polls.
    Staging.onChanged = function()
        if not screenState.torndown then
            syncPrompt(instance)
        end
    end

    buttonOwner[screenState.ourButtonAddress] = screenState
    if screenState.ourInvisibleAddress ~= nil then
        buttonOwner[screenState.ourInvisibleAddress] = screenState
    end
    for _, field in ipairs(ui.realButtonFields) do
        local ok, button = pcall(function()
            return instance["WBP_OptionSettings_MenuButton_" .. field]
        end)
        if ok and button ~= nil then
            local address = addressOf(button)
            if address ~= nil then
                buttonOwner[address] = screenState
            end
            local invisibleAddress = addressOf(invisibleChildOf(button))
            if invisibleAddress ~= nil then
                buttonOwner[invisibleAddress] = screenState
            end
        end
    end
    return screenState
end

local function teardown(screenState)
    if screenState.torndown then
        return
    end
    screenState.torndown = true
    Staging.onChanged = nil
    pcall(Controls.setPageActive, false)
    -- Code-review fix, 2026-09-01: the NativeModOptions poll chain's own liveness check would
    -- eventually notice torndown and clear itself, but only on its next scheduled tick (up to
    -- pollIntervalMs later); clearing here immediately closes that window and frees the
    -- bookkeeping the moment the screen actually goes away.
    clearInstance(addressOf(screenState.instance))
    local ok, err = pcall(function()
        showVanilla(screenState, false)
        detach(screenState.ourPage)
        Panel.destroy(screenState.panelState, false)
        detach(screenState.ourButton)
        buttonOwner[screenState.ourButtonAddress] = nil
        if screenState.ourInvisibleAddress ~= nil then
            buttonOwner[screenState.ourInvisibleAddress] = nil
        end
        for _, field in ipairs(ui.realButtonFields) do
            local fieldOk, button = pcall(function()
                return screenState.instance["WBP_OptionSettings_MenuButton_" .. field]
            end)
            if fieldOk and button ~= nil then
                local address = addressOf(button)
                if address ~= nil then
                    buttonOwner[address] = nil
                end
                local invisibleAddress = addressOf(invisibleChildOf(button))
                if invisibleAddress ~= nil then
                    buttonOwner[invisibleAddress] = nil
                end
            end
        end
    end)
    if not ok then
        log.warn("teardown threw: " .. tostring(err))
    end
end

-- Every hook is class-level and fires for widgets this mod does not own; each callback resolves
-- its Context and no-ops when it finds nothing.
-- One registration per hook name, retried on every call until it takes: at boot the
-- options-screen classes are not loaded yet and every RegisterHook fails, so the guard is per
-- hook, never a single "done" flag (that flag once froze the tab: every hook failed at boot, the
-- retry from the options screen's own construction was a no-op, and clicks went nowhere).
-- `expectLoaded` is false for the boot attempt, where a failure is expected and stays quiet.
local hooked = {}
local function tryHook(name, expectLoaded, register)
    if hooked[name] then
        return
    end
    local ok, err = pcall(register)
    if ok then
        hooked[name] = true
        log.info("hooked " .. name)
    elseif expectLoaded then
        log.warn("failed to hook " .. name .. ": " .. tostring(err))
    end
end

local function installHooks(expectLoaded)
    tryHook("MenuButton Construct", expectLoaded, function()
        RegisterHook(MENU_BUTTON_CLASS .. ":Construct", function(Context)
            local button = HookParam.read(Context)
            local address = addressOf(button)
            local screenState = address ~= nil and buttonOwner[address] or nil
            if screenState ~= nil and address == screenState.ourButtonAddress then
                relabel(button)
            end
        end)
    end)

    tryHook("ButtonBase BP_OnClicked", expectLoaded, function()
        RegisterHook(BUTTON_BASE_CLASS .. ":BP_OnClicked", function(Context)
            local clicked = HookParam.read(Context)
            local address = addressOf(clicked)
            if address == nil then
                return
            end
            local escMenuState = escClickTargets[address]
            if escMenuState ~= nil then
                ExecuteInGameThreadWithDelay(0, function()
                    pcall(onEscButtonClicked, escMenuState)
                end)
                return
            end
            local screenState = buttonOwner[address]
            if screenState ~= nil then
                if address == screenState.ourInvisibleAddress
                    or address == screenState.ourButtonAddress then
                    relabel(screenState.ourButton)
                    ExecuteInGameThreadWithDelay(0, function()
                        if not screenState.torndown then
                            showOurs(screenState)
                        end
                    end)
                else
                    ExecuteInGameThreadWithDelay(0, function()
                        if not screenState.torndown then
                            showVanilla(screenState, false)
                        end
                    end)
                end
                return
            end
            -- Unknown click while a screen shows our page: another mod's injected category
            -- button hands the page back; anything else (a row control, an unrelated button)
            -- is ignored.
            for _, candidate in pairs(screens) do
                if not candidate.torndown and candidate.showing == "ours" then
                    if categorySiblingAddresses(candidate)[address] then
                        ExecuteInGameThreadWithDelay(0, function()
                            if not candidate.torndown then
                                showVanilla(candidate, true)
                            end
                        end)
                    end
                end
            end
        end)
    end)

    -- Q/E page through mods while our page shows. These are the screen's own actions; on other
    -- tabs they keep their vanilla meaning.
    for _, tab in ipairs({ { name = "PreTab", delta = -1 }, { name = "NextTab", delta = 1 } }) do
        tryHook(tab.name, expectLoaded, function()
            RegisterHook(OPTION_SETTINGS_CLASS .. ":" .. tab.name, function(Context)
                local screenState = screens[addressOf(HookParam.read(Context))]
                if screenState == nil or screenState.showing ~= "ours" then
                    return
                end
                ExecuteInGameThreadWithDelay(0, function()
                    if screenState.torndown or screenState.showing ~= "ours" then
                        return
                    end
                    Panel.stepMod(screenState.panelState, tab.delta)
                    -- The action may also have driven vanilla's own switch; hold our page.
                    assertOurPage(screenState)
                end)
            end)
        end)
    end

    -- The apply prompt answers for OUR edits only when a restart-required mod is among them;
    -- otherwise it is vanilla's own prompt about vanilla's own settings and must not touch mod
    -- configs, which ClosePanel has already saved. Deliberately not gated on
    -- a live screen: the prompt is answered while the screen is already closing.
    tryHook("ApplySettings", expectLoaded, function()
        RegisterHook(OPTION_SETTINGS_CLASS .. ":ApplySettings", function(Context, Confirmed)
            if not ourPromptGoverns() then
                return
            end
            local screenState = screens[addressOf(HookParam.read(Context))]
            local panelState = screenState ~= nil and screenState.panelState or nil
            if HookParam.read(Confirmed) ~= true then
                Panel.discardAll(panelState)
                return
            end
            -- A value typed into a slider's box and never blurred is still held; Apply is the
            -- other moment it commits, and it has to land before applyAll reads the staging set.
            Controls.commitPending()
            Panel.applyAll(panelState)
        end)
    end)

    -- Restore-to-Default (the screen's F action) STAGES the file-at-open values; Apply commits.
    -- Gated on our page showing: pressing F on the Graphics tab must not touch mod configs.
    tryHook("SetDefaultAction", expectLoaded, function()
        RegisterHook(OPTION_SETTINGS_CLASS .. ":SetDefaultAction", function(Context)
            local screenState = screens[addressOf(HookParam.read(Context))]
            if screenState ~= nil and screenState.showing == "ours"
                and screenState.panelState ~= nil then
                Panel.resetAll(screenState.panelState)
            end
        end)
    end)

    -- The confirmation half of the same F action, kept as a second entry point; double fire is
    -- harmless (the same values are staged twice).
    tryHook("SetDefault", expectLoaded, function()
        RegisterHook(OPTION_SETTINGS_CLASS .. ":SetDefault", function(Context, Confirmed)
            local screenState = screens[addressOf(HookParam.read(Context))]
            if screenState ~= nil and screenState.showing == "ours"
                and screenState.panelState ~= nil
                and HookParam.read(Confirmed) == true then
                Panel.resetAll(screenState.panelState)
            end
        end)
    end)

    -- OnSetup/OpenPanel fire when the screen is set up or reopened (NotifyOnNewObject cannot see
    -- a reused instance). inject() is idempotent, so multiple trigger points are safe.
    for _, functionName in ipairs({ "OnSetup", "OpenPanel" }) do
        tryHook(functionName, expectLoaded, function()
            RegisterHook(OPTION_SETTINGS_CLASS .. ":" .. functionName, function(Context)
                local instance = HookParam.read(Context)
                if instance ~= nil then
                    inject(instance)
                end
            end)
        end)
    end

    -- ClosePanel fires BEFORE ApplySettings and must only hide: tearing down there destroys the
    -- row widgets while a pending apply is still unanswered.
    tryHook("ClosePanel", expectLoaded, function()
        RegisterHook(OPTION_SETTINGS_CLASS .. ":ClosePanel", function(Context)
            local screenState = screens[addressOf(HookParam.read(Context))]
            -- Leaving the screen SAVES mod config edits, with no prompt: that is the whole point
            -- of not raising vanilla's flag for them. The one set that waits is a mod the catalog
            -- records as needing a relaunch, whose prompt is on screen unanswered right now.
            if not ourPromptGoverns() and Staging.hasChanges() then
                pcall(Controls.commitPending)
                Panel.applyAll(screenState ~= nil and screenState.panelState or nil)
            end
            if screenState ~= nil then
                showVanilla(screenState, false)
            end
        end)
    end)

    -- Destruct is where teardown actually happens; Apply has been answered by then.
    tryHook("Destruct", expectLoaded, function()
        RegisterHook(OPTION_SETTINGS_CLASS .. ":Destruct", function(Context)
            local address = addressOf(HookParam.read(Context))
            local screenState = address ~= nil and screens[address] or nil
            if screenState ~= nil then
                teardown(screenState)
                screens[address] = nil
                injected[address] = nil
            end
        end)
    end)
end

-- The other half of the pending-select handoff (see the "our own ESC button" section further
-- down for where the flag is armed): once the flag is set and still live, selects our category
-- exactly as a click on our own category button does (showOurs, the same function the
-- BP_OnClicked hook above calls). Clears the flag either way, so a stale or already-handled
-- request can never fire twice.
-- `screenSeenAtMs` is the timestamp inject() captured at the top of the specific call that led
-- here (see inject() below) - the "this screen-open event" clock reading Inject.
-- shouldConsumePendingSelect compares against the arming moment.
local function maybeSelectOurs(screenState, screenSeenAtMs)
    if pendingSelectArmedAtMs == nil then
        return
    end
    local escUi = Config.ui.escMenu
    local nowMs = os.clock() * 1000
    local shouldSelect = Inject.shouldConsumePendingSelect(pendingSelectArmedAtMs, screenSeenAtMs,
        nowMs, escUi ~= nil and escUi.pendingSelectTimeoutMs or 0)
    pendingSelectArmedAtMs = nil
    pendingSelectSourceMenuAddress = nil
    if not shouldSelect or screenState == nil or screenState.torndown then
        return
    end
    showOurs(screenState)
end

-- Scheduled on the game thread, after the screen has settled (the same
-- ui.switchReassertMs delays the tab-switch handoff above already uses; the largest one is the
-- point by which the Control-tab layout and any of its own re-show animations have finished).
-- `screenSeenAtMs` is captured by the caller at the moment THIS screen-open event was observed
-- (the top of inject()), not when this delayed callback actually fires.
local function scheduleMaybeSelectOurs(screenState, screenSeenAtMs)
    if screenState == nil then
        return
    end
    local delay = ui.switchReassertMs[#ui.switchReassertMs] or 0
    ExecuteInGameThreadWithDelay(delay, function()
        if not screenState.torndown then
            maybeSelectOurs(screenState, screenSeenAtMs)
        end
    end)
end

function inject(instance)
    local address = addressOf(instance)
    if address == nil then
        return true
    end
    -- Captured once per call, at the top: the clock reading for THIS screen-open event, which
    -- maybeSelectOurs compares against the pending-select arming moment (see
    -- Inject.shouldConsumePendingSelect) so a stale scheduled callback from an OLDER open can
    -- never consume a newer arm.
    local screenSeenAtMs = os.clock() * 1000
    -- Honest success for the Mod Configs ESC button's open trigger: this call to
    -- inject() IS the "an options screen was seen" event Inject.escOptionOpenConfirmed compares
    -- against escOpenClickedAtMs. Checked before anything else so both hook paths that reach
    -- inject() (OnSetup and OpenPanel) confirm identically, whichever fires first, and the
    -- retry chain in attemptEscOpen (escOpenActiveEpoch cleared here) stops on the next check.
    if escOpenActiveEpoch ~= nil and Inject.escOptionOpenConfirmed(escOpenClickedAtMs,
        screenSeenAtMs, Config.ui.escMenu.openTimeoutMs) then
        escOpenConfirmedMethodIndex = escOpenAttemptIndex
        escOpenActiveEpoch = nil
        local method = (Config.ui.escMenu.openMethods or {})[escOpenAttemptIndex]
        logEscOptionTriggerMethodOnce(method ~= nil and method.name or "an unknown method")
    end
    if injected[address] then
        local existing = screens[address]
        local buttonAlive = false
        if existing ~= nil and existing.ourButton ~= nil then
            local ok, hasParent = pcall(function()
                return existing.ourButton:IsValid() and existing.ourButton:GetParent() ~= nil
                    and existing.ourButton:GetParent():IsValid()
            end)
            buttonAlive = ok and hasParent == true
        end
        if buttonAlive then
            hideNativeModOptionsButton(existing, Scanner.cachedModel())
            scheduleMaybeSelectOurs(existing, screenSeenAtMs)
            return true
        end
        -- The screen rebuilt its own button row since we last injected (our button was
        -- destroyed along with it, address unchanged): tear down the stale state and
        -- reinject rather than silently leaving the Mod Configs button gone.
        log.info("Mod Configs button no longer present - reinjecting")
        if existing ~= nil then
            teardown(existing)
        end
        screens[address] = nil
        injected[address] = nil
    end
    installHooks(true)

    local anchorButton = nil
    pcall(function() anchorButton = instance.WBP_OptionSettings_MenuButton_Graphic end)
    if anchorButton == nil or not anchorButton:IsValid() then
        return false
    end
    local buttonContainer = nil
    pcall(function() buttonContainer = anchorButton:GetParent() end)
    if buttonContainer == nil or not buttonContainer:IsValid() then
        return false
    end

    local ourButton = Widgets.createUserWidget(instance, MENU_BUTTON_CLASS, ui.menuButtonAsset)
    if ourButton == nil then
        return false
    end
    relabel(ourButton)

    local added = pcall(function() buttonContainer:AddChildToHorizontalBox(ourButton) end)
        or pcall(function() buttonContainer:AddChildToVerticalBox(ourButton) end)
        or pcall(function() buttonContainer:AddChild(ourButton) end)
    if not added then
        detach(ourButton)
        return false
    end
    relabel(ourButton)   -- again: attaching to the live tree can trigger a caption resync

    screens[address] = buildScreenState(instance, ourButton, buttonContainer)
    injected[address] = true
    hideNativeModOptionsButton(screens[address], Scanner.cachedModel())
    log.info("injected the Mod Configs category")
    scheduleMaybeSelectOurs(screens[address], screenSeenAtMs)
    return true
end

local function queueInjection(instance, attempt)
    local address = addressOf(instance)
    if address == nil then
        return
    end
    attempt = attempt or 0
    local epoch = (epochs[address] or 0) + 1
    epochs[address] = epoch
    ExecuteInGameThreadWithDelay(attempt == 0 and 50 or 200, function()
        if epochs[address] ~= epoch then
            return
        end
        if addressOf(instance) == nil then
            return
        end
        if not inject(instance) and attempt < 4 then
            queueInjection(instance, attempt + 1)
        end
    end)
end

-- Code-review fix, 2026-09-01 (Minor finding): IsValid alone is not enough - if WBP_MenuESC_C is
-- hidden rather than destroyed when the player closes the menu (common for a persistent Slate
-- widget), IsValid stays true and the chain would run to the full 120-poll cap while the menu
-- sits closed. A second liveness signal: prefer the reflected IsVisible() bool where the widget
-- exposes one, falling back to comparing its own Visibility property against
-- ui.pageInactiveVisibility when it does not. Two CONSECUTIVE invisible polls (not one) end the
-- chain, so a single frame of transitional invisibility during a legitimate re-show cannot cut it
-- short.
local function isMenuVisible(menu)
    local visible = nil
    local ok = pcall(function() visible = menu:IsVisible() end)
    if ok and visible ~= nil then
        return visible == true
    end
    local visibility = nil
    pcall(function() visibility = menu.Visibility end)
    if visibility == nil then
        return true
    end
    return visibility ~= ui.pageInactiveVisibility
end

local function isPalModOptionsAlive(menu, entry, pollsRun)
    local ok, valid = pcall(function() return menu ~= nil and menu:IsValid() end)
    if not ok or valid ~= true then
        return false
    end
    if Inject.withinVisibilityGracePeriod(pollsRun, Config.frameworks.pollScheduleMs,
        Config.frameworks.pollVisibilityGracePolls) then
        entry.invisibleStreak = 0
        return true
    end
    if isMenuVisible(menu) then
        entry.invisibleStreak = 0
        return true
    end
    entry.invisibleStreak = (entry.invisibleStreak or 0) + 1
    return entry.invisibleStreak < 2
end

-- Runs one PalModOptions match-and-hide pass, same shape as passNativeModOptions above: updates
-- `entry`'s evidence bookkeeping, and is used both for the immediate trigger call and every later
-- poll so the first successful hide anywhere in the chain gets the "hid" log.
local function passPalModOptions(menu, model, entry)
    local result, wasVisible = hidePalModOptionsButton(menu, model)
    if result == "hidden" and wasVisible then
        if not entry.firstHidLogged then
            entry.firstHidLogged = true
            log.info("hid PalModOptions' ESC-menu button (instance " .. entry.n .. ")")
        else
            entry.reHideCount = entry.reHideCount + 1
        end
    end
    return result
end

-- ============================ Our own ESC-menu button ============================
--
-- A "Mod Configs" button on the in-world ESC menu, in the same slot PalModOptions injects its
-- own "Mod Options" button into, opening the options screen on our tab. Every symbol is in
-- Config.ui.escMenu; nothing here is a literal.

-- escButtonState, escButtonAddresses and escClickTargets are all declared near the top of the
-- file: escButtonAddresses is read by hidePalModOptionsButton (above) and escClickTargets by
-- installHooks' shared click hook (also above), both defined earlier than this section.
local function ourEscButtonStillPresent(group, address)
    if address == nil then
        return false
    end
    for _, child in ipairs(panelChildren(group)) do
        if addressOf(child) == address then
            return true
        end
    end
    return false
end

-- Builds this mod's own "Mod Configs" ESC-menu button if it is missing from `menu`'s button
-- group: absent on the first construction of a fresh instance, or absent again if a poll finds
-- the tracked address no longer among the group's children. Never-crash: every widget call
-- pcall-guarded; a failure to build logs once and degrades (no ESC button that pass), the same
-- idiom hidePalModOptionsButton above already uses.
local function buildEscButton(menu)
    local escUi = Config.ui.escMenu
    if escUi == nil or menu == nil or not menu:IsValid() then
        return
    end
    local menuAddress = addressOf(menu)
    if menuAddress == nil then
        return
    end
    local anchor = nil
    pcall(function() anchor = menu[escUi.anchorField] end)
    if anchor == nil or not anchor:IsValid() then
        Inject.logAnomalyOnce("ours:escMenu", "buildAnchorMissing",
            "could not find the ESC menu's own Option button (anchor) - the Mod Configs ESC "
            .. "button will not be added that pass")
        return
    end
    local group = nil
    pcall(function() group = anchor:GetParent() end)
    if group == nil or not group:IsValid() then
        Inject.logAnomalyOnce("ours:escMenu", "buildGroupMissing",
            "could not reach the ESC menu's button group - the Mod Configs ESC button will not "
            .. "be added that pass")
        return
    end

    local state = escButtonState[menuAddress]
    if state ~= nil and ourEscButtonStillPresent(group, state.ourButtonAddress) then
        return
    end

    local button = Widgets.createUserWidget(menu, escUi.buttonClass, escUi.buttonAsset)
    if button == nil then
        Inject.logAnomalyOnce("ours:escMenu", "buildFailed",
            "failed to construct the Mod Configs ESC button - leaving the ESC menu without it")
        return
    end
    pcall(function() button[escUi.captionField]:SetText(FText(I18n.t("category_label"))) end)
    Rows.setTooltip(button, I18n.t("esc_tip"))

    if Widgets.insertAfter(group, anchor, button) == nil then
        Inject.logAnomalyOnce("ours:escMenu", "buildInsertFailed",
            "failed to insert the Mod Configs ESC button after the ESC menu's Option button")
        detach(button)
        return
    end

    local buttonAddress = addressOf(button)
    local invisibleAddress = addressOf(invisibleChildOf(button))
    escButtonState[menuAddress] = { ourButtonAddress = buttonAddress,
        invisibleAddress = invisibleAddress }
    local menuState = { menu = menu }
    if buttonAddress ~= nil then
        escButtonAddresses[buttonAddress] = true
        escClickTargets[buttonAddress] = menuState
    end
    if invisibleAddress ~= nil then
        escButtonAddresses[invisibleAddress] = true
        escClickTargets[invisibleAddress] = menuState
    end
end

-- pendingSelectArmedAtMs/pendingSelectSourceMenuAddress are declared near the top of the file,
-- ahead of inject() (which reads and clears them - see maybeSelectOurs there) and clearInstance
-- (which also clears them when the arming ESC menu's own chain stops).
--
-- Code-review fix, 2026-09-01 (Important finding): the old pendingSelectStillLive checked only
-- elapsed time, so a bare armed flag could consume against ANY later options-screen open within
-- the timeout - including one wholly unrelated to the click that armed it, if the trigger
-- silently no-op'd. Consumption now also requires the SPECIFIC screen-open event inject() is
-- processing (`screenSeenAtMs`, captured fresh at the top of every inject() call) to have
-- happened at or after the arming moment: a stale in-flight maybeSelectOurs callback scheduled
-- for a screen that opened BEFORE the click can never consume a later arm meant for a different,
-- newer open. Exported and pure so the boundary is directly testable without a live game clock.
function Inject.shouldConsumePendingSelect(armedAtMs, screenSeenAtMs, nowMs, timeoutMs)
    if armedAtMs == nil or screenSeenAtMs == nil or nowMs == nil or timeoutMs == nil then
        return false
    end
    if screenSeenAtMs < armedAtMs then
        return false
    end
    return nowMs >= armedAtMs and (nowMs - armedAtMs) < timeoutMs
end

-- Found in a live session, 2026-09-01: the button used to log a false "opened the options
-- screen" line by treating a Blueprint EVENT call's own success (the pcall not throwing) as
-- proof the screen opened. Calling a Blueprint event only runs ITS graph; nothing observed
-- afterward ever actually showed the options screen. Header-dump evidence (CXXHeaderDump/Pal.hpp,
-- read 2026-09-01 23:28-23:30) exposes the real native call: a trigger "returning" is no longer
-- treated as success at all - the screen must actually be SEEN (inject()'s own OnSetup/OpenPanel
-- path) within Config.ui.escMenu.openTimeoutMs of the click.
local escOptionTriggerFailedLogged = false
local function logEscOptionTriggerFailedOnce()
    if escOptionTriggerFailedLogged then
        return
    end
    escOptionTriggerFailedLogged = true
    log.warn("could not open the options screen from the Mod Configs ESC button - tried: "
        .. table.concat(Inject.openMethodNames(Config.ui.escMenu.openMethods), ", "))
end

local escOptionSuccessLogged = false
function logEscOptionTriggerMethodOnce(methodName)
    if escOptionSuccessLogged then
        return
    end
    escOptionSuccessLogged = true
    log.info("opened the options screen from the Mod Configs ESC button via " .. methodName)
end

-- Plain list of an openMethods table's own `name` fields, in order - the exact roster
-- logEscOptionTriggerFailedOnce reports once every method has been tried and none produced a
-- screen. Exported (not that it needs an engine call) purely so the log text itself is checkable
-- from a fixture without duplicating the join logic there.
function Inject.openMethodNames(openMethods)
    local names = {}
    for _, method in ipairs(openMethods or {}) do
        names[#names + 1] = method.name
    end
    return names
end

-- The pure "what next" decision behind the method-cycling retry: given the method index just
-- tried (1-based) and how many methods exist, returns the next index to try, or nil once every
-- method has been tried. Exported and pure so the cycling boundary is directly testable.
function Inject.nextOpenMethodIndex(triedIndex, totalMethods)
    if triedIndex == nil or totalMethods == nil then
        return nil
    end
    local nextIndex = triedIndex + 1
    if nextIndex > totalMethods then
        return nil
    end
    return nextIndex
end

-- The pure "did it actually work" decision inject() applies: a click at `clickedAtMs` is
-- confirmed to have opened the options screen when a screen-open event is observed at or after
-- that moment and within `timeoutMs` of it. Exported and pure so the boundary is directly
-- testable without a live game clock, the same idiom Inject.shouldConsumePendingSelect already
-- uses for the related pending-select handoff.
function Inject.escOptionOpenConfirmed(clickedAtMs, screenSeenAtMs, timeoutMs)
    if clickedAtMs == nil or screenSeenAtMs == nil or timeoutMs == nil then
        return false
    end
    if screenSeenAtMs < clickedAtMs then
        return false
    end
    return (screenSeenAtMs - clickedAtMs) < timeoutMs
end

-- Tries firing the vanilla Option button through one method, without judging whether it worked -
-- only inject() seeing an actual options screen appear counts as proof. Every branch pcall-guarded
-- per the project invariant; a throw here just means this attempt produced nothing observable,
-- exactly like a silent no-op would.
local function tryOpenMethod(optionButton, method)
    local escUi = Config.ui.escMenu
    if method.kind == "hud" then
        pcall(function()
            local hud = FindFirstOf("PalHUDInGame")
            if hud == nil or not hud:IsValid() then
                return
            end
            local class = StaticFindObject(OPTION_SETTINGS_CLASS)
            if class == nil or not class:IsValid() then
                pcall(function() LoadAsset(ui.optionSettingsAsset) end)
                class = StaticFindObject(OPTION_SETTINGS_CLASS)
            end
            if class == nil or not class:IsValid() then
                return
            end
            hud:PushWidgetStackableUI(class, nil)
        end)
    elseif method.kind == "invisibleChild" then
        pcall(function() optionButton[escUi.optionButtonInvisibleChildField]:BP_OnClicked() end)
    elseif method.kind == "own" then
        pcall(function() optionButton:BP_OnClicked() end)
    elseif method.kind == "boundEvent" then
        pcall(function() optionButton[escUi.clickBoundEvent](optionButton) end)
    end
end

-- Fires method `index`, records the in-flight attempt for inject() to judge, and schedules the
-- next method after openTimeoutMs if this one never produces a seen screen. `menu`/`optionButton`
-- are captured in the closure so the retry chain needs no per-instance state beyond the epoch.
local function attemptEscOpen(menu, optionButton, index)
    local escUi = Config.ui.escMenu
    local methods = escUi.openMethods or {}
    if index > #methods then
        escOpenActiveEpoch = nil
        escOpenExhausted = true
        logEscOptionTriggerFailedOnce()
        return
    end
    escOpenEpoch = escOpenEpoch + 1
    local epoch = escOpenEpoch
    escOpenActiveEpoch = epoch
    escOpenAttemptIndex = index
    escOpenClickedAtMs = os.clock() * 1000
    -- Armed regardless of what tryOpenMethod observes: the pending-select handoff already has
    -- its own independent timeout (pendingSelectTimeoutMs) and no-ops harmlessly if this attempt
    -- never actually opens anything.
    pendingSelectArmedAtMs = escOpenClickedAtMs
    pendingSelectSourceMenuAddress = addressOf(menu)
    tryOpenMethod(optionButton, methods[index])
    -- Code-review fix, 2026-09-01 (Minor finding): pcall-guarded to match every other scheduled
    -- callback in this file (startPollChain's, above) - a throw here (from
    -- Inject.nextOpenMethodIndex, attemptEscOpen's own recursion, or anything else) would
    -- otherwise leave escOpenActiveEpoch permanently set to this epoch, wedging the button for
    -- the rest of the session instead of degrading to one log line.
    ExecuteInGameThreadWithDelay(escUi.openTimeoutMs, function()
        local ok, err = pcall(function()
            if escOpenActiveEpoch ~= epoch then
                -- Superseded: inject() already confirmed success, or a newer attempt is in flight.
                return
            end
            local nextIndex = Inject.nextOpenMethodIndex(index, #methods)
            if nextIndex == nil then
                escOpenActiveEpoch = nil
                escOpenExhausted = true
                logEscOptionTriggerFailedOnce()
                return
            end
            attemptEscOpen(menu, optionButton, nextIndex)
        end)
        if not ok then
            log.warn("Mod Configs ESC-open retry threw: " .. tostring(err))
        end
    end)
end

-- Runs on a click on our own ESC button (resolved via escClickTargets in the shared
-- BUTTON_BASE_CLASS click hook, installHooks above). Starts (or ignores, while one is already in
-- flight or all methods are exhausted) the method-cycling attempt above; a confirmed method is
-- reused directly rather than re-cycling through methods already known not to work.
function onEscButtonClicked(menuState)
    local menu = menuState ~= nil and menuState.menu or nil
    if menu == nil or not menu:IsValid() then
        return
    end
    if escOpenExhausted or escOpenActiveEpoch ~= nil then
        return
    end
    local escUi = Config.ui.escMenu
    local optionButton = nil
    pcall(function() optionButton = menu[escUi.anchorField] end)
    if optionButton == nil or not optionButton:IsValid() then
        Inject.logAnomalyOnce("ours:escMenu", "clickAnchorMissing",
            "could not find the vanilla Option button to open the options screen from the Mod "
            .. "Configs ESC button")
        return
    end
    attemptEscOpen(menu, optionButton, escOpenConfirmedMethodIndex or 1)
end

-- The trigger for the ESC-menu path: builds/maintains our own button and matches (and hides)
-- PalModOptions' - a "zero" result from the hide attempt here is the common case, not an
-- anomaly, since a freshly constructed menu's children may not exist yet on this very first
-- callback (NotifyOnNewObject fires as the object is created, ahead of its own widget tree
-- finishing layout) - then starts the bounded poll that keeps both jobs current for as long as
-- this menu instance stays open. The poll chain used to start only when the PalModOptions-hiding
-- gate applied (the framework fully absorbed); it now always starts, since building and
-- maintaining our own button must not depend on that gate at all.
local function startPalModOptionsPoll(menu, model)
    local address = addressOf(menu)
    if address == nil then
        return
    end
    local entry = instanceEntry(address)
    buildEscButton(menu)
    passPalModOptions(menu, model, entry)
    startPollChain(address,
        function(pollsRun) return isPalModOptionsAlive(menu, entry, pollsRun) end,
        function()
            buildEscButton(menu)
            passPalModOptions(menu, model, entry)
        end,
        function()
            if entry.reHideCount > 0 then
                log.info("PalModOptions' ESC-menu button re-hidden " .. entry.reHideCount
                    .. " time(s) on instance " .. entry.n)
            end
        end)
end

-- Logged once per session, the first time the ESC-menu callback fires, so the log carries direct
-- evidence the NotifyOnNewObject(escMenuClass, ...) path is actually alive - on 2026-09-01 the
-- log carried no trace of it firing either way.
local escMenuConstructLogged = false

-- PalModOptions' ESC menu is a screen this mod never otherwise touches, so its hiding hook is
-- registered independently of the options-screen flow above: a player can open the ESC menu
-- without ever visiting Options this session, and RegisterHook(":Construct") alone is enough
-- (PalModOptions' own install_construct_hook() drives its entire re-injection cycle from that
-- one hook, with no separate OnSetup/OpenPanel-style re-trigger of its own).
local function installEscMenuHook()
    if escHooksInstalled then
        return
    end
    escHooksInstalled = true
    -- The shared BUTTON_BASE_CLASS click hook (which resolves a click on our own ESC button
    -- through escClickTargets) lives in installHooks; a player who never opens the options
    -- screen this session would otherwise never get it registered.
    installHooks(false)
    local identity = Config.frameworks.buttonIdentity
        and Config.frameworks.buttonIdentity.palModOptions
    if identity == nil or identity.escMenuClass == nil then
        return
    end
    local ok, err = pcall(function()
        NotifyOnNewObject(identity.escMenuClass, function(menu)
            -- The project invariant is every game call pcall-guarded. `hidePalModOptionsButton`
            -- calls `:IsValid()`/`:GetParent()` on live widgets it just read via reflection;
            -- wrapping the whole callback body here (both the immediate call and the poll it
            -- starts) matches the pcall-then-log-warn style every other hook registration in
            -- this file already uses, so a genuinely unexpected throw degrades to one log line
            -- instead of taking the callback down.
            local bodyOk, bodyErr = pcall(function()
                if not escMenuConstructLogged then
                    escMenuConstructLogged = true
                    log.info("WBP_MenuESC_C constructed - watching for PalModOptions' button")
                end
                startPalModOptionsPoll(menu, Scanner.cachedModel())
            end)
            if not bodyOk then
                log.warn("WBP_MenuESC_C construction handling threw: " .. tostring(bodyErr))
            end
            return false
        end)
    end)
    if not ok then
        log.warn("failed to watch for WBP_MenuESC_C - PalModOptions' ESC-menu button will "
            .. "not be hidden even when fully absorbed: " .. tostring(err))
    end
end

function Inject.install()
    local ok, err = pcall(function()
        NotifyOnNewObject(OPTION_SETTINGS_CLASS, function(instance)
            -- The class is definitely loaded here, so hooks register in time to catch this same
            -- instance's own OnSetup; queueInjection's retries remain the fallback.
            installHooks(true)
            queueInjection(instance)
            return false
        end)
    end)
    if not ok then
        log.error("could not watch for the options screen: " .. tostring(err)
            .. " - Universal Config Manager is disabled this session")
    end
    -- The screen can already exist when this mod starts: the main menu is clickable while
    -- UE4SS is still starting mods (about sixty on one real install, this one near the end
    -- of the alphabet), and an Options screen opened in that window was created before the
    -- watch above existed, so the watch never fired for it (2026-09-03: the first open showed
    -- no Mod Configs tab, the next open did). Inject into a live instance now; when no
    -- screen exists yet this costs one FindFirstOf.
    local found, existing = pcall(FindFirstOf, "WBP_OptionSettings_C")
    if found and existing ~= nil and existing:IsValid() then
        log.info("options screen already open at start - injecting into it now")
        installHooks(true)
        queueInjection(existing)
    end
    installEscMenuHook()
end

return Inject
