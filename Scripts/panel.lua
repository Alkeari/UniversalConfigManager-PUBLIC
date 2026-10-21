-- Builds and operates the page content. Two views inside one VerticalBox:
--   home - one clickable button per mod (no more arrowing through every mod), headed by the
--          relaunch notice and the Advanced Mode switch (it is universal: nothing live-applies
--          in this version).
--   mod  - a back button, a title row for the mod, a section header per file (an "Advanced"
--          header once, ahead of the first advanced file, when Advanced Mode is on), a
--          sub-header per group inside a file, and rows classified by rowspec.lua. A setting's
--          description, if it has one, is a tooltip on the row's own widget, never a line of
--          its own.
--
-- The scan model comes from the boot-time cache and is value-refreshed here without any
-- directory listing (the shell listing fallback flashes a console window; file reads do not). Rows are built per
-- mod, not all at once: one mod's worst case (~120 rows) is the scale the screen handles.
local Browser = require("browser")
local Clipboard = require("clipboard")
local Config = require("config")
local Controls = require("controls")
local Entries = require("entries")
local Rows = require("rows")
local RowSpec = require("rowspec")
local Scanner = require("scanner")
local Staging = require("staging")
local Gamepad = require("gamepad")
local Store = require("store")
local Upload = require("upload")
local I18n = require("i18n")
local Presets = require("presets")
local Present = require("present")
local Requests = require("requests")
local Widgets = require("widgets")
local log = require("logger")

local Panel = {}

local function addToList(state, widget, leftAligned)
    if widget == nil then
        return
    end
    state.viewWidgets[#state.viewWidgets + 1] = widget
    if state.collect ~= nil then
        state.collect[#state.collect + 1] = widget
    end
    local ok, slot = pcall(function()
        return state.list:AddChildToVerticalBox(widget)
    end)
    if ok and slot ~= nil and slot:IsValid() then
        if leftAligned then
            pcall(function() slot:SetHorizontalAlignment(1) end)
        else
            -- A one-unit gap under every row lets the page show through as the hairline
            -- separator the design system draws between rows.
            pcall(function() slot:SetPadding({ Left = 0, Top = 0, Right = 0, Bottom = 1 }) end)
        end
    end
end

-- Adds the Possible Entries strip as a full-width child (EHorizontalAlignment Fill = 0) with
-- Config.ui.controls.hint.slotPadding, so its text starts at the row label's column and ends
-- at the text box's right edge whatever the list's real width is (the row renders 1173 units
-- in practice while Config.ui.listWidth says 786: nothing here anchors to that).
local function addToListStrip(state, widget)
    if widget == nil then
        return
    end
    state.viewWidgets[#state.viewWidgets + 1] = widget
    if state.collect ~= nil then
        state.collect[#state.collect + 1] = widget
    end
    local ok, slot = pcall(function()
        return state.list:AddChildToVerticalBox(widget)
    end)
    if ok and slot ~= nil and slot:IsValid() then
        local pad = Config.ui.controls.hint.slotPadding
        pcall(function() slot:SetHorizontalAlignment(0) end)
        pcall(function()
            slot:SetPadding({ Left = pad.left, Top = pad.top, Right = pad.right, Bottom = pad.bottom })
        end)
    end
end

-- The "Copy request" row, on the home view (every mod) or a mod page (that mod): only built
-- when something is still undescribed, so the control is never dead. A click writes the
-- Save and Revert for one scope: a single mod on its own page, or every mod from the home page.
-- Built once and then shown or hidden, rather than rebuilt when the pending set changes: a
-- rebuild would tear down the row the player is editing. `modName` nil is the whole screen.
local function addPendingRow(state, modName)
    -- One label for both scopes. The page above it already says which mod, the tooltips say what
    -- each button covers, and a scope spelled out in the label overflowed the row in 13 of the 17
    -- languages (measured 2026-09-06).
    local scopeLabel = I18n.t("pending_all")
    local row = Rows.createActionRow(state.worldContext, scopeLabel, {
        { caption = I18n.t("pending_save"), tooltip = I18n.t(modName ~= nil
            and "pending_save_one_tip" or "pending_save_all_tip"), variant = "primary",
            onClick = function() Panel.saveScope(state, modName) end },
        { caption = I18n.t("pending_revert"), tooltip = I18n.t(modName ~= nil
            and "pending_revert_one_tip" or "pending_revert_all_tip"), variant = "secondary",
            onClick = function() Panel.revertScope(state, modName) end },
    })
    if row == nil then
        return
    end
    addToList(state, row, false)
    state.pendingRows[#state.pendingRows + 1] = { widget = row, modName = modName }
    Panel.refreshPendingRows(state)
end

-- Shows each pending row only while its own scope has something to save. Cheap enough for the
-- poll tick: one pass over the staged set per row.
function Panel.refreshPendingRows(state)
    if state == nil or state.torndown or state.pendingRows == nil then
        return
    end
    for _, record in ipairs(state.pendingRows) do
        local widget = record.widget
        if widget ~= nil and widget:IsValid() then
            local visibility = Staging.hasChanges(record.modName)
                and Config.ui.controls.pendingVisibleVisibility
                or Config.ui.controls.pendingHiddenVisibility
            pcall(function() widget:SetVisibility(visibility) end)
        end
    end
end

local function clearView(state, bookkeepingOnly)
    -- Anything typed and not yet committed is staged BEFORE the widgets go, since a held value
    -- is read from a live box and leaving the page is one of the two moments it commits.
    if not bookkeepingOnly then
        Controls.commitPending()
    end
    for _, widget in ipairs(state.viewWidgets) do
        Rows.destroy(widget, bookkeepingOnly)
    end
    state.viewWidgets = {}
    state.rowRecords = {}
    state.pendingRows = {}
    Controls.clear()
    -- Every widget above is gone now, so drop the references rows.lua still holds into them
    -- (the font reference and the deferred font/size queues). Leaving them dangling crashed the
    -- game on leaving the Presets page for All Mods (2026-09-04).
    Rows.resetTransient()
end

-- The strip's headline: collapsed, the label plus as many sample values as fit the strip's
-- width (never the label alone: the hint has to be readable in one line, and a bare button
-- conveys nothing); expanded, the short form. Both strings, affordance included, live in ui.tsv.
-- Just the label, in both states: the chevron shows which state it is in, and a truncated
-- sample squeezed the caption into an unreadable strip (seen 2026-09-03 22:49).
local function hintCaption()
    return I18n.t("hint_toggle")
end

-- Builds one text box's Possible Entries strip from its semantic lines ({ text, dim }) and the
-- values its headline samples, wraps them to the strip's width, caps them, and registers the
-- handle under `id` in state.rowRecords (merging with a staged setting's own record). `id` is
-- a staged setting's id or one of this mod's synthetic ids ("ucm:searchHint",
-- "ucm:presetNameHint"). Every editable text box gets a strip: the ladder in Entries.resolve
-- always yields at least the floor line.
local function addHintRow(state, id, semanticLines)
    if semanticLines == nil or #semanticLines == 0 then
        return
    end
    local hint = Config.ui.controls.hint
    local lines = Entries.fit(semanticLines, hint.maxWidth)
    local handle = Rows.createHintPanel(state.worldContext, hintCaption(),
        lines, function()
            if not state.torndown then
                Panel.rebuildHint(state, id)
            end
        end, I18n.t("hint_filter"), I18n.t("inferred_tip"))
    if handle == nil then
        return
    end
    Rows.setTooltip(handle.button, I18n.t("hint_toggle_tip"))
    if handle.filter ~= nil then
        -- Typed text lands through Controls.poll like every other box (and holds the Backspace
        -- gate while focused); a change only toggles block visibility, never rebuilds, so the
        -- box keeps focus keystroke to keystroke.
        Rows.setTooltip(handle.filter.widget, I18n.t("hint_filter_tip"))
        Controls.register(handle.filter, id .. ":filter", function(query)
            handle.setFilter(query)
        end)
    end
    addToListStrip(state, handle.root)
    local record = state.rowRecords[id] or {}
    record.hint = handle
    state.rowRecords[id] = record
end

-- Removes every widget in `destroyed` from `list`, by reference, in place. Pure list bookkeeping
-- (no widget method ever called), so it is exported and offline-testable with any comparable Lua
-- value standing in for a widget. Every Rows.reaffirm call site must run its return value through
-- this - a widget belongs in state.viewWidgets if and only if it is still live and tracked, and
-- Rows.reaffirm has no access to that list itself to keep the invariant on its own.
function Panel.pruneWidgets(list, destroyed)
    if destroyed == nil then
        return
    end
    for _, widget in ipairs(destroyed) do
        local index = nil
        for i, w in ipairs(list) do
            if w == widget then
                index = i
                break
            end
        end
        if index ~= nil then
            table.remove(list, index)
        end
    end
end

-- Pure list bookkeeping for the inline-dropdown fallback, exported for tests. Inserts `choices`
-- directly after `anchor`'s position in `list`, preserving every other entry's order.
function Panel.insertChoicesAfter(list, anchor, choices)
    local result = {}
    for _, item in ipairs(list) do
        result[#result + 1] = item
        if item == anchor then
            for _, choice in ipairs(choices) do
                result[#result + 1] = choice
            end
        end
    end
    return result
end

-- Pure list bookkeeping: `list` with every entry present in `items` removed, order preserved.
function Panel.removeAll(list, items)
    local drop = {}
    for _, item in ipairs(items) do drop[item] = true end
    local result = {}
    for _, item in ipairs(list) do
        if not drop[item] then result[#result + 1] = item end
    end
    return result
end

-- Polls the registered combo/text controls while a page is open. Guarded for the offline suite,
-- where ExecuteInGameThreadWithDelay does not exist: startPolling/stopPolling are then no-ops.
function Panel.startPolling(state)
    if ExecuteInGameThreadWithDelay == nil then
        return
    end
    if state.polling then
        return
    end
    state.polling = true
    -- The Backspace gate runs on its own, much faster clock. Reading values, measuring buttons
    -- and copying fonts are all fine at 250 ms, but the gate is racing a keypress: the close
    -- action fires on key release, so every millisecond between clicking into a box and the gate
    -- closing is a Backspace that escapes. Three boolean reads per box is all this costs.
    local function gateTick()
        if state.torndown or not state.polling then
            return
        end
        pcall(Controls.updateTypingGate)
        -- Same fast clock: a player who puts the pad down and reaches for the mouse gets their
        -- text boxes back without waiting on the slower control poll.
        pcall(Controls.applyInputMode)
        ExecuteInGameThreadWithDelay(Config.ui.controls.focusPollMs, gateTick)
    end
    ExecuteInGameThreadWithDelay(Config.ui.controls.focusPollMs, gateTick)

    local function tick()
        if state.torndown or not state.polling then
            return
        end
        pcall(Controls.poll)
        -- One line the first time the input type can be read, so a build where the lookup never
        -- resolves is distinguishable from a player on a keyboard.
        pcall(Gamepad.logOnce)
        -- A page is built for ONE device: a controller gets a file header with buttons and no
        -- text box, a mouse gets the clickable row and the path box. Changing device therefore
        -- has to rebuild whatever page is open, not just the next one entered. Only the home
        -- view came back correctly before, because leaving a mod page and returning rebuilt it
        -- (seen 2026-09-07). The reading is already sticky, so this cannot chatter.
        local pad = Gamepad.isActive()
        if state.builtForGamepad == nil then
            state.builtForGamepad = pad
        elseif pad ~= state.builtForGamepad then
            state.builtForGamepad = pad
            pcall(Panel.refreshView, state)
        end
        -- Values change through the controls, so this is the one place that learns a scope just
        -- became dirty (or clean again) without the page being rebuilt.
        pcall(Panel.refreshPendingRows, state)
        -- Text built before the first list row had no font to copy; catch those up.
        pcall(Rows.applyPendingFonts)
        ExecuteInGameThreadWithDelay(Config.ui.controls.pollIntervalMs, tick)
    end
    ExecuteInGameThreadWithDelay(Config.ui.controls.pollIntervalMs, tick)
end

function Panel.stopPolling(state)
    state.polling = false
    Controls.clear()
end

-- Builds into `list` (a VerticalBox). Returns panelState.
function Panel.build(worldContext, list)
    local model = Scanner.cachedModel()
    if model ~= nil then
        Scanner.refresh(model, function(line) log.info("refresh: " .. line) end)
    else
        local err
        model, err = Scanner.scan(function(line) log.info("scan: " .. line) end)
        if model == nil then
            log.error("scan failed: " .. tostring(err))
            return nil
        end
        model.managedModsDir = Scanner.managedModsDirectory()
        Scanner.setCachedModel(model)
    end
    Staging.begin(model)

    pcall(I18n.refresh)
    Present.decorate(model, model.managedModsDir)

    local state = {
        worldContext = worldContext,
        list = list,
        model = model,
        view = "home",
        selectedIndex = nil,
        viewWidgets = {},
        rowRecords = {},
        pendingRows = {},
        modRowWidgets = {},
        searchQuery = nil,
        presetName = "",
        torndown = false,
        advancedMode = Store.loadOptions().advancedMode,
    }
    Panel.showHome(state)
    Panel.startPolling(state)
    return state
end

-- Settings a mod shows right now: every entry, or only the non-advanced ones.
function Panel.visibleCount(mod, advancedMode)
    local count = 0
    for _, file in ipairs(mod.files) do
        for _, entry in ipairs(file.entries) do
            if (advancedMode or not entry.advanced) and not entry.hidden then
                count = count + 1
            end
        end
    end
    return count
end

-- The search filter: mods whose display name (falling back to name) contains `query` as a
-- substring, case-insensitively, after trimming leading/trailing whitespace. An empty or nil
-- query matches everything. Pure: touches no widget, so it is directly fixture-testable.
function Panel.filterMods(ordered, query)
    local trimmed = tostring(query or ""):match("^%s*(.-)%s*$"):lower()
    if trimmed == "" then
        return ordered
    end
    local result = {}
    for _, mod in ipairs(ordered) do
        if (mod.displayName or mod.name):lower():find(trimmed, 1, true) ~= nil then
            result[#result + 1] = mod
        end
    end
    return result
end

-- The mods actually shown on the home list, in the order they are shown: alphabetical by
-- display name (case-insensitive), with any mod that has zero visible settings under the
-- current Advanced Mode setting left out entirely, then narrowed by the search box
-- (state.searchQuery). Pure: touches no widget, so showHome, showMod and stepMod can all index
-- into the same list this returns.
function Panel.orderedMods(state)
    local ordered = {}
    for _, mod in ipairs(state.model.mods) do
        if Panel.visibleCount(mod, state.advancedMode) > 0 then
            ordered[#ordered + 1] = mod
        end
    end
    table.sort(ordered, function(a, b)
        return (a.displayName or a.name):lower() < (b.displayName or b.name):lower()
    end)
    return Panel.filterMods(ordered, state.searchQuery)
end

-- The index of `mod` inside `ordered` (by table identity), or nil when it is not in that list -
-- the case a mod that was only advanced-only-visible falls out of at the moment Advanced Mode is
-- switched off. Pure: touches no widget, exported so the re-find is directly testable offline.
function Panel.indexOfMod(ordered, mod)
    if mod == nil then
        return nil
    end
    for index, candidate in ipairs(ordered) do
        if candidate == mod then
            return index
        end
    end
    return nil
end

-- Corrected 2026-09-01: the mod page branch used to reuse the pre-toggle numeric
-- state.selectedIndex straight into the re-sorted/re-filtered list Advanced Mode produces,
-- which can point at the wrong mod (or one that just left the list). The mod itself is captured
-- by identity before the toggle, from the OLD ordering, and re-found in the NEW ordering by
-- Panel.indexOfMod; if it is no longer listed (advanced-only and Advanced Mode just turned
-- off), the view falls back to the home list instead of showing a wrong mod.
local function setAdvancedMode(state, isOn)
    if state.torndown or state.advancedMode == isOn then
        return
    end
    local selectedMod = nil
    if state.view == "mod" then
        selectedMod = Panel.orderedMods(state)[state.selectedIndex]
    end
    state.advancedMode = isOn
    local ok, err = Store.saveOptions({ advancedMode = isOn })
    if not ok then
        log.warn("could not save options: " .. tostring(err))
    end
    if state.view == "home" then
        Panel.showHome(state)
        return
    end
    local newIndex = Panel.indexOfMod(Panel.orderedMods(state), selectedMod)
    if newIndex == nil then
        Panel.showHome(state)
    else
        Panel.showMod(state, newIndex)
    end
end

-- Once per session: whether the search box built on this run, or the home view fell back to
-- showing every mod unfiltered because the control could not be built.
local searchUnavailableLogged = false
local function logSearchUnavailableOnce()
    if searchUnavailableLogged then
        return
    end
    searchUnavailableLogged = true
    log.info("search box unavailable on this build")
end

-- Rebuilds only the mod-row section of the home view (the clickable mod buttons, or the
-- "No mods match" line when the search box narrows the list to nothing). Never touches the
-- header rows or the search box itself: a keystroke in the search box re-filters through this,
-- not through Panel.showHome, so the box the player is typing in is never destroyed and never
-- loses focus. state.modRowWidgets tracks exactly the widgets this function owns so the next
-- call can remove precisely those and nothing else.
function Panel.renderModRows(state)
    if state.torndown or state.view ~= "home" then
        return
    end
    for _, widget in ipairs(state.modRowWidgets) do
        Rows.destroy(widget, false)
    end
    state.viewWidgets = Panel.removeAll(state.viewWidgets, state.modRowWidgets)
    state.modRowWidgets = {}

    local mods = Panel.orderedMods(state)
    if #mods == 0 then
        local noMatch = Rows.createSection(state.worldContext, I18n.t("no_mods_match"), "muted")
        addToList(state, noMatch, true)
        state.modRowWidgets[#state.modRowWidgets + 1] = noMatch
        return
    end
    for index, mod in ipairs(mods) do
        local modIndex = index
        local count = Panel.visibleCount(mod, state.advancedMode)
        local caption = mod.displayName or mod.name
        local modRow = Rows.createRowButton(state.worldContext, caption, function()
            if not state.torndown then
                Panel.showMod(state, modIndex)
            end
        end, { note = I18n.t(count == 1 and "settings_one" or "settings_many", { count = count }) })
        -- No tooltip: "Open this mod's settings" on all sixty rows says nothing the row does
        -- not already say.
        addToList(state, modRow, false)
        state.modRowWidgets[#state.modRowWidgets + 1] = modRow
    end
end

-- Requesting support for settings this mod could not describe.
--
-- One line wherever the player is, opening a page of its own the way Presets does. The page is
-- ordered the way the job is:
--
--   how many are missing, and which mods are included
--   Compile the List          writes the file, replacing any previous one, and CLEARS the link,
--                             because a link points at a list that no longer exists
--   Path to the List          shown once a list exists, outside either uploading option
--   Catbox.moe Link           shown once one exists, outside either uploading option
--   Manual Uploading          instructions, on its own page
--   Automated Uploading       one click: upload, and the LINK goes to the clipboard
--
-- The two uploading options appear only after a list has been compiled, because until then there
-- is nothing to upload. The link persists so it can be copied again, and is dropped when the list
-- is recompiled or when the SETTINGS THAT ARE MISSING change. Deliberately not when the player's
-- selection changes: the fingerprint is taken over everything missing, never over the filtered
-- subset, so toggling a mod cannot make a live link disappear (review, 2026-09-06).
local uploadInFlight = false

local function requestMods(state)
    local all = Requests.collect(state.model)
    local options = Store.loadOptions()
    local excluded = {}
    for name in tostring(options.requestExcluded or ""):gmatch("[^,]+") do
        excluded[name] = true
    end
    local includeAll = options.requestAllMods ~= false
    return all, Requests.filter(all, includeAll, excluded), includeAll, excluded
end

local function saveSelection(includeAll, excluded)
    local names = {}
    for name in pairs(excluded) do
        names[#names + 1] = name
    end
    table.sort(names)
    local options = Store.loadOptions()
    options.requestAllMods = includeAll
    options.requestExcluded = table.concat(names, ",")
    Store.saveOptions(options)
end

-- What is on disk for the settings that are CURRENTLY missing, or an empty record. A record whose
-- fingerprint no longer matches describes settings that have since changed, so it is dropped from
-- disk as well as from the page rather than lingering with a live link to a stale list.
local function requestRecord(fingerprint)
    local stored = Store.loadRequestRecord()
    if stored ~= nil and stored.fingerprint == fingerprint then
        return stored
    end
    if stored ~= nil then
        Store.clearRequestRecord()
    end
    return { fingerprint = fingerprint }
end

-- The one line, on whatever page the player is already looking at. It counts everything missing
-- on the install, which is what the page it opens also counts before any selection is applied.
local function addRequestLine(state, modIndex)
    -- On a MOD's page the count is that mod's own. It was the whole install's, so a page could
    -- announce a missing description for a setting belonging to some other mod entirely, and the
    -- player had no way to tell which (2026-09-07: AntiPhat's page reported a gap that was
    -- Alkeari Logging's). The home page still counts everything, which is what it is for.
    local onlyMod = nil
    if modIndex ~= nil and state.model ~= nil and state.model.mods ~= nil then
        onlyMod = state.model.mods[modIndex]
    end
    local count = Requests.count(Requests.collect(state.model, onlyMod))
    if count == 0 then
        return
    end
    local row = Rows.createRowButton(state.worldContext, I18n.t("request_support"), function()
        if not state.torndown then
            state.requestReturn = modIndex ~= nil and { kind = "mod", index = modIndex }
                or { kind = "home" }
            Panel.showRequest(state, nil)
        end
    end, { trailingIcon = (Config.ui.theme.icon or {}).angleRight,
        note = I18n.t(count == 1 and "request_note_one" or "request_note_many",
            { count = count }) })
    Rows.setTooltip(row, I18n.t("request_support_tip"))
    addToList(state, row, false)
end

-- The Request Support page's content, top to bottom, as a pure list of
-- { kind = "title"|"note"|"toggle"|"button"|"path", ... }. Touches no widget, so the page's shape
-- is checked in the offline suite the way presetPageModel is.
function Panel.requestPageModel(selected, all, includeAll, excluded, record, canUpload, message,
                                busy)
    local rows = {}
    local count = Requests.count(selected)
    local total = Requests.count(all)
    -- Nothing selected is not "0 settings still lack": that line would be false as well as
    -- forbidden. Say what is actually true and offer nothing to compile (review, 2026-09-06).
    if count == 0 then
        rows[#rows + 1] = { kind = "title", text = I18n.t("request_none_selected") }
    elseif count < total then
        rows[#rows + 1] = { kind = "title",
            text = I18n.t("request_note_selected", { count = count, total = total }) }
    else
        rows[#rows + 1] = { kind = "title",
            text = I18n.t(count == 1 and "request_note_one" or "request_note_many",
                { count = count }) }
    end
    if message ~= nil and message ~= "" then
        rows[#rows + 1] = { kind = "title", text = message }
    end
    rows[#rows + 1] = { kind = "toggle", action = "all", text = I18n.t("request_include_all"),
        on = includeAll }
    if not includeAll then
        -- One line per mod that actually has something missing, so a player can leave any of them
        -- out. Listing a mod with nothing missing would be a control that does nothing.
        for _, mod in ipairs(all) do
            rows[#rows + 1] = { kind = "toggle", action = "mod", key = mod.name,
                text = mod.displayName or mod.name, on = not excluded[mod.name],
                note = I18n.t(#mod.settings == 1 and "request_mod_note_one"
                    or "request_mod_note_many", { count = #mod.settings }) }
        end
    end
    if count > 0 then
        rows[#rows + 1] = { kind = "button", action = "compile",
            text = I18n.t("request_compile") }
    end
    -- The path belongs to the list itself, so it sits above either uploading option.
    if record.path ~= nil and record.path ~= "" then
        rows[#rows + 1] = { kind = "path", text = I18n.t("request_path_label"),
            value = record.path, tip = "request_path_tip" }
    end
    -- Nothing to upload until something has been compiled.
    if record.path ~= nil and record.path ~= "" then
        rows[#rows + 1] = { kind = "button", action = "manual", text = I18n.t("request_manual") }
        -- The disclosure sits ABOVE the automated action, always, in lines short enough to
        -- render: the host, that the link is public, and what the file does and does not
        -- hold. A rebuild of this page once dropped these, which left the automatic upload
        -- with no disclosure at all (caught 2026-09-06).
        rows[#rows + 1] = { kind = "note", text = I18n.t("request_upload_warning_where") }
        rows[#rows + 1] = { kind = "note", text = I18n.t("request_upload_warning_what") }
        if busy then
            rows[#rows + 1] = { kind = "title", text = I18n.t("request_uploading") }
        elseif canUpload then
            rows[#rows + 1] = { kind = "button", action = "automatic",
                text = I18n.t("request_automatic") }
        else
            -- Never a missing row with no reason: curl is what this needs and it is absent.
            rows[#rows + 1] = { kind = "note", text = I18n.t("request_automatic_unavailable") }
        end
        -- Directly under the button that produces it, which is where a player looks for it.
        -- Above, beside the path, it read as another property of the file.
        if record.url ~= nil and record.url ~= "" then
            rows[#rows + 1] = { kind = "path", text = I18n.t("request_link_label"),
                value = record.url, tip = "request_link_tip" }
        end
    end
    return rows
end

-- The Manual Uploading page: what to do, in order, with the address of each place it names.
function Panel.manualPageModel(record)
    local rows = {}
    for _, key in ipairs({ "manual_step_1", "manual_step_2", "manual_step_3",
        "manual_step_4" }) do
        rows[#rows + 1] = { kind = "title", text = I18n.t(key) }
    end
    if record.path ~= nil and record.path ~= "" then
        rows[#rows + 1] = { kind = "path", text = I18n.t("request_path_label"),
            value = record.path, tip = "request_path_tip" }
    end
    -- Between the path and the host, because that is the order the job happens in: find the
    -- file, then open the page to drop it on.
    if record.path ~= nil and record.path ~= "" then
        rows[#rows + 1] = { kind = "button", action = "folder",
            text = I18n.t("manual_open_folder") }
    end
    rows[#rows + 1] = { kind = "button", action = "host", text = I18n.t("manual_open_host") }
    for _, forum in ipairs(Config.requestForums or {}) do
        rows[#rows + 1] = { kind = "button", action = "forum", key = forum.key,
            text = I18n.t(forum.labelKey) }
    end
    -- An address this page could not open. Promised by forum_open_failed, so it has to exist.
    if record.forumUrl ~= nil and record.forumUrl ~= "" then
        rows[#rows + 1] = { kind = "path", text = I18n.t("forum_label"),
            value = record.forumUrl, tip = "forum_tip" }
    end
    return rows
end

-- Writes the list, replacing whatever was there. The link goes with it: it points at a file that
-- no longer describes what this one does.
local function compileRequest(record, selected, everyMod)
    if #selected == 0 then
        return false, I18n.t("request_none_selected")
    end
    local path, err = Store.saveRequest(Requests.fileName(everyMod),
        Requests.render(selected, Config.version))
    if path == nil then
        return false, tostring(err)
    end
    record.path, record.count, record.url = path, Requests.count(selected), nil
    Store.saveRequestRecord(record)
    return true
end

local function addBackRow(state, label, onBack)
    local row = Rows.createRowButton(state.worldContext, label, function()
        if not state.torndown then
            onBack()
        end
    end, { leadingIcon = (Config.ui.theme.icon or {}).angleLeft })
    Rows.setTooltip(row, I18n.t("back_tip"))
    addToList(state, row, false)
end

local function addPathRow(state, row)
    local frame = Rows.createPathEntry(state.worldContext, row.text, row.value,
        { caption = I18n.t("copy_label"), copiedCaption = I18n.t("copied_label"),
            tooltip = I18n.t("copy_path_tip") })
    if frame ~= nil then
        Rows.setTooltip(frame, I18n.t(row.tip))
        addToList(state, frame, false)
    else
        addToList(state, Rows.createSection(state.worldContext, row.value), true)
    end
end

-- Opens `url`, or falls back to the clipboard and says so: a browser that will not open is not a
-- dead end when the address is put on the page as well.
local function openOrCopy(record, url, again)
    if Browser.open(url) then
        return
    end
    Clipboard.copy(url)
    record.forumUrl = url
    again(I18n.t("forum_open_failed"))
end

function Panel.showManual(state, message)
    if state.torndown then
        return
    end
    clearView(state, false)
    state.view = "request-manual"
    state.selectedIndex = nil
    addBackRow(state, I18n.t("back_request"), function() Panel.showRequest(state, nil) end)
    addToList(state, Rows.createSection(state.worldContext, I18n.t("request_manual"), "title"),
        true)
    local all = Requests.collect(state.model)
    local record = requestRecord(Requests.fingerprint(all))
    local again = function(text) Panel.showManual(state, text) end
    if message ~= nil and message ~= "" then
        addToList(state, Rows.createSection(state.worldContext, message, "muted"), true)
    end
    for _, row in ipairs(Panel.manualPageModel(record)) do
        if row.kind == "title" then
            addToList(state, Rows.createHeaderLine(state.worldContext, row.text), true)
        elseif row.kind == "path" then
            addPathRow(state, row)
        elseif row.kind == "button" then
            local action, key = row.action, row.key
            local button = Rows.createRowButton(state.worldContext, row.text, function()
                if state.torndown then
                    return
                end
                if action == "folder" then
                    if not Browser.openFolder(record.path) then
                        Clipboard.copy(record.path)
                        again(I18n.t("manual_folder_failed"))
                    end
                elseif action == "host" then
                    openOrCopy(record, Config.upload.hostPage, again)
                else
                    for _, forum in ipairs(Config.requestForums or {}) do
                        if forum.key == key then
                            openOrCopy(record, forum.url, again)
                        end
                    end
                end
            end, { trailingIcon = (Config.ui.theme.icon or {}).angleRight })
            local manualTips = { folder = "manual_open_folder_tip",
                host = "manual_open_host_tip", forum = "forum_tip" }
            Rows.setTooltip(button, I18n.t(manualTips[action] or "forum_tip"))
            addToList(state, button, false)
        end
    end
    Panel.armFocus(state)
end

function Panel.showRequest(state, message)
    if state.torndown then
        return
    end
    clearView(state, false)
    state.view = "request"
    state.selectedIndex = nil
    local returnTo = state.requestReturn or { kind = "home" }
    addBackRow(state, I18n.t(returnTo.kind == "mod" and "back_mod" or "back_all_mods"),
        function()
            if returnTo.kind == "mod" then
                Panel.showMod(state, returnTo.index)
            else
                Panel.showHome(state)
            end
        end)
    addToList(state, Rows.createSection(state.worldContext, I18n.t("request_support"), "title"),
        true)

    local all, selected, includeAll, excluded = requestMods(state)
    if Requests.count(all) == 0 then
        addToList(state, Rows.createSection(state.worldContext, I18n.t("request_none"), "muted"),
            true)
        return
    end
    -- Over EVERYTHING missing, never the selection: a live link must not vanish because a mod
    -- was toggled off (review, 2026-09-06).
    local record = requestRecord(Requests.fingerprint(all))
    local again = function(text) Panel.showRequest(state, text) end

    for _, row in ipairs(Panel.requestPageModel(selected, all, includeAll, excluded, record,
        Upload.available(), message, uploadInFlight)) do
        if row.kind == "title" then
            addToList(state, Rows.createSection(state.worldContext, row.text, "muted"), true)
        elseif row.kind == "note" then
            addToList(state, Rows.createHeaderLine(state.worldContext, row.text), true)
        elseif row.kind == "path" then
            addPathRow(state, row)
        elseif row.kind == "toggle" then
            local action, key = row.action, row.key
            local toggle = Rows.createOptionSwitch(state.worldContext, row.text, row.on,
                function(isOn)
                    if state.torndown then
                        return
                    end
                    if action == "all" then
                        saveSelection(isOn, excluded)
                    else
                        excluded[key] = (not isOn) or nil
                        saveSelection(includeAll, excluded)
                    end
                    again(nil)
                end)
            Rows.setTooltip(toggle, I18n.t(action == "all" and "request_include_all_tip"
                or "request_include_mod_tip"))
            addToList(state, toggle, false)
        elseif row.kind == "button" then
            local action = row.action
            local button = Rows.createRowButton(state.worldContext, row.text, function()
                if state.torndown or uploadInFlight then
                    return
                end
                if action == "compile" then
                    local ok, err = compileRequest(record, selected, includeAll)
                    again(ok and I18n.t("request_compiled")
                        or I18n.t("request_failed", { error = err }))
                elseif action == "manual" then
                    Panel.showManual(state, nil)
                elseif action == "automatic" then
                    -- The upload blocks for as long as the host takes, so the page is repainted
                    -- saying so BEFORE it starts; without this the game simply stops responding
                    -- for up to the timeout with nothing on screen (review, 2026-09-06).
                    uploadInFlight = true
                    again(nil)
                    local finish = function()
                        local url, err = Upload.publish(record.path)
                        uploadInFlight = false
                        if state.torndown then
                            return
                        end
                        if url == nil then
                            again(I18n.t("upload_failed", { error = tostring(err) }))
                        else
                            local unchanged = record.url == url
                            record.url = url
                            Store.saveRequestRecord(record)
                            local copied = Clipboard.copy(url)
                            again(I18n.t(not copied and "request_copy_unavailable"
                                or unchanged and "request_link_same"
                                or "request_link_copied"))
                        end
                    end
                    if ExecuteInGameThreadWithDelay ~= nil then
                        ExecuteInGameThreadWithDelay(50, finish)
                    else
                        finish()
                    end
                end
            end, { trailingIcon = (Config.ui.theme.icon or {}).angleRight })
            local tips = { compile = "request_compile_tip", manual = "request_manual_tip",
                automatic = "request_automatic_tip" }
            Rows.setTooltip(button, I18n.t(tips[action] or "request_support_tip"))
            addToList(state, button, false)
        end
    end
    Panel.armFocus(state)
end

-- This mod's own on-screen keyboard, as a PAGE rather than a floating overlay. A page is made of
-- the same rows every other page is, so it inherits what already works: the controller focus that
-- is armed after every build, the screen's own scrolling, and buttons that are CommonUI and
-- therefore reachable with a stick. An overlay would have had to solve focus, z-order and
-- navigation from nothing, and Palworld ships no keyboard to borrow.
--
-- `target` is { label, value, view, index } plus EITHER `id` (a setting, staged on Save) or
-- `onCommit` (a function handed the typed text, for the search box and the preset name, which are
-- not settings at all). Nothing is written until Save, so backing out leaves things as they were.
function Panel.showKeyboard(state, target)
    if state.torndown or target == nil then
        return
    end
    clearView(state, false)
    state.view = "keyboard"
    state.keyboard = { id = target.id, commit = target.onCommit, label = target.label,
        back = target, buffer = Rows.displayString(target.value), shift = false }
    local board = state.keyboard

    local backRow = Rows.createRowButton(state.worldContext, I18n.t("kb_cancel"), function()
        if not state.torndown then
            Panel.leaveKeyboard(state)
        end
    end, { leadingIcon = (Config.ui.theme.icon or {}).angleLeft })
    Rows.setTooltip(backRow, I18n.t("kb_cancel_tip"))
    addToList(state, backRow, false)
    addToList(state, Rows.createSection(state.worldContext, target.label, "title"), true)

    -- The value as it stands, repainted on every key rather than rebuilt: rebuilding the page
    -- would destroy the key the player is standing on and throw the focus away with it.
    board.preview = Rows.createSection(state.worldContext, Panel.keyboardPreview(board), "muted")
    addToList(state, board.preview, true)

    local function keyAction(character)
        return { caption = character, tooltip = I18n.t("kb_key_tip"), variant = "secondary",
            onClick = function()
                if state.torndown or state.view ~= "keyboard" then
                    return
                end
                board.buffer = board.buffer .. character
                Panel.repaintKeyboard(state)
            end }
    end

    for _, line in ipairs(Config.ui.controls.keyboard.rows) do
        local actions = {}
        for _, code in utf8.codes(line.keys) do
            local character = utf8.char(code)
            if board.shift then
                character = character:upper()
            end
            actions[#actions + 1] = keyAction(character)
        end
        addToList(state, Rows.createActionRow(state.worldContext, "", actions,
            { packLeft = true, indent = line.indent }), false)
    end

    addToList(state, Rows.createActionRow(state.worldContext, "", {
        { caption = I18n.t("kb_shift"), tooltip = I18n.t("kb_shift_tip"), variant = "secondary",
            onClick = function()
                if not state.torndown then
                    board.shift = not board.shift
                    Panel.showKeyboard(state, target)
                end
            end },
        { caption = I18n.t("kb_space"), tooltip = I18n.t("kb_space_tip"), variant = "secondary",
            onClick = function()
                if not state.torndown then
                    board.buffer = board.buffer .. " "
                    Panel.repaintKeyboard(state)
                end
            end },
        { caption = I18n.t("kb_delete"), tooltip = I18n.t("kb_delete_tip"), variant = "secondary",
            onClick = function()
                if not state.torndown then
                    board.buffer = Panel.dropLastCharacter(board.buffer)
                    Panel.repaintKeyboard(state)
                end
            end },
        { caption = I18n.t("kb_clear"), tooltip = I18n.t("kb_clear_tip"), variant = "secondary",
            onClick = function()
                if not state.torndown then
                    board.buffer = ""
                    Panel.repaintKeyboard(state)
                end
            end },
        { caption = I18n.t("kb_save"), tooltip = I18n.t("kb_save_tip"), variant = "primary",
            onClick = function()
                if state.torndown then
                    return
                end
                if board.commit ~= nil then
                    pcall(board.commit, board.buffer)
                elseif board.id ~= nil then
                    Staging.stage(board.id, Rows.parseDisplayString(board.buffer))
                end
                Panel.leaveKeyboard(state)
            end },
    }, { packLeft = true, indent = 0 }), false)
    Panel.armFocus(state)
end

-- The preview line: the value being typed, or a word saying it is empty, never a blank row the
-- player cannot tell apart from a broken one.
-- A row that opens the keyboard for something that is not a setting: the search box and the
-- preset name. On a mouse these are text boxes and stay text boxes; a controller cannot type into
-- one, so it gets a row that opens the keyboard instead.
function Panel.typedValueRow(state, label, value, tooltip, onCommit)
    local frame = Rows.createRowButton(state.worldContext, label, function()
        if not state.torndown then
            Panel.showKeyboard(state, { label = label, value = value, onCommit = onCommit,
                view = state.view, index = state.selectedIndex })
        end
    end, { note = Rows.displayString(value), trailingIcon = (Config.ui.theme.icon or {}).angleRight })
    if frame ~= nil then
        Rows.setTooltip(frame, tooltip)
        addToList(state, frame, false)
    end
    return frame
end

function Panel.keyboardPreview(board)
    local shown = board.buffer
    if shown == "" then
        return I18n.t("kb_empty")
    end
    local limit = Config.ui.controls.keyboard.maxPreview
    if Rows.labelWidth(shown) > limit * 10 then
        shown = Rows.truncatePathToWidth(shown, limit * 10)
    end
    return shown
end

function Panel.repaintKeyboard(state)
    local board = state.keyboard
    if board == nil or board.preview == nil then
        return
    end
    Rows.setSectionText(board.preview, Panel.keyboardPreview(board))
end

-- Drops one CHARACTER, not one byte: a byte would cut a multi-byte glyph in half and leave the
-- value invalid UTF-8.
function Panel.dropLastCharacter(text)
    text = tostring(text or "")
    if text == "" then
        return ""
    end
    local ok, offset = pcall(function() return utf8.offset(text, -1) end)
    if not ok or offset == nil then
        return text:sub(1, #text - 1)
    end
    return text:sub(1, offset - 1)
end

function Panel.leaveKeyboard(state)
    local board = state.keyboard
    state.keyboard = nil
    local back = board ~= nil and board.back or nil
    if back ~= nil and back.view == "mod" and back.index ~= nil then
        Panel.showMod(state, back.index)
    else
        Panel.showHome(state)
    end
end

function Panel.showHome(state)
    if state.torndown then
        return
    end
    clearView(state, false)
    state.view = "home"
    state.selectedIndex = nil
    state.modRowWidgets = {}

    if #state.model.mods == 0 then
        addToList(state, Rows.createSection(state.worldContext, I18n.t("no_configs"), "muted"), true)
        return
    end
    local homeNotice = Present.allReloadLive(state.model.mods) and "live_notice" or "mixed_notice"
    addToList(state, Rows.createHeaderLine(state.worldContext, I18n.t(homeNotice)), true)
    -- The whole-screen scope lives here, outside any one mod's page.
    addPendingRow(state, nil)
    local advancedRow = Rows.createOptionSwitch(state.worldContext, I18n.t("advanced_mode"),
        state.advancedMode, function(isOn) setAdvancedMode(state, isOn) end)
    Rows.setTooltip(advancedRow, I18n.t("advanced_mode_tip"))
    addToList(state, advancedRow, false)

    -- On a controller the search box is a row that opens the keyboard, because a pad cannot type
    -- into a text box. That is a deliberate shape, not a failure to build one, so it must not
    -- report the box as unavailable.
    local searchByKeyboard = Gamepad.isActive()
    local searchFrame, searchHandle = nil, nil
    if searchByKeyboard then
        Panel.typedValueRow(state, I18n.t("search"), state.searchQuery or "",
            I18n.t("search_tip"), function(text)
                state.searchQuery = text
                Panel.showHome(state)
            end)
    else
        searchFrame, searchHandle = Rows.createSearchEntry(state.worldContext, I18n.t("search"),
            state.searchQuery or "", I18n.t("search_placeholder"))
    end
    if searchFrame ~= nil then
        addToList(state, searchFrame, false)
        Rows.setTooltip(searchFrame, I18n.t("search_tip"))
        if searchHandle ~= nil then
            Controls.register(searchHandle, "ucm:search", function(v)
                state.searchQuery = v
                Panel.renderModRows(state)
            end)
        end
        -- No strip here: the mod list below IS the list of what the box matches, so a strip
        -- would repeat the page.
    elseif not searchByKeyboard then
        logSearchUnavailableOnce()
    end

    local presetsRow = Rows.createRowButton(state.worldContext, I18n.t("presets"), function()
        if not state.torndown then
            Panel.showPresets(state, nil)
        end
    end, { trailingIcon = (Config.ui.theme.icon or {}).angleRight })
    Rows.setTooltip(presetsRow, I18n.t("presets_tip"))
    addToList(state, presetsRow, false)

    addRequestLine(state, nil)

    Panel.renderModRows(state)
    Panel.armFocus(state)
end

-- The Presets page's content, top to bottom, as a pure list of
-- { kind = "title"|"entry"|"button"|"preset", text?, action?, name? }: the folder line, a
-- message line when one is given, the name box, the Save button, then one "preset" row per
-- existing preset name (already sorted by the caller; one row per preset, never one row per
-- action), or a "No presets yet" title when the list is empty. Touches
-- no widget, so Panel.showPresets and the offline suite can both build from the same shape.
function Panel.presetPageModel(names, message)
    local rows = {}
    rows[#rows + 1] = { kind = "path", text = I18n.t("presets_folder"), value = Store.presetsDirectory() }
    if message ~= nil then
        rows[#rows + 1] = { kind = "title", text = message }
    end
    rows[#rows + 1] = { kind = "entry", text = I18n.t("new_preset_name") }
    rows[#rows + 1] = { kind = "button", text = I18n.t("save_preset"), action = "save" }
    if #names == 0 then
        rows[#rows + 1] = { kind = "title", text = I18n.t("no_presets_yet") }
    else
        for _, name in ipairs(names) do
            rows[#rows + 1] = { kind = "preset", name = name }
        end
    end
    return rows
end

function Panel.handlePresetSave(state)
    -- The name box's onChange lands through Controls.poll, which runs on a timer (see
    -- Panel.startPolling); a click on this button can land up to one poll tick before the
    -- box's latest keystroke was read. Polling here first guarantees state.presetName reflects
    -- what the player actually typed before validation reads it.
    pcall(Controls.poll)
    local name = state.presetName
    if not Store.isValidPresetName(name) then
        Panel.showPresets(state, I18n.t("preset_invalid_name"))
        return
    end
    local records = Presets.capture(state.model)
    local ok, err = Store.savePreset(name, records)
    if ok then
        Panel.showPresets(state, I18n.t("preset_saved", { name = name }))
    else
        Panel.showPresets(state, I18n.t("preset_save_failed", { name = name, error = err }))
    end
end

-- Overwrite: identical write as Save, just against an existing preset's own name instead of the
-- name box's typed value - Store.savePreset always replaces whatever file already sits at that
-- name, so there is no separate "overwrite" write path to keep in sync with Save's.
function Panel.handlePresetOverwrite(state, name)
    local records = Presets.capture(state.model)
    local ok, err = Store.savePreset(name, records)
    if ok then
        Panel.showPresets(state, I18n.t("preset_saved", { name = name }))
    else
        Panel.showPresets(state, I18n.t("preset_save_failed", { name = name, error = err }))
    end
end

function Panel.handlePresetLoad(state, name)
    local records, err = Store.loadPreset(name)
    if records == nil then
        Panel.showPresets(state, I18n.t("preset_read_failed", { name = name, error = err }))
        return
    end
    local plan = Presets.plan(records, state.model)
    Presets.apply(plan)
    local summary = I18n.t("preset_loaded",
        { name = name, staged = #plan.stage, skipped = plan.skipped })
    log.info(summary)
    Panel.showPresets(state, summary)
end

function Panel.handlePresetDelete(state, name)
    local ok, err = Store.deletePreset(name)
    if ok then
        Panel.showPresets(state, I18n.t("preset_deleted", { name = name }))
    else
        Panel.showPresets(state, I18n.t("preset_delete_failed", { name = name, error = err }))
    end
end

-- Renders Panel.presetPageModel with the game's own widgets: a back row above the model, then
-- one row per model entry. The name box is a search-entry-style control (Rows.createSearchEntry)
-- registered as "ucm:presetName" whose onChange only stores state.presetName - it never rebuilds
-- the page, so a keystroke never loses focus. When the control cannot be built, its title-row
-- entry and the Save button are both skipped, per the model's own row order (entry always
-- precedes the save button).
function Panel.showPresets(state, message)
    if state.torndown then
        return
    end
    clearView(state, false)
    state.view = "presets"
    state.selectedIndex = nil

    local backRow = Rows.createRowButton(state.worldContext, I18n.t("back_all_mods"), function()
        if not state.torndown then
            Panel.showHome(state)
        end
    end, { leadingIcon = (Config.ui.theme.icon or {}).angleLeft })
    Rows.setTooltip(backRow, I18n.t("back_tip"))
    addToList(state, backRow, false)
    addToList(state, Rows.createSection(state.worldContext, I18n.t("presets"), "title"), true)
    local savedHeaderShown = false

    local names = {}
    local ok, listed = pcall(Store.listPresets)
    if ok and listed ~= nil then
        names = listed
    end

    local nameBoxBuilt = false
    for _, row in ipairs(Panel.presetPageModel(names, message)) do
        if row.kind == "path" then
            local frame = Rows.createPathEntry(state.worldContext, row.text, row.value,
                { caption = I18n.t("copy_label"), copiedCaption = I18n.t("copied_label"),
                    tooltip = I18n.t("copy_path_tip") })
            if frame ~= nil then
                Rows.setTooltip(frame, I18n.t("presets_folder_tip"))
                addToList(state, frame, false)
            else
                addToList(state, Rows.createSection(state.worldContext,
                    row.text .. ": " .. row.value), true)
            end
        elseif row.kind == "title" then
            addToList(state, Rows.createSection(state.worldContext, row.text, "muted"), true)
        elseif row.kind == "entry" and Gamepad.isActive() then
            -- A controller cannot type into the name box, so it opens the keyboard instead. The
            -- Save button below still needs to know a name was given, so nameBoxBuilt is set the
            -- same way.
            nameBoxBuilt = Panel.typedValueRow(state, row.text, state.presetName or "",
                I18n.t("preset_name_tip"), function(text)
                    state.presetName = text
                    Panel.showPresets(state, nil)
                end) ~= nil
        elseif row.kind == "entry" then
            local frame, handle = Rows.createSearchEntry(state.worldContext, row.text,
                state.presetName or "", I18n.t("preset_name_placeholder"))
            if frame ~= nil then
                addToList(state, frame, false)
                Rows.setTooltip(frame, I18n.t("preset_name_tip"))
                nameBoxBuilt = true
                if handle ~= nil then
                    Controls.register(handle, "ucm:presetName", function(v)
                        state.presetName = v
                    end)
                end
                -- No strip here either: the saved presets are listed on this same page, and
                -- the naming rule is the box's own tooltip.
            else
                addToList(state, Rows.createSection(state.worldContext,
                    I18n.t("preset_saving_unavailable")), true)
            end
        elseif row.action == "save" then
            if nameBoxBuilt then
                local button = Rows.createRowButton(state.worldContext, row.text, function()
                    if not state.torndown then
                        Panel.handlePresetSave(state)
                    end
                end)
                Rows.setTooltip(button, I18n.t("save_preset_tip"))
                addToList(state, button, false)
            end
        elseif row.kind == "preset" then
            local name = row.name
            local deleteArmed, deleteButton = false, nil
            if not savedHeaderShown then
                savedHeaderShown = true
                addToList(state, Rows.createSection(state.worldContext, I18n.t("saved_presets"), "title"), true)
            end
            local frame = Rows.createActionRow(state.worldContext, name, {
                { caption = I18n.t("preset_load_label"), tooltip = I18n.t("load_preset_tip"),
                    onClick = function()
                        if not state.torndown then Panel.handlePresetLoad(state, name) end
                    end },
                { caption = I18n.t("preset_overwrite_label"), tooltip = I18n.t("preset_overwrite_tip"),
                    onClick = function()
                        if not state.torndown then Panel.handlePresetOverwrite(state, name) end
                    end },
                -- Danger: amber, and a confirmation step (design system): the first click
                -- relabels the button, the second deletes. Leaving the page resets it.
                { caption = I18n.t("preset_delete_label"), tooltip = I18n.t("delete_preset_tip"),
                    variant = "danger",
                    -- The pill is sized for this too, so the armed caption fits the button it is
                    -- written into rather than spilling over the one beside it.
                    confirmCaption = I18n.t("preset_delete_confirm_label"),
                    attach = function(handle) deleteButton = handle end,
                    onClick = function()
                        if state.torndown then
                            return
                        end
                        if not deleteArmed then
                            deleteArmed = true
                            if deleteButton ~= nil then
                                deleteButton.setCaption(I18n.t("preset_delete_confirm_label"))
                            end
                            return
                        end
                        Panel.handlePresetDelete(state, name)
                    end },
            })
            if frame ~= nil then
                addToList(state, frame, false)
            else
                -- Fallback for a build where the embedded buttons could not be built at all:
                -- the old one-row-per-action shape, so the preset is never simply unreachable.
                local loadButton = Rows.createRowButton(state.worldContext,
                    I18n.t("load_preset", { name = name }), function()
                        if not state.torndown then Panel.handlePresetLoad(state, name) end
                    end)
                Rows.setTooltip(loadButton, I18n.t("load_preset_tip"))
                addToList(state, loadButton, false)
                local overwriteButton = Rows.createRowButton(state.worldContext,
                    I18n.t("preset_overwrite_label") .. " " .. name, function()
                        if not state.torndown then Panel.handlePresetOverwrite(state, name) end
                    end)
                Rows.setTooltip(overwriteButton, I18n.t("preset_overwrite_tip"))
                addToList(state, overwriteButton, false)
                local deleteButton = Rows.createRowButton(state.worldContext,
                    I18n.t("delete_preset", { name = name }), function()
                        if not state.torndown then Panel.handlePresetDelete(state, name) end
                    end)
                Rows.setTooltip(deleteButton, I18n.t("delete_preset_tip"))
                addToList(state, deleteButton, false)
            end
        end
    end
    Panel.armFocus(state)
end

-- Once per session: whether string rows are building as editable text entries on this run, or
-- falling back to the read-only line (no canvas field, or the text box class failed to build).
local textRowModeLogged = false
local function logTextRowModeOnce(mode)
    if textRowModeLogged then
        return
    end
    textRowModeLogged = true
    log.info("string rows: " .. (mode == "editable" and "editable text entry" or "read-only fallback"))
end

-- The accepted values of a text setting, when they are actually known and there are few enough to
-- pick from with a stick. Anything the ladder could not answer ends at the floor line, which is
-- prose rather than a value set, and is never offered as a list.
local function pickableValues(entry, file, mod)
    local resolved = Entries.resolve(entry, file, mod, Present.overrides.entries)
    if type(resolved) ~= "table" or resolved.source == "floor" then
        return nil
    end
    local values = resolved.values
    if type(values) ~= "table" then
        return nil
    end
    local limit = Config.ui.controls.pickListMax or 60
    if #values < 2 or #values > limit then
        return nil
    end
    for _, value in ipairs(values) do
        if type(value) ~= "string" and type(value) ~= "number" then
            return nil
        end
    end
    return values
end

local function buildEntryRow(state, mod, file, entry)
    local id = Staging.idFor(mod.name, file.rel, entry.key)
    local value = Staging.valueOf(id)
    local spec = RowSpec.classify(entry, file, mod)
    local label = entry.label
    if spec.kind == "keyCombo" then
        label = Present.labelFor(mod.name, entry.key, entry.strippedKey or entry.key, true,
            entry.schema and entry.schema.label or nil)
    end
    local built = nil

    if spec.kind == "switch" or spec.kind == "switch01" then
        local frame = Rows.createSwitch(state.worldContext, id, label, value,
            spec.kind == "switch01")
        if frame ~= nil then
            addToList(state, frame, false)
            state.rowRecords[id] = { frame = frame, rowKind = spec.kind }
            built = frame
        end
    elseif spec.kind == "slider" then
        local minValue, maxValue = spec.min, spec.max
        -- A staged edit can sit outside the derived range; the slider must hold it.
        if value < minValue then
            minValue = value
        end
        if value > maxValue then
            maxValue = value
        end
        local frame = Rows.createSlider(state.worldContext, id, label, value,
            minValue, maxValue, spec.step, spec.unit)
        if frame ~= nil then
            addToList(state, frame, false)
            state.rowRecords[id] = { frame = frame, rowKind = "slider",
                min = minValue, max = maxValue }
            built = frame
            -- The value is typed as well as dragged: a bar whose step resolves to 0 runs
            -- continuously and can never be nudged onto a round number. What is typed is pulled
            -- inside the bar's range and onto its grid before staging, so the number and the bar
            -- always agree; anything that is not a number restores the value that was already
            -- there rather than staging a guess.
            local handle = Rows.controlOf(frame)
            if handle ~= nil then
                -- Held until the player leaves the box: clamping per keystroke rewrote "5" into
                -- the range minimum before the "0" of "50" arrived.
                Controls.register(handle, id .. ":value", function(v)
                    local numeric = Rows.normalizeSliderValue(v, minValue, maxValue, spec.step)
                    if numeric == nil then
                        local current = Staging.valueOf(id)
                        handle.set(Rows.numberString(current ~= nil and current or value))
                        return
                    end
                    Staging.stage(id, numeric)
                    Rows.reaffirm(state.rowRecords[id], numeric)
                end, { commitOnBlur = true })
            end
        end
    elseif spec.kind == "enum" then
        local function rebuild()
            Panel.rebuildDropdown(state, id)
        end
        -- A dropdown always hands back the caption it displays; a numeric enum must be staged
        -- as the number it was parsed from, or the rewrite would quote it into a string.
        local function stageChoice(v)
            if spec.numeric then
                Staging.stage(id, tonumber(v) or v)
            else
                Staging.stage(id, v)
            end
        end
        -- The dropdown shows the author's own spelling of the current value ("3", not the "3.0"
        -- tostring gives a float), so it matches an option instead of adding a phantom one.
        local function displayOf(v)
            if spec.numeric then
                for _, choice in ipairs(spec.choices) do
                    if tonumber(choice) == tonumber(v) then
                        return choice
                    end
                end
            end
            return v
        end
        local shown = displayOf(value)
        local frame, mode = Rows.createDropdown(state.worldContext, id, label, spec.choices,
            shown, rebuild)
        if frame ~= nil then
            addToList(state, frame, false)
            if mode == "combo" then
                local handle = Rows.controlOf(frame)
                if handle ~= nil then
                    Controls.register(handle, id, stageChoice)
                end
                state.rowRecords[id] = { frame = frame, rowKind = "enum", mode = "combo" }
            else
                state.rowRecords[id] = { frame = frame, rowKind = "enum", caption = label,
                    choicesFn = function() return spec.choices end, stageChoice = stageChoice,
                    numeric = spec.numeric, displayOf = displayOf,
                    expanded = false, choiceWidgets = {}, mode = "inline" }
            end
            built = frame

            -- A dropdown lists its values but cannot say what any of them MEANS: it shows
            -- "smart_defender" and nothing else. Where the catalog gives those values notes
            -- ("pacifist_avenger (fights back only when attacked)") the row gets the same
            -- Possible Entries strip a text box does, which is the only place those notes can
            -- be read - the strip used to be built in the text branch alone, so every note
            -- written for a choice list was unreachable (found 2026-09-04, on the nine Passive
            -- Pals reaction profiles, which are the example of what a good note set looks like).
            --
            -- Only where they are ANNOTATED, though. A dropdown of bare values already shows
            -- everything the strip would repeat, and a mod like Passive Pals has 21 of them:
            -- a strip under every one would double the page to say nothing.
            addHintRow(state, id, Entries.annotatedLines(entry, file, mod, Present.overrides.entries))
        end
    elseif Gamepad.isActive() and pickableValues(entry, file, mod) ~= nil then
        -- A controller cannot type, so a text setting whose accepted values are actually KNOWN is
        -- offered as a list to pick from instead. The values are the same ones Possible Entries
        -- shows, so this invents nothing: it presents what the strip already says, in a shape a
        -- pad can use. A mouse keeps the text box; nothing here changes for it.
        local choices = pickableValues(entry, file, mod)
        local function rebuild()
            Panel.rebuildDropdown(state, id)
        end
        local frame = Rows.createDropdown(state.worldContext, id, label, choices,
            tostring(value), rebuild)
        if frame ~= nil then
            addToList(state, frame, false)
            state.rowRecords[id] = { frame = frame, rowKind = "enum", caption = label,
                choicesFn = function() return choices end,
                stageChoice = function(v) Staging.stage(id, v) end,
                numeric = false, displayOf = function(v) return v end,
                expanded = false, choiceWidgets = {}, mode = "inline" }
            built = frame
            addHintRow(state, id,
                Entries.annotatedLines(entry, file, mod, Present.overrides.entries))
        end
    elseif Gamepad.isActive() then
        -- Free-form text on a controller: the row opens this mod's own on-screen keyboard, because
        -- Palworld ships none and a pad has no other way to enter a value.
        local frame = Rows.createRowButton(state.worldContext, label, function()
            if not state.torndown then
                Panel.showKeyboard(state, { id = id, label = label,
                    value = Staging.valueOf(id), view = state.view,
                    index = state.selectedIndex })
            end
        end, { note = Rows.displayString(Staging.valueOf(id)),
            trailingIcon = (Config.ui.theme.icon or {}).angleRight })
        if frame ~= nil then
            addToList(state, frame, false)
            state.rowRecords[id] = { frame = frame, rowKind = "text", mode = "keyboard" }
            built = frame
            local resolved = Entries.resolve(entry, file, mod, Present.overrides.entries)
            addHintRow(state, id, Entries.lines(resolved))
        end
    else
        -- Free-form strings and hotkeys ("CTRL+N", "F7") alike: a hotkey is typed, never picked
        -- from a modifier-times-key list, which read as nonsense.
        local frame = Rows.createTextEntry(state.worldContext, id, label, value)
        if frame ~= nil then
            addToList(state, frame, false)
            local handle = Rows.controlOf(frame)
            if handle ~= nil then
                Controls.register(handle, id, function(v)
                    Staging.stage(id, Rows.parseDisplayString(v))
                end)
            end
            state.rowRecords[id] = { frame = frame, rowKind = "text", mode = "control" }
            logTextRowModeOnce("editable")
            built = frame

            -- Only what can be ENTERED (Entries.resolve's ladder, never a description), and
            -- every text box gets a strip: the ladder ends at the floor line, never at nothing.
            local resolved = Entries.resolve(entry, file, mod, Present.overrides.entries)
            addHintRow(state, id, Entries.lines(resolved))
        else
            local shown = tostring(value)
            if shown == "" then
                shown = I18n.t("empty_value")
            end
            local text = Rows.createText(state.worldContext, label .. " = " .. shown)
            addToList(state, text, true)
            logTextRowModeOnce("read-only")
            built = text
        end
    end

    Rows.setTooltip(built, entry.tooltip)
end

-- Toggles one inline-fallback dropdown row's expansion (combo-mode rows never call this: their
-- selection lands through Controls.poll, not a click). On expand: computes the row's current
-- choice set (record.choicesFn) and inserts one clickable choice row
-- per option directly under the closed row, via Widgets.insertAfter chained from the previous
-- choice so the whole block reads as subordinate to the row that opened it, mirroring the same
-- order into state.viewWidgets with Panel.insertChoicesAfter. On collapse (a choice picked, or
-- the closed row clicked again): Rows.reaffirm is the one place a dropdown row's widgets are
-- destroyed and its closed caption re-labeled, so Apply, Restore to Default, and an interactive
-- collapse can never re-label it differently; Rows.reaffirm hands back the widgets it destroyed
-- (it has no access to state.viewWidgets itself), and Panel.removeAll drops them here.
function Panel.rebuildDropdown(state, id)
    local record = state.rowRecords[id]
    if record == nil or record.mode == "combo" then
        return
    end
    if record.expanded then
        local shown = Staging.valueOf(id)
        if record.displayOf ~= nil then
            shown = record.displayOf(shown)
        end
        local destroyed = Rows.reaffirm(record, shown)
        state.viewWidgets = Panel.removeAll(state.viewWidgets, destroyed or {})
        return
    end
    record.expanded = true
    local currentValue = Staging.valueOf(id)
    local anchor = record.frame
    for _, choice in ipairs(record.choicesFn()) do
        local isCurrent
        if record.numeric then
            isCurrent = tonumber(currentValue) ~= nil and tonumber(currentValue) == tonumber(choice)
        else
            isCurrent = tostring(currentValue):lower() == choice:lower()
        end
        local widget = Rows.createDropdownChoice(state.worldContext, choice, isCurrent, function()
                local stage = record.stageChoice
                if stage ~= nil then
                    stage(choice)
                else
                    Staging.stage(id, choice)
                end
                Panel.rebuildDropdown(state, id)
            end)
        if widget ~= nil then
            Widgets.insertAfter(state.list, anchor, widget)
            state.viewWidgets = Panel.insertChoicesAfter(state.viewWidgets, anchor, { widget })
            record.choiceWidgets[#record.choiceWidgets + 1] = widget
            anchor = widget
        end
    end
end

-- Toggles one text box's Possible Entries strip. The lines live inside the strip from the
-- start (Rows.createHintPanel), so this flips their visibility and relabels the headline; the
-- rows beneath move down as the strip grows. On expand the strip is scrolled into view (an
-- unproven ScrollBox call, its own pcall, degrading to no scroll). Informative only, never a
-- selector.
function Panel.rebuildHint(state, id)
    local record = state.rowRecords[id]
    if record == nil or record.hint == nil then
        return
    end
    local expanded = not record.hint.expanded
    record.hint.setExpanded(expanded, nil)
    if expanded then
        pcall(function()
            state.list:GetParent():ScrollWidgetIntoView(record.hint.root, true, 0, 0)
        end)
    end
end

function Panel.showMod(state, index)
    if state.torndown then
        return
    end
    local mod = Panel.orderedMods(state)[index]
    if mod == nil then
        return
    end
    clearView(state, false)
    state.view = "mod"
    state.selectedIndex = index

    local backRow = Rows.createRowButton(state.worldContext, I18n.t("back_all_mods"), function()
        if not state.torndown then
            Panel.showHome(state)
        end
    end, { leadingIcon = (Config.ui.theme.icon or {}).angleLeft })
    Rows.setTooltip(backRow, I18n.t("back_tip"))
    addToList(state, backRow, false)
    addToList(state, Rows.createSection(state.worldContext, mod.displayName, "title"), true)
    -- Reloading into a world or server is the DEFAULT promise, because it is what a mod
    -- actually does most of the time; "restart the game" is only said where the catalog records
    -- that we know it. A mod that watches its own file keeps the stronger promise above both.
    local modNotice = "world_load_notice"
    if Present.reloadsLive(mod) then
        modNotice = "live_notice"
    elseif Present.requiresGameRestart(mod) then
        modNotice = "relaunch_notice"
    end
    addToList(state, Rows.createHeaderLine(state.worldContext, I18n.t(modNotice)), true)
    addPendingRow(state, mod.name)
    addRequestLine(state, index)

    local advancedTitleShown = false
    for _, file in ipairs(mod.files) do
        local isAdvanced = file.class == "advanced"
        if not isAdvanced or state.advancedMode then
            if isAdvanced and not advancedTitleShown then
                addToList(state, Rows.createSection(state.worldContext, I18n.t("advanced_section"), "title"), true)
                advancedTitleShown = true
            end
            -- The file's path is a clickable header that collapses and expands its settings
            -- (expanded by default), with a Copy button for the file's own full path. Everything
            -- built under it is collected so one click hides it all.
            local icons = Config.ui.theme.icon or {}
            local iconOut, section = {}, { expanded = true, widgets = {} }
            local toggleHandle, copyHandle = nil, nil
            local function toggleSection()
                if state.torndown then
                    return
                end
                section.expanded = not section.expanded
                local visibility = section.expanded and Config.ui.pageActiveVisibility
                    or Config.ui.pageInactiveVisibility
                for _, widget in ipairs(section.widgets) do
                    pcall(function() widget:SetVisibility(visibility) end)
                end
                if iconOut.widget ~= nil then
                    pcall(function()
                        iconOut.widget:SetRenderTransformAngle(section.expanded and icons.angleDown
                            or icons.angleRight)
                    end)
                end
                if toggleHandle ~= nil then
                    pcall(function()
                        toggleHandle.setCaption(I18n.t(section.expanded and "hide_label"
                            or "show_label"))
                    end)
                end
            end
            local header
            if Gamepad.isActive() then
                -- On a controller the header is an ACTION ROW: a Hide button and a Copy button,
                -- both of them widgets this mod places and a pad can already focus, press and see
                -- outlined. Three rounds of testing proved the row itself cannot be relied on for
                -- this - the press reaches the mod and the action runs, and the file still does
                -- not open (2026-09-07) - so the press is put on a button instead of being
                -- chased through the row. The path box is dropped here: a pad cannot select text
                -- out of it, and Copy still copies the whole path.
                local captions = { I18n.t("hide_label"), I18n.t("show_label") }
                local widest = Rows.labelWidth(captions[1]) >= Rows.labelWidth(captions[2])
                    and captions[1] or captions[2]
                header = Rows.createActionRow(state.worldContext, file.rel, {
                    { caption = I18n.t("hide_label"), confirmCaption = widest,
                        tooltip = I18n.t("file_header_tip"), variant = "secondary",
                        onClick = toggleSection,
                        attach = function(handle) toggleHandle = handle end },
                    { caption = I18n.t("copy_label"),
                        -- Sized for the longer of the two, so "Copied" fits the pill it lands in.
                        confirmCaption = I18n.t("copied_label"),
                        tooltip = I18n.t("copy_file_tip"), variant = "secondary",
                        attach = function(handle) copyHandle = handle end,
                        onClick = function()
                            -- The button has to SAY it copied. Without it a controller player has
                            -- no way to know the press did anything; the
                            -- mouse header has said so since 2026-09-06.
                            if file.path == nil or not Clipboard.copy(file.path)
                                or copyHandle == nil then
                                return
                            end
                            pcall(function()
                                copyHandle.setCaption(I18n.t("copied_label"))
                            end)
                            if type(ExecuteInGameThreadWithDelay) == "function" then
                                ExecuteInGameThreadWithDelay(Config.ui.controls.copiedRevertMs,
                                    function()
                                        if not state.torndown then
                                            pcall(function()
                                                copyHandle.setCaption(I18n.t("copy_label"))
                                            end)
                                        end
                                    end)
                            end
                        end },
                }, { trimFromLeft = true })
            else
                header = Rows.createRowButton(state.worldContext, file.rel, toggleSection,
                    { leadingIcon = icons.angleDown, iconOut = iconOut })
                Rows.setTooltip(header, I18n.t("file_header_tip"))
                -- The file's own full path, in a box on the header line, with a Copy button at
                -- its end.
                if file.path ~= nil then
                    Rows.addPathField(header, state.worldContext, file.rel, file.path,
                        { caption = I18n.t("copy_label"), copiedCaption = I18n.t("copied_label"),
                            tooltip = I18n.t("copy_file_tip") }, Config.ui.theme.rowIconInset)
                end
            end
            addToList(state, header, false)

            state.collect = section.widgets

            local currentGroup = nil
            for _, entry in ipairs(file.entries) do
                if not entry.hidden then
                    if entry.group ~= nil and entry.group ~= currentGroup then
                        currentGroup = entry.group
                        addToList(state, Rows.createSection(state.worldContext,
                            "  " .. Present.humanize(entry.group:gsub("%.", " "), false), "muted"), true)
                    end
                    buildEntryRow(state, mod, file, entry)
                end
            end
            state.collect = nil
        end
    end
    Panel.armFocus(state)
end

-- Q/E paging: steps between mods while a mod page is open, wrapping at either end.
function Panel.stepMod(state, delta)
    if state == nil or state.torndown or state.view ~= "mod" then
        return
    end
    if Controls.anyTextFocused() then
        return
    end
    local count = #Panel.orderedMods(state)
    if count < 2 then
        return
    end
    local newIndex = state.selectedIndex + delta
    if newIndex < 1 then
        newIndex = count
    elseif newIndex > count then
        newIndex = 1
    end
    Panel.showMod(state, newIndex)
end

-- Restore to Default stages each value's template (from a template sibling, if present and type-matching),
-- else the BASELINE: the value the config file held the first time this mod ever saw it (the closest
-- observable thing to the author's default). Falls back to the file's open-time value where neither exists.
function Panel.resetAll(state)
    local baselines = Store.loadBaselines()
    local templates = Staging.templateValues(state.model)
    Staging.resetAll(baselines, templates)
    if state == nil then
        return
    end
    for id, rowRecord in pairs(state.rowRecords) do
        Panel.pruneWidgets(state.viewWidgets, Rows.reaffirm(rowRecord, Staging.valueOf(id)))
    end
end

-- Discards every staged edit without committing. `state` may be nil: the apply prompt's "no" is
-- answered while the screen is already closing, and discarding is what matters then. When a panel
-- state is live, every row is reaffirmed back to its pre-discard value so a still-open text box
-- cannot keep showing text the player typed but declined to keep.
function Panel.discardAll(state, modName)
    Staging.discardAll(modName)
    if state == nil then
        return
    end
    for id, rowRecord in pairs(state.rowRecords) do
        Panel.pruneWidgets(state.viewWidgets, Rows.reaffirm(rowRecord, Staging.valueOf(id)))
    end
    Panel.refreshPendingRows(state)
end

-- Commits staged edits. `state` may be nil: the apply prompt is answered while the screen is
-- already closing, and committing is what matters then.
function Panel.applyAll(state, modName)
    local written, failed = Staging.applyAll(modName)
    if written > 0 or failed > 0 then
        log.info("apply: " .. written .. " file(s) written, " .. failed .. " failed")
    end
    if state == nil then
        return
    end
    for id, rowRecord in pairs(state.rowRecords) do
        Panel.pruneWidgets(state.viewWidgets, Rows.reaffirm(rowRecord, Staging.valueOf(id)))
    end
    Panel.refreshPendingRows(state)
end

-- The Save button. A value typed into a box and never blurred is still held, so it is committed
-- into staging first; Apply on the way out of the screen does the same for the same reason.
function Panel.saveScope(state, modName)
    if state == nil or state.torndown then
        return
    end
    pcall(Controls.commitPending)
    Panel.applyAll(state, modName)
end

-- The Revert button: drops this scope's staged edits and puts every row back to its file value.
function Panel.revertScope(state, modName)
    if state == nil or state.torndown then
        return
    end
    pcall(Controls.commitPending)
    Panel.discardAll(state, modName)
end

-- Puts the controller on the first row of whatever page is showing. ONLY on a controller: a mouse
-- player who never sees a focus outline must not have focus yanked around behind their back, and a
-- keyboard player is already where they put themselves.
--
-- A collapsed row is skipped: the pending Save and Revert row is built collapsed and only appears
-- once something is unsaved, and focusing a widget that is not on screen is how the first pass
-- ended up focusing nothing at all: the Mod Configs page opened with nothing focused at all
-- (2026-09-06). Every call is guarded, so a build without SetKeyboardFocus does
-- nothing and the tab behaves as it did.
local function isOnScreen(widget)
    local visibility = nil
    pcall(function() visibility = widget:GetVisibility() end)
    if visibility == nil then
        return true
    end
    visibility = tonumber(visibility)
    if visibility == nil then
        return true
    end
    return visibility ~= Config.ui.pageInactiveVisibility and visibility ~= 2
end

-- Called at the end of every page this mod draws. A page swap tears down every row and builds new
-- ones, so whatever the controller was focused on is gone.
--
-- Focus is RE-ASSERTED on a short ladder rather than set once, for the same reason the page swap
-- itself is: vanilla's tab-switch animation runs its callbacks after the builder returns and puts
-- focus back where it wants it, so a single call lands and is immediately overridden. The proof
-- is what alt-tabbing does (2026-09-06): leaving the game and coming back fixed the focus every
-- time, because window re-activation makes CommonUI re-apply it - the tree was always focusable,
-- our one call was just too early.
--
-- It stops as soon as the page holds focus, so it never yanks a player back off a row they moved
-- to themselves.
local function pageHoldsFocus(state)
    for _, widget in ipairs(state.viewWidgets) do
        local held = false
        pcall(function()
            held = widget:HasKeyboardFocus() or widget:HasFocusedDescendants()
        end)
        if held then
            return true
        end
    end
    return false
end

-- Rebuilds whatever page is open, in place. Used when the input device changes: a slider row is
-- built one way for a controller and another for a mouse, so the rows themselves have to be made
-- again. Never called while a page is already being built, and cheap enough at the rate a player
-- actually puts a controller down.
function Panel.refreshView(state)
    if state == nil or state.torndown then
        return
    end
    local view, index = state.view, state.selectedIndex
    if view == "keyboard" then
        -- Half-typed text belongs to the device that was typing it; a change of device leaves the
        -- keyboard rather than rebuilding it around a value the player can no longer edit.
        Panel.leaveKeyboard(state)
    elseif view == "mod" and index ~= nil then
        Panel.showMod(state, index)
    elseif view == "presets" then
        Panel.showPresets(state, nil)
    elseif view == "request" then
        Panel.showRequest(state, nil)
    elseif view == "request-manual" then
        Panel.showManual(state, nil)
    else
        Panel.showHome(state)
    end
end

function Panel.armFocus(state, attempt)
    if state == nil or state.torndown or type(ExecuteInGameThreadWithDelay) ~= "function" then
        return
    end
    if not Gamepad.isActive() then
        return
    end
    attempt = attempt or 1
    local ladder = Config.ui.controls.focusReassertMs
    local delay = ladder[attempt]
    if delay == nil then
        return
    end
    ExecuteInGameThreadWithDelay(delay, function()
        if state.torndown or not Gamepad.isActive() then
            return
        end
        if pageHoldsFocus(state) then
            return
        end
        pcall(Panel.focusFirstRow, state)
        Panel.armFocus(state, attempt + 1)
    end)
end

function Panel.focusFirstRow(state)
    if state == nil or state.torndown or not Gamepad.isActive() then
        return false
    end
    local tried = 0
    for _, widget in ipairs(state.viewWidgets) do
        local alive = false
        pcall(function() alive = widget:IsValid() end)
        if alive and isOnScreen(widget) then
            local target = Rows.focusTargetOf(widget)
            if target ~= nil then
                tried = tried + 1
                if pcall(function() target:SetKeyboardFocus() end) then
                    log.info("controller focus placed on the page's first row")
                    return true
                end
            end
        end
    end
    log.warn("could not place controller focus on the page (" .. tried
        .. " candidate row(s) refused SetKeyboardFocus); navigate to it with the stick instead")
    return false
end

function Panel.destroy(state, bookkeepingOnly)
    if state == nil then
        return
    end
    state.torndown = true
    Panel.stopPolling(state)
    clearView(state, bookkeepingOnly)
end

return Panel
