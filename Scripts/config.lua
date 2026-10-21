-- Tunables and every game symbol this mod resolves, in one place, so a game patch is triaged by
-- reading this file. Every symbol was read from a working implementation (NativeModOptions 1.1.0)
-- on game build 24575825, 2026-08-30; treat them as findings a patch can invalidate.
local Config = {}

-- ============================== Scanning ==============================

-- A candidate file's NAME is not evidence of anything: a non-Lua file that parses into real
-- key=value entries is a user config whatever it is called, and a .lua file qualifies only by
-- content, through Scripts/scope.lua's pure-data gate (comments plus literal data only). Only
-- the extension below and the loose-INI structure gate decide whether a file is even attempted.
-- .txt and .cfg are treated as loose INI: other setups than the reference install may use them,
-- but they only qualify when their content is overwhelmingly key=value shaped (see the
-- structure gate in scanner.lua), so a prose file named "settings.txt" never produces junk rows.
Config.extensions = { [".lua"] = "lua", [".ini"] = "ini", [".json"] = "json",
    [".txt"] = "ini", [".cfg"] = "ini" }
Config.looseIniExtensions = { [".txt"] = true, [".cfg"] = true }
-- Loose-INI structure gate: at least this many entries, and at least this share of the
-- meaningful lines must be [Section] or key=value.
Config.looseIniMinEntries = 2
Config.looseIniMinStructureRatio = 0.6
-- Path depth below the mod folder to search (segments, file included).
Config.maxDepth = 3
-- A settings file has a bounded number of settings; a file with more scalar entries than this is
-- reference data (item/species lookup tables, translation dictionaries), not configuration,
-- whatever its format. Evidence from the reference install's live sweep, 2026-09-01: the
-- smallest reference table found (AntiPhatPalResizing's displaynames.lua) has 304 entries and the
-- largest (PalsLearnOverTime's say.lua) has 3341; the largest surviving legitimate settings file
-- (PalInsight's Scripts\config.lua) has 117. 200 sits between the two with margin on both sides.
Config.maxSettingsPerFile = 200
-- A preset file larger than this is refused outright: no legitimate preset approaches it, and
-- reading one unbounded would let a corrupted or malicious file exhaust memory.
Config.presetMaxBytes = 1048576

-- A file carrying one of these tokens before its extension (SmartPalFeeding.default.ini) is a
-- template: never edited, used as that file's defaults source. So is any file whose name minus
-- the token matches a sibling.
Config.templateTokens = { ".default.", ".example.", ".template.", ".sample." }

-- Mod folders never scanned: self (both identities) and shared libraries. The two mod-options
-- frameworks' own folders are NOT here: their saved-value stores are scanned and reattributed to
-- the consumer mod each file belongs to (Config.frameworkPathPatterns below), never excluded.
Config.excludedMods = {
    ["UniversalConfigManager"] = true,
    ["UniversalConfigManagerDev"] = true,
    ["shared"] = true,
}

-- File names never treated as configs, wherever they appear: framework bridge copies, JSON
-- library files that would otherwise parse into entries and be classified like a real config,
-- and the loader's own package manifests (Info.json, the uploader's .workshop.json), which some
-- mods ship inside their UE4SS folder.
Config.excludedFileNames = {
    ["mod_options_client.lua"] = true,
    ["palmodoptionsclient.lua"] = true,
    ["json.lua"] = true,
    ["pmo_json.lua"] = true,
    -- `main.lua` is NOT excluded: a single-file mod keeps its settings there behind a comment
    -- inviting the player to edit them, and a blanket exclusion hid every one of them (audit,
    -- 2026-09-03: UE4SS's own Keybinds mod). A code-heavy main.lua classifies `advanced` and
    -- shows only in Advanced Mode, which is what Advanced Mode is for.
    ["info.json"] = true,
    [".workshop.json"] = true,
}

-- Per-mod path prefixes never scanned. The two frameworks' per-consumer saved-value paths used
-- to be listed here (blanket exclusion); they are now reattributed instead, via
-- Config.frameworkPathPatterns below, so they no longer appear in this list.
Config.excludedPathPrefixes = {
}

-- A folder a mod WRITES into, never one a player edits. A mod's own output can hold a copy of
-- its config under the same key names, which then shows twice under one mod with two different
-- values and no way to tell which one the mod reads (audit, 2026-09-03: AlkeariLogging's
-- logs\companion-directive.ini beside Scripts\companion.ini). Matched on the first path segment
-- under the mod's folder, so it holds on any install.
Config.excludedFolderNames = {
    logs = true, log = true, cache = true, caches = true, backup = true, backups = true,
    out = true, output = true, temp = true, tmp = true, crashes = true,
}

-- Framework saved-value stores: matched by (folder, filename-without-extension) -> the id is
-- the consumer mod this file's settings actually belong to. Replaces plain exclusion: these
-- files are now reattributed to their consumer mod's own scan-model entry, not skipped.
-- `headerLines` is how many leading comment lines ParseFramework must skip for this store
-- (0 for NativeModOptions' flat root *.ini, 2 for PalModOptions' "# ..." header pair).
Config.frameworkPathPatterns = {
    { folder = "nativemodoptions", source = "framework:nativemodoptions", headerLines = 0,
      idFromFile = function(fileName) return fileName:match("^(.*)%.ini$") end },
    { folder = "palmodoptions\\scripts\\config", source = "framework:palmodoptions",
      headerLines = 2,
      idFromFile = function(fileName) return fileName:match("^(.*)%.ini$") end },
}

-- ============================== UI ==============================

-- Mirrors Info.json's Version (the release source); shown in the log and the request file.
Config.version = "1.5.0"

-- Once per game start the mod asks alkeari.com for its newest published version and, only when a
-- newer one exists, says so in the game's on-screen log. Nothing is sent but that request. Set it to
-- false to turn the check off; turning it on takes effect the next time you launch the game.
Config.checkForUpdates = true

Config.ui = {
    optionSettingsAsset = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/WBP_OptionSettings",
    menuButtonAsset = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/WBP_OptionSettings_MenuButton",
    buttonBaseAsset = "/Game/Pal/Blueprint/UI/System/Style/WBP_PalCommonButtonBase",
    -- No art and no children: one empty CanvasPanel, so it takes exactly the slot it is given.
    invisibleButtonAsset = "/Game/Pal/Blueprint/UI/System/Style/WBP_PalInvisibleButton",
    listContentAsset = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/WBP_OptionSettings_ListContent",
    switchClass = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/WBP_OptionSettings_ListContentSwitch.WBP_OptionSettings_ListContentSwitch_C",
    sliderClass = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/WBP_OptionSettings_ListContentSlider.WBP_OptionSettings_ListContentSlider_C",
    textBlockAsset = "/Game/Pal/Blueprint/UI/PalTextBlock/BP_PalTextBlock",

    -- ESlateVisibility: SelfHitTestInvisible for the active page, Collapsed removes from layout.
    pageActiveVisibility = 4,
    pageInactiveVisibility = 1,

    -- The width this page asks for; vanilla's own pages report 704-786 wide. There is no height
    -- override: the page is as tall as its rows and the screen's own ScrollBox scrolls it.
    listWidth = 786,

    -- What a row is ACTUALLY as wide as, measured off a screenshot of the game (2026-09-03): the
    -- SizeBox override above does not constrain row width, so listWidth is the width we ask for
    -- and this is the width we get. Anything laying text out inside a row uses THIS. Anchoring
    -- the action row's label room to listWidth threw away 387 units and ellipsized preset names
    -- that fit perfectly well.
    rowWidth = 1173,

    -- Entries.width estimates at BP_PalTextBlock_C's DEFAULT advance, but every caption this mod
    -- draws is put through Rows.copyFont to the screen's 14 pt row-label font, which is smaller.
    -- Derived from the recorded measurement (2026-09-03 14:52): "Resource Respawn
    -- Test Enabled" estimates 458.8 and rendered 319 units, so 319/458.8. Without it every width
    -- in a row is over-stated by about half again, which is why the first pills came out fat.
    labelFontScale = 0.695,

    -- Vanilla prompts "apply changed settings?" from its pages' SomethingChanged flags; raising
    -- GameSettings' (the page with the most inert apply) routes our edits through the same prompt.
    dirtyPageField = "GameSettings",

    -- The five real category buttons/pages on WBP_OptionSettings_C.
    realButtonFields = { "Graphic", "Sound", "Game", "Key", "Other" },
    realPageFields = { "GraphicSettings", "AudioSettings", "KeySettings", "GameSettings",
        "OtherSettings" },

    -- Invoking the Control tab's bound event is what lays the content area out; switching to the
    -- already-selected tab early-outs, and a fresh screen shows Graphic, so Control is safe.
    controlTabEvent = "BndEvt__WBP_OptionSettings_WBP_OptionSettings_MenuButton_Control_K2Node_ComponentBoundEvent_2_OnClicked__DelegateSignature",

    -- The tab switch drives an animation whose completion callbacks can re-show the page it
    -- activated; the page swap is re-asserted on these delays (ms).
    switchReassertMs = { 100, 300, 600 },

    -- Bound-event names on the game's own row widgets through which value changes arrive.
    -- SWITCH alone is only the gamepad/keyboard path; mouse clicks arrive via the ON/OFF buttons'
    -- bound events.
    switchChangeEvents = {
        "SWITCH",
        "BndEvt__WBP_OptionSettings_ListContentSwitch_WBP_PalCommonButton_OFF_K2Node_ComponentBoundEvent_2_CommonButtonBaseClicked__DelegateSignature",
        "BndEvt__WBP_OptionSettings_ListContentSwitch_WBP_PalCommonButton_OFF_K2Node_ComponentBoundEvent_7_CommonButtonBaseClicked__DelegateSignature",
        "BndEvt__WBP_OptionSettings_ListContentSwitch_WBP_PalCommonButton_OFF_K2Node_ComponentBoundEvent_8_CommonButtonBaseClicked__DelegateSignature",
        "BndEvt__WBP_OptionSettings_ListContentSwitch_WBP_PalCommonButton_ON_K2Node_ComponentBoundEvent_9_CommonButtonBaseClicked__DelegateSignature",
        "BndEvt__WBP_OptionSettings_ListContentSwitch_WBP_PalCommonButton_ON_K2Node_ComponentBoundEvent_10_CommonButtonBaseClicked__DelegateSignature",
        "BndEvt__WBP_OptionSettings_ListContentSwitch_WBP_PalCommonButton_ON_K2Node_ComponentBoundEvent_11_CommonButtonBaseClicked__DelegateSignature",
    },
    sliderChangeEvent = "BndEvt__WBP_OptionSettings_ListContentSlider_Slider_K2Node_ComponentBoundEvent_0_OnFloatValueChangedEvent__DelegateSignature",

    -- The full-width row frame's click target, tried in order. Object dump (build 24575825,
    -- 2026-09-01): WBP_OptionSettings_ListContent_C has no WBP_PalInvisibleButton field at all;
    -- its click children are Button and WBP_OptionSettings_ClickableButton (both
    -- ObjectProperty). WBP_PalInvisibleButton is kept last as the field the game's own
    -- WBP_OptionSettings_MenuButton_C uses (Rows.createModButton), in case a future build adds
    -- it to the row frame too.
    rowClickFields = { "Button", "WBP_OptionSettings_ClickableButton", "WBP_PalInvisibleButton" },

    -- The width a notice line wraps at. Not `rowWidth`: a header line is a bare text block in the
    -- page's own vertical box, and the screen clipped the reload notice at 849 units when the
    -- sentence itself measures 915 at the row font (measured 2026-09-07). 820 sits
    -- inside what was proven available, and every translation wraps rather than being cut.
    noticeWidth = 820,

    -- The row's OWN click handler, and the two functions its edit mode binds the D-pad to
    -- (bytecode of WBP_OptionSettings_ListContent, build 25094871). A mouse click
    -- reaches the invisible button inside the row; a controller press reaches the ROW, which
    -- broadcasts its own delegate and never runs that button's BP_OnClicked.
    rowClickEvent = "BndEvt__WBP_OptionSettings_ListContent_WBP_PalInvisibleButton"
        .. "_K2Node_ComponentBoundEvent_3_CommonButtonBaseClicked__DelegateSignature",
    rowGamepadLeft = "Gamepad_LeftPress",
    rowGamepadRight = "Gamepad_RightPress",

    -- Both paths can fire for one mouse click. A second press of the same row inside this many
    -- seconds is the same press arriving twice, not the player clicking twice: a file header
    -- toggled twice looks like nothing happened at all.
    rowPressDedupeSeconds = 0.25,

    -- Seen on the mod-list home view (screenshot, 2026-09-01): a row built with
    -- Rows.createRowButton (a click target tracked on the game's own WBP_OptionSettings_ListContent_C
    -- frame) showed every one of the frame's control children at once next to the caption - a
    -- slider, a switch, an LR selector, and a checkbox - because createRowButton never collapses
    -- them the way the frame's own SetSwitcher/SetSlider/SetSelecter_String functions do for a
    -- real switch/slider/dropdown row. Every control child the frame can carry, collapsed with
    -- SetVisibility(pageInactiveVisibility) except whichever one was resolved as the click
    -- target. Includes the fields this mod's own switch/slider rows already use plus the
    -- additional control children named from the game's row-widget naming convention
    -- (..ListContentLR for the LR/dropdown selector, ..ListContentButton and
    -- ..ListContentCheckbox per the sibling classes the object dump records); each is only ever
    -- touched through pcall, so a name that does not exist on this build is a silent no-op.
    rowButtonCollapsedChildren = {
        "WBP_OptionSettings_ListContentSwitch",
        "WBP_OptionSettings_ListContentSlider",
        "WBP_OptionSettings_ListContentLR",
        "WBP_OptionSettings_ListContentButton",
        "WBP_Title_WorldSettings_ListButton",
        "WBP_OptionSettings_ClickableButton",
    },
}

-- Finding, build 24575825, 2026-09-01: frame:SetConfigButton() FAILED (Rows.createRowButton's
-- logSetConfigButtonOnce logged "failed" in a live pass), so it never collapses
-- a row's other control children on its own. This is why collapseUnusedRowChildren (above) does
-- the collapsing explicitly instead of relying on it; the pcall around SetConfigButton stays, as
-- a future build may fix or remove the function and the call must stay harmless either way.

-- What this section builds: a "Mod Configs" button on the in-world ESC menu (WBP_MenuESC_C, the
-- same screen PalModOptions injects its own "Mod Options" button into) opening the options screen
-- on our tab. Every symbol below is read from PalModOptions 0.1.15's own working source
-- (PalModOptions\Scripts\main.lua, game build 24575825, 2026-09-01) -- the same mod this mod's
-- Config.frameworks.buttonIdentity.palModOptions block already documents for hiding that mod's
-- own ESC-menu button, since our button is built and inserted the identical way.
Config.ui.escMenu = {
    -- The ESC button Blueprint asset PalModOptions builds its own entry from (main.lua lines 26,
    -- 30: PMO.esc_button_class). A different asset than WBP_OptionSettings_MenuButton (the
    -- options-screen category button this mod's own category tab uses).
    buttonAsset = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button",
    buttonClass = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button."
        .. "WBP_MenuESC_Button_C",

    -- Caption field: set_button_text() (main.lua lines 1064-1070) calls
    -- `button.Text_Main:SetText(FText(tostring(text or "")))`. Same field
    -- Config.frameworks.buttonIdentity.palModOptions.captionField already names for reading the
    -- OTHER mod's button back; here it is the field this mod writes its OWN caption into.
    captionField = "Text_Main",

    -- Anchor-and-insert idiom, identical to how PalModOptions inserts its own button
    -- (`option_button = menu.WBP_MenuESC_Button_Option`, main.lua line 1986;
    -- `insert_vertical_after(first_group, option_button, state.entry_button)`, line 2042) and the
    -- same field Config.frameworks.buttonIdentity.palModOptions.anchorField already names.
    -- `menu[anchorField]:GetParent()` reaches the button group VerticalBox in one reflected field
    -- read plus one GetParent() call, no recursive tree walk.
    anchorField = "WBP_MenuESC_Button_Option",

    -- insert_vertical_after's own mechanics (main.lua, the function backing line 2042): find the
    -- anchor's child index in its VerticalBox parent, pop every trailing child from the box with
    -- GetChildAt/RemoveChildAt (collecting them in order), AddChildToVerticalBox the new button,
    -- then re-add each popped child in its original order. This keeps the new button positioned
    -- directly after the anchor without needing an insert-at-index API the VerticalBox reflection
    -- surface does not expose.
    insertMechanics = "GetChildIndex(anchor) on the parent VerticalBox, then repeatedly "
        .. "GetChildAt(index+1)/RemoveChildAt(index+1) to pop every trailing child (collecting "
        .. "them in order), AddChildToVerticalBox(newButton), then AddChildToVerticalBox each "
        .. "popped child back in its original order",

    -- Click detection: PalModOptions registers a class-wide hook on its own button's bound click
    -- event and resolves the firing instance by address (main.lua's own button click wiring).
    -- BUTTON_BASE_CLASS (Config.ui.buttonBaseAsset, WBP_PalCommonButtonBase_C) is this button's
    -- invisible child, the same pattern this mod's own options-screen category button already
    -- uses (inject.lua's BP_OnClicked hook on that same class) -- the bound-event name below is
    -- the class-specific delegate PalModOptions itself hooks, recorded for completeness even
    -- though this mod's own click handling goes through the shared BUTTON_BASE_CLASS hook.
    clickBoundEvent = "BndEvt__WBP_MenuESC_Button_WBP_PalInvisibleButton_"
        .. "K2Node_ComponentBoundEvent_0_CommonButtonBaseClicked__DelegateSignature",

    -- Triggering the vanilla Option button programmatically to open the options screen: tried in
    -- this order (main.lua's own option_button field name, `menu.WBP_MenuESC_Button_Option`, is
    -- the same field anchorField above already names). No confirmed working call was found in
    -- either framework's source for firing a button's OWN click programmatically (both only ever
    -- react to a live click), so all three are tried and the first that does not throw is used
    -- and logged once.
    optionButtonInvisibleChildField = "WBP_PalInvisibleButton",
    optionButtonClickMethods = { "WBP_PalInvisibleButton.BP_OnClicked", "BP_OnClicked",
        "boundEventFunction" },

    -- Found in a live session and in a header dump taken the same evening (session
    -- 2026-09-01 23:28-23:30): calling any of the three Blueprint-event methods above only runs
    -- that event's own graph, never the real native click plumbing, so the button used to log a
    -- false "opened the options screen" line while nothing actually opened. CXXHeaderDump/Pal.hpp
    -- was read to find the real path: PalHUDInGame exposes
    -- `PushWidgetStackableUI(WidgetClass, Parameter)` (a ClassProperty WidgetClass, an
    -- ObjectProperty Parameter, struct return) - the options screen is itself a
    -- PalUserWidgetStackableUI (PalModOptions' own code hooks
    -- /Script/Pal.PalUserWidgetStackableUI:Close, confirming the class), so pushing
    -- WBP_OptionSettings_C's class through the HUD is the same mechanism vanilla's own click uses.
    -- PalHUDService:ShowCommonUI(EPalWidgetBlueprintType, Parameter) was also dumped and has NO
    -- Option entry in its enum, so it is not a candidate. Tried FIRST; the three Blueprint-event
    -- methods above remain as fallbacks, tried in order, one per Config.ui.escMenu.openTimeoutMs
    -- window, in case PushWidgetStackableUI's signature or availability changes on a future
    -- build. `kind` selects the dispatch in Scripts/inject.lua's tryOpenMethod; `name` is the
    -- string logged on a confirmed open or listed in the "none worked" warning.
    openMethods = {
        { name = "PalHUDInGame:PushWidgetStackableUI(WBP_OptionSettings_C, nil)", kind = "hud" },
        { name = "the Option button's invisible child's BP_OnClicked", kind = "invisibleChild" },
        { name = "the Option button's own BP_OnClicked", kind = "own" },
        { name = "the Option button's bound click event", kind = "boundEvent" },
    },

    -- How long to wait after firing one open method before concluding it did not actually open
    -- the options screen and trying the next one (ms). inject()'s own screenSeenAtMs is compared
    -- against the click timestamp with this same window (Inject.escOptionOpenConfirmed) to decide
    -- honest success - a trigger call returning without error is never treated as proof by itself.
    openTimeoutMs = 3000,

    -- How long a pending "select our category once the options screen opens" request stays live
    -- before it is considered expired and dropped (ms). Generous enough to cover the vanilla
    -- Option button's own screen-open animation and this mod's OnSetup/OpenPanel re-trigger path,
    -- short enough that a stale flag from an aborted attempt can never fire on a much later,
    -- unrelated options-screen open.
    pendingSelectTimeoutMs = 5000,
}

-- Row-widget style settability findings, read from source (no live deploy), game build
-- 24575825, 2026-09-01: NativeModOptions 1.1.0 and PalModOptions 0.1.15's own working source,
-- plus a grep of this mod's own Scripts/ for every UMG style-property write. Each entry records
-- what a style call is proven or unproven to accept; Config.ui.theme below is what gets applied.
--
-- THE CENTRAL NEGATIVE FINDING: neither framework, nor this mod's own Scripts/rows.lua, sets
-- ANY color/brush/tint/font/opacity property on WBP_OptionSettings_ListContent_C (the row
-- frame) or its WBP_OptionSettings_ListContentSwitch_C / ..ListContentSlider_C children,
-- anywhere. Both frameworks build rows from that exact frame class the same way this mod does
-- (NativeModOptions\Scripts\row_switch.lua: `Widgets.createUserWidget(outer, FRAME_PATH,
-- FRAME_ASSET)` then `frame.WBP_OptionSettings_ListContentSwitch`, `frame:SetSwitcher(...)`,
-- `RowLabel.set(frame, label)` -- SetText only) and never touch a style property on the frame
-- or the switch/slider child; grepping row_switch.lua and row_slider.lua for ColorAndOpacity,
-- SetColorAndOpacity, Brush, Tint, RenderOpacity, SetRenderOpacity, WidgetStyle, SetBrush,
-- SetFont, SetStyle, SetIcon, SetIsEnabled and SetToolTipText returns zero matches; the same
-- grep across this mod's own Scripts/rows.lua, widgets.lua and inject.lua also returns zero
-- matches (confirmed 2026-09-01). This is silence, not proof: whether these three Blueprint
-- classes expose ANY reflected style property at all (a background Brush, a tint) is genuinely
-- undetermined from source, because nobody who has shipped code against them has ever tried.
-- Settling it needs a live UE4SS property enumeration against a real row instance, which
-- static reading cannot substitute for.
--
-- What IS proven, on widget classes NEITHER framework applies to a row frame or switch/slider:
Config.ui.style = {
    -- TextBlock (BP_PalTextBlock_C, the same class this mod's own label/description/section
    -- rows already use): proven-in-NMO. NativeModOptions\Scripts\native_style.lua copyColor():
    -- `target:SetColorAndOpacity(reference.ColorAndOpacity)`. Critically,
    -- NativeModOptions\Scripts\row_warning.lua ALSO calls `text:SetColorAndOpacity(
    -- FALLBACK_CAUTION_COLOR)` where FALLBACK_CAUTION_COLOR is built ENTIRELY in Lua, no live
    -- widget involved: `{ SpecifiedColor = { R = 1.0, G = 0.78, B = 0.20, A = 1.0 },
    -- ColorUseRule = 0 }` (row_warning.lua lines 25-28, 83). This proves an FSlateColor-shaped
    -- table constructed purely in Lua is accepted by TextBlock:SetColorAndOpacity -- a custom
    -- color does not require copying a live reference widget.
    textBlockColorAndOpacity = "proven-in-NMO: TextBlock:SetColorAndOpacity accepts a plain "
        .. "Lua table { SpecifiedColor = {R,G,B,A}, ColorUseRule = 0 }, no live reference needed",

    -- TextBlock font: proven-in-NMO, but ONLY as a copy of a live reference's Font
    -- (native_style.lua copyFont(): `target:SetFont(reference.Font)`). The file's own comment
    -- states why: "An FSlateFontInfo cannot be constructed from Lua, but one can be read off a
    -- live widget and handed straight back to SetFont." No Lua-built font was ever attempted.
    textBlockFont = "proven-in-NMO, copy-only: SetFont(reference.Font) works, but the "
        .. "FSlateFontInfo struct itself must come from a live widget, never built in Lua",

    -- TextBlock CommonTextStyle class swap: proven-in-NMO as a code path
    -- (native_style.lua applyStyle(): `target:SetStyle(styleClass)`, styleClass found via
    -- StaticFindObject/LoadAsset on a style asset path) but NEVER exercised with a real
    -- stylePath anywhere in the reference install's mods -- every RowWarning.create() call this
    -- install's mods make passes stylePath = nil, so vanilla's own default text style is what
    -- always renders. The plumbing is proven; a working stylePath value is not.
    textBlockSetStyle = "proven-in-NMO as a code path (SetStyle(class) is called and does not "
        .. "error), never exercised with a real style class on this install",

    -- Image brush: proven-in-NMO, texture-only. RowWarning/row_keybind construct a
    -- `/Script/UMG.Image` and call `image:SetBrushFromTexture(texture, bMatchSize)` --
    -- takes a UTexture object pointer plus a bool, not a raw FSlateBrush struct. The comment in
    -- row_image.lua states why: "SetBrushFromTexture and SizeBox are preferred over SetBrush and
    -- SetDesiredSizeOverride because they take an object pointer and two numbers; the
    -- alternatives need FSlateBrush and FVector2D," both of which "cannot be constructed from
    -- Lua." SetBrushResourceObject(texture) (row_keybind.lua) swaps only the texture on an
    -- already-styled brush. SetIcon(brush) (row_keybind.lua, native_style.lua) needs a whole
    -- live FSlateBrush struct copied off another widget's .Brush field -- never built from
    -- scratch either. Image:SetColorAndOpacity is also used (row_warning.lua line 118), always
    -- copying a live reference's ColorAndOpacity, never a Lua-built value (unlike the TextBlock
    -- case above, which IS proven Lua-buildable).
    imageBrush = "proven-in-NMO: SetBrushFromTexture(texture, bool) and "
        .. "SetBrushResourceObject(texture) take a texture object and work with no live "
        .. "reference; SetBrush/SetIcon need a whole FSlateBrush struct, which can only be "
        .. "copied off a live widget, never constructed in Lua",
    imageColorAndOpacity = "proven-in-NMO, copy-only: always copied from a live reference's "
        .. "ColorAndOpacity in this codebase, never attempted as a Lua-built value (contrast "
        .. "TextBlock, where a Lua-built value IS proven)",

    -- EditableTextBox WidgetStyle struct (ForegroundColor / FocusedForegroundColor /
    -- ReadOnlyForegroundColor / BackgroundColor / TextStyle.ColorAndOpacity, all mutated on the
    -- struct in place then written back via SetWidgetStyle) and SetForegroundColor(FLinearColor)
    -- directly: proven-in-PalModOptions (main.lua apply_input_appearance(), lines 1029-1062),
    -- with every color value built in Lua from a #RRGGBB hex string (srgb_color()), no live
    -- reference at all. Applies to /Script/Pal.PalEditableTextBox / UMG.EditableTextBox only --
    -- not a class this mod or NativeModOptions uses for any row.
    editableTextBoxWidgetStyle = "proven-in-PMO: WidgetStyle color fields and "
        .. "SetForegroundColor both accept Lua-built FLinearColor tables with no live reference, "
        .. "on EditableTextBox only",

    -- SetIsEnabled(bool): proven-in-PMO (main.lua set_widget_enabled(), line ~1072-1078:
    -- `widget:SetIsEnabled(enabled == true)`), used on its dynamically built buttons. Not
    -- observed anywhere in NativeModOptions' source or this mod's own Scripts/.
    setIsEnabled = "proven-in-PMO on its own custom ESC-menu button widgets; unproven on any "
        .. "vanilla options-screen row widget",

    -- Visibility / SetVisibility: proven-in-NMO and proven-here, but only ever a switch between
    -- the two ESlateVisibility values already in Config.ui (pageActiveVisibility /
    -- pageInactiveVisibility) -- never a style property in the tint/color sense.
    visibility = "proven-in-NMO and proven-here: SetVisibility / the Visibility field, "
        .. "toggled between SelfHitTestInvisible and Collapsed throughout both codebases",

    -- Standard UMG reflection candidates neither framework nor this mod has ever exercised.
    -- These are ordinary UWidget/TextBlock/Image properties in every UE5 build; nothing here
    -- says they are UNAVAILABLE on the game's Blueprint row classes, only that no working
    -- Palworld mod source found by this pass has ever touched them.
    renderOpacity = "standard UMG (every UWidget carries RenderOpacity / SetRenderOpacity), "
        .. "unproven here: neither framework nor this mod's own code sets it anywhere",
    toolTipText = "standard UMG (SetToolTipText / ToolTipText on any UWidget), unproven here: "
        .. "not found in either framework's source or this mod's own code",
    imageColorAndOpacityFromScratch = "standard UMG (Image:SetColorAndOpacity takes an "
        .. "FLinearColor, which the TextBlock case above proves is Lua-constructible for the "
        .. "sibling FSlateColor shape), unproven here specifically for Image: every observed "
        .. "call copies a live reference instead of building one",

    -- The actual open question, unresolved by any static reading: does
    -- WBP_OptionSettings_ListContent_C (the row frame our rows.lua and NativeModOptions'
    -- row_switch.lua/row_slider.lua both build from) or WBP_OptionSettings_ListContentSwitch_C /
    -- ..ListContentSlider_C expose ANY color, brush, or tint property through reflection at all.
    -- No source this pass read ever asks that question of these three specific classes. A live
    -- UE4SS property dump against a real instance is the only way to answer it;
    -- this file records the answer once one exists, keyed the same way as everything above.
    rowFrameAndSwitchSliderStyle = "UNRESOLVED by static evidence - neither framework's source "
        .. "nor this mod's own code ever inspects or sets any style property on "
        .. "WBP_OptionSettings_ListContent_C, ..ListContentSwitch_C or ..ListContentSlider_C; "
        .. "requires a live property enumeration to answer",
}

-- Our own controls inside a row frame. PalComboBoxString is the game's native dropdown
-- (object dump, build 24575825, 2026-09-01: AddOption, ClearOptions, FindOptionIndex,
-- GetOptionAtIndex, GetOptionCount, GetSelectedOption, RefreshOptions, RemoveOption,
-- SetSelectedOption). EditableTextBox is stock UMG; PalModOptions constructs it from Lua on
-- this build. CanvasPanel_0 is the row frame's own canvas (object dump). Layouts are
-- right-anchored so the control sits where the switch and slider do; the numbers are a
-- first placement, tuned after a pass in game.
Config.ui.controls = {
    comboBoxClass = "/Script/Pal.PalComboBoxString",
    textBoxClass = "/Script/UMG.EditableTextBox",
    canvasField = "CanvasPanel_0",
    comboLayout = { anchorMinX = 1, anchorMinY = 0.5, anchorMaxX = 1, anchorMaxY = 0.5,
        alignX = 1, alignY = 0.5, x = -24, y = 0, w = 400, h = 44 },
    textLayout = { anchorMinX = 1, anchorMinY = 0.5, anchorMaxX = 1, anchorMaxY = 0.5,
        alignX = 1, alignY = 0.5, x = -24, y = 0, w = 400, h = 44 },
    -- The number on a slider row, typed instead of dragged. A slider cannot land on a round
    -- number when its step resolves to 0 (a continuous bar) - six of GoToBedTeleportEdition's
    -- nine numeric settings do - so the value the bar shows is replaced by an editable box in
    -- the same slot, and the player types the value they actually want: on a continuous bar the
    -- slightest adjustment of the slider can only get as close as 50.5 (2026-09-04).
    -- Sits where Config.ui.theme.valueTextSlot puts the game's own value text, at the right
    -- inset, ending where the bar begins; narrow, because it holds a number and nothing else.
    -- Right-aligned, so widening the box grows it LEFTWARDS into empty row and never towards
    -- the bar. 50 further left than first placed, because the box was drawing over the slider's
    -- own thumb, and wide enough that a seven-digit value (a gold cost runs to 1000000) is fully
    -- readable rather than clipped (seen clipped on 2026-09-04).
    sliderValueLayout = { anchorMinX = 1, anchorMinY = 0.5, anchorMaxX = 1, anchorMaxY = 0.5,
        alignX = 1, alignY = 0.5, x = -474, y = 0, w = 220, h = 44 },
    -- Controller focus is re-asserted on this ladder after a page is built: vanilla's tab-switch
    -- animation puts focus back where it wants it after our builder returns, so one call is not
    -- enough. It stops early the moment the page holds focus. Milliseconds.
    focusReassertMs = { 0, 120, 300, 700, 1200 },

    -- This mod's own on-screen keyboard, for a controller entering free-form text. Palworld
    -- ships no keyboard of its own (checked 2026-09-07) and a pad has no other way to type.
    -- Rows of at most ten keys: ten keys at the action row's minimum width, with its gaps and
    -- inset, come to 972 of a 1173 row, so every key is a real target rather than a sliver.
    keyboard = {
        -- Indented like a real keyboard, so the rows read as one: each row starts a little
        -- further right than the one above, the way a physical board staggers.
        rows = {
            { keys = "1234567890", indent = 0 },
            { keys = "qwertyuiop", indent = 0 },
            { keys = "asdfghjkl", indent = 48 },
            { keys = "zxcvbnm", indent = 96 },
            { keys = "._-+/,:;", indent = 144 },
        },
        -- Not on a key: a space is a word the player can read, and the rest are actions.
        maxPreview = 96,
    },

    -- EUINavigation, Slate's own direction enum, for SetNavigationRuleExplicit. A controller
    -- moves between ROWS on its own, but nothing carried it between the buttons inside one row:
    -- left escaped the page to the category buttons and right did nothing, so only the first key
    -- of each keyboard row could be reached (seen 2026-09-07). Linking each button to its
    -- neighbours explicitly is what makes a row of keys a row.
    navigation = { left = 0, right = 1, up = 2, down = 3 },

    -- The longest list a controller is asked to pick from. Past this a stick is worse than the
    -- keyboard, and the Possible Entries strip already shows the values either way.
    pickListMax = 60,

    -- ESlateVisibility for a text box by input device. Visible takes focus and the caret; on a
    -- controller it becomes SelfHitTestInvisible, which still draws the box and its value but
    -- takes it out of the focus path, because a pad cannot type into one or reliably leave one.
    textBoxVisibility = 0,
    textBoxGamepadVisibility = 4,

    -- A path box narrower than this is not worth drawing: the caller keeps its plain row rather
    -- than a box with three characters in it.
    pathFieldMinWidth = 240,
    -- How long a Copy button reads "Copied" before going back to "Copy".
    copiedRevertMs = 5000,
    pollIntervalMs = 250,

    -- The Backspace gate runs on its own, much faster clock than the control poll above.
    -- Palworld's close action fires on key RELEASE, and Palpedia Enhancer's own source records
    -- what that means (PalpediaUi.cpp, SetTypingInputMode): "waiting for the first keystroke to
    -- prove focus means the very first Backspace has already escaped". A 250 ms gap between
    -- clicking into a box and the gate closing is that whole race, every time, which is why
    -- Backspace still left the screen after the gate was first added (2026-09-04).
    focusPollMs = 50,
    -- Polls the gate stays closed after focus is lost. The close action fires on key release, so
    -- letting go of Backspace just as focus drops must still land inside the gate.
    typingGateReleasePolls = 6,
    -- The gate disables the game's own CommonUI input, which is what ESC and every Back action
    -- runs on. If it is ever held with no way to release it, the whole settings screen stops
    -- responding - not just this mod's page (2026-09-07: after moving from a controller to the
    -- keyboard, ESC did nothing on any tab). Nothing this mod does may be able to leave the
    -- game in that state, so the hold is bounded: at focusPollMs of 50 ms, 120 polls is six
    -- seconds, far longer than the release countdown ever needs and far shorter than a player
    -- would sit wondering why the menu is dead.
    typingGateMaxHoldPolls = 120,
    -- The Possible Entries strip under a text box (Rows.createHintPanel): text on the page
    -- background, no border, no fill, never a row frame - a row frame reads as a setting and a
    -- filled box reads as a second input. It spans from the row label's column to the text box's
    -- right edge: the box's own 400 units hold only 21 key-name characters at the game text's
    -- default size (measured 2026-09-03), so the strip keeps that box's right edge and position
    -- and extends left into the empty space beside it.
    -- The text keeps the default size: a SetFont call aborted the game.
    hint = {
        -- Slot padding on the page list: Left puts the strip's text at the label column
        -- (measured label origin 25 units into the row), Right ends it at the text box's right
        -- edge (its 24-unit inset plus the row's own 8).
        slotPadding = { left = 32, top = 0, right = 32, bottom = 8 },
        -- Body lines hang under the headline's text, not its box edge.
        indent = 16,
        -- Wrap budget in UMG units: the measured row width 1173 minus both paddings, minus slack.
        -- There is no line cap: every entry is shown and the strip's filter box narrows a long
        -- list.
        maxWidth = 1100,
        -- Glyph advance at BP_PalTextBlock_C's default size, UMG units, measured off a
        -- 2026-09-03 19:23 screenshot (1 unit = 1.3325 px): "Numpad, mouse buttons," 505 px over
        -- 22 characters, "like F7 needs no" 317 px over 16. `wide` (CJK and fullwidth) is
        -- ASSUMED twice `upper` until a Japanese-language screenshot measures it.
        charWidth = { upper = 17.2, lower = 15.6, wide = 34.4, zero = 0 },
    },

    -- An action row's buttons are BUILT, not borrowed: a stock Border for the pill, a text block
    -- for the caption, and WBP_PalInvisibleButton_C for the click. The game's own menu button
    -- carries baked 296x64 art and IGNORES the canvas slot it is given, so every fixed pixel
    -- offset written against it was wrong the moment a caption changed length - which it does in
    -- all 17 languages: the buttons overlapped and ran off the right edge (2026-09-06).
    -- The invisible button's whole widget tree is one empty CanvasPanel (pak dump, build
    -- 24575825), so it has no desired size of its own and takes exactly the rect it is given.
    actionRow = {
        -- 44, like every other control this mod places in a row (comboLayout, textLayout,
        -- sliderValueLayout above): a pill 4 units shorter than the text box above it
        -- reads as a different family of control.
        height = 44,
        -- Distance from the row's right edge to the rightmost button's right edge. Matches
        -- theme.rowIconInset, so a pill lines up with every trailing chevron in the list.
        inset = 24,
        gap = 12,
        -- Padding either side of the caption inside a button. Real padding: the caption sits in
        -- its own auto-sized slot centered on the pill, so this is space, not just arithmetic.
        padX = 20,
        minWidth = 84,
        -- 320, not 240: the widest caption this mod ships is the French delete confirmation at
        -- 261 units, and a cap below that clipped it in six languages (measured 2026-09-06).
        -- Three buttons at this width still come to 1008 of a 1173 row.
        maxWidth = 320,
        -- Space kept clear to the right of the row label before the first button may start.
        labelGap = 32,
        -- The 1 unit of outer border that shows around a pill's fill as its edge.
        borderWidth = 1,
        -- The edge a button takes while it holds focus. Focus only ever lands on a widget through
        -- controller or keyboard navigation, so a mouse-only player never sees this and the tab
        -- looks exactly as it did. Without it a controller player cannot see which button they
        -- are on, which is the whole of the problem.
        focusEdge = "accent",
    },

    -- A pending-changes row is Visible while its scope has something to save, and HIDDEN rather
    -- than collapsed otherwise, so it keeps its space and the page under it never moves. Closing
    -- the gap looked tidier and was worse to use: every edit and undo pushed the whole list down
    -- or pulled it back up under the player's cursor, and a slider nudged back and forth jumped
    -- the page each time (seen 2026-09-07). ESlateVisibility, the same enum as
    -- pageActiveVisibility above; the row holds buttons, so it needs real hit testing.
    pendingVisibleVisibility = 0,
    pendingHiddenVisibility = 2,
}

-- The Alkeari theme, applied to option rows. `Config.ui.style` above is the
-- 2026-09-01 settability-findings table (what a property call is proven or unproven to accept);
-- this is the separate, actionable palette the findings feed into. Every setter Rows.applyStyle
-- makes is its own pcall, so a property this build refuses to accept leaves the vanilla look for
-- that element rather than erroring.
Config.ui.theme = {
    enabled = true,
    -- Roles from the Alkeari design system,
    -- where the hex values are recorded once and never restated. These are those same colors
    -- as linear-float 0..1 triples, the shape SetColorAndOpacity/SetFillColorAndOpacity accept.
    colors = {
        accent = { R = 1.0, G = 0.855, B = 0.0, A = 1.0 },
        accentShadow = { R = 0.788, G = 0.659, B = 0.0, A = 1.0 },
        champagne = { R = 1.0, G = 0.945, B = 0.702, A = 1.0 },
        steelGray = { R = 0.651, G = 0.651, B = 0.651, A = 1.0 },
        graphite = { R = 0.102, G = 0.102, B = 0.102, A = 1.0 },
        -- The hueless neutral for an input field's background: visibly lighter than the row's
        -- graphite base so a text box reads as a box. A box in the row's own shade was
        -- invisible (2026-09-02).
        -- Raised #2E2E2E: the design system's text-field fill and a toggle's OFF segment,
        -- as drawn in the 2026-09-03 mockup this page was built to.
        field = { R = 0.180, G = 0.180, B = 0.180, A = 1.0 },
        -- Hairline #333333: borders of a secondary button.
        hairline = { R = 0.2, G = 0.2, B = 0.2, A = 1.0 },
        -- Alert Amber #FFB000: the one danger fill (Delete), black caption, confirmation step.
        amber = { R = 1.0, G = 0.69, B = 0.0, A = 1.0 },
        -- Obsidian Black: text on a gold or amber fill.
        black = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 },
        transparent = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 },
    },
    -- Children the object dump exposes on each row widget (build 24575825, 2026-09-01).
    frameBase = "Base",
    frameLabel = "BP_PalTextBlock_Name",
    switchOn = { "Active_On", "BaseLine_On" },
    -- The OFF segment's images (PalWidgetDump of WBP_OptionSettings_ListContentSwitch,
    -- 2026-09-03: both variables, both tinted the game's blue; design system backlog item 17).
    switchOff = { "Active_Off", "BaseLine_Off" },
    -- The two captions inside the switch (same dump): ON sits on the gold fill and must be
    -- black; white on gold is unreadable.
    switchCaptions = { on = "BP_PalTextBlock_C", off = "BP_PalTextBlock_C_41" },
    -- The slider child's USlider (dump, 2026-09-03: variable "Slider"); SetSliderHandleColor
    -- takes a plain FLinearColor like SetColorAndOpacity does.
    sliderHandle = "Slider",
    -- WBP_OptionSettings_MenuButton_C children (dump, 2026-09-03). Only BP_PalTextBlock_Name is
    -- a variable; the others are reached through GetWidgetFromName(FName), the call four
    -- installed mods make live on this build (BondalotLoadingScreen logs its success).
    menuButton = {
        label = "BP_PalTextBlock_Name",
        base = "Base",
        frame = "Frame",
        focusFrame = "FocusFrame",
        tabEffects = "Tab_Eff_t",
        canvas = "CanvasPanel_37",
    },
    -- The switch's hover frames (dump, 2026-09-03: not variables, game blue), reached through
    -- GetWidgetFromName on the switch child and tinted gold.
    switchHover = { "Frame", "Frame_1", "FrameFlare", "FrameFlare_1" },
    -- The slider track is the ProgressBar style's background brush (dump: light blue, alpha
    -- 0.3); tinted hairline through the same copy-mutate-write of WidgetStyle that styleTextBox
    -- proved live on EditableTextBox.
    sliderTrack = "ProgressBar",
    -- Every text this mod builds (sections, notices, strip lines, menu button captions) takes
    -- the font of a live 14 pt label on the options screen (dump: BP_PalTextBlock_Default, a
    -- variable; row labels are the same 14 pt, menu buttons 18), copied verbatim with
    -- SetFont(reference.Font), the form NativeModOptions proved on this build (Config.ui.style
    -- textBlockFont). Never a mutated copy: that form aborted the game. `copyFont`
    -- is the one switch to turn it off should a build refuse it.
    copyFont = true,
    fontReference = "BP_PalTextBlock_Default",
    -- The arrow texture the game draws in its own menus, drawn as an Image for the strip's
    -- chevron, the back row's arrow and a row's trailing chevron. Angles assume the texture
    -- points right; wrong by a rotation is one config change.
    icon = {
        texturePath = "/Game/Pal/Texture/UI/IngameMenu/T_prt_arrow_0",
        textureObject = "/Game/Pal/Texture/UI/IngameMenu/T_prt_arrow_0.T_prt_arrow_0",
        width = 12, height = 18,
        angleRight = 0, angleDown = 90, angleLeft = 180,
    },
    -- A row's secondary note (a mod's setting count, a request count) sits after the label in
    -- steel gray: label origin plus the label's estimated width at the 14 pt label size, which
    -- is about 0.67 of the strip estimate (measured 2026-09-03 14:52: "Resource Respawn Test
    -- Enabled", 29 characters, 319 units).
    rowLabelOriginX = 25,
    rowNoteGap = 12,
    -- The note's own slot. A 0x0 slot cannot offset by its content's desired size, so the text
    -- ran off the row's right edge and only its first characters showed (2026-09-04). Wide
    -- enough for the longest note, the copy request's "N settings still lack a description or
    -- entries"; the text is right-justified, so the unused left part of the slot is empty and a
    -- short count still sits at the right edge.
    rowNoteWidth = 620,
    rowNoteHeight = 40,
    rowIconInset = 24,
    sliderFill = "ProgressBar",
    sliderValueText = "BP_PalTextBlock_Value",
    -- The slider child's layout, read from the pak (WBP_OptionSettings_ListContentSlider,
    -- build 24575825, exported 2026-09-02 with a widget dump): the child is 500x42,
    -- right-anchored in the row; the value text's canvas slot is anchored left at x=14,
    -- auto-sized, growing rightward; the bar canvas starts at x=72 and is 380 wide. So the
    -- number has 58px before it runs onto the bar, and a widened, right-justified auto-size
    -- box (the 2026-09-01 fix) put it there. The fix is a fixed slot ending where the bar
    -- begins, right-justified. A 2026-09-02 pass moved the number a further 56px left of that
    -- first placement (x = -56), so the box now ends 56px before the bar.
    valueTextSlot = { x = -112, y = 0, w = 128, h = 28 },
}

-- =========================== Frameworks ===========================

-- Findings read from the two opt-in mod-options frameworks' own working source on the reference
-- install, game build 24575825, 2026-09-01; treat as findings a framework update can invalidate.
Config.frameworks = {}

-- Seen in game, 2026-09-01: a single one-shot re-check was not enough, because both frameworks
-- re-assert their own button on their own hooks/re-shows after ours hides it, so the button
-- reappears later than any one delayed re-check catches. Replaced with a bounded poll per live
-- instance: the first `#pollScheduleMs` re-checks land at the listed offsets AFTER THE TRIGGER
-- (a button hide attempt), then every `pollIntervalMs` after that while the instance is still
-- alive, up to `pollCap` total polls. Both the NativeModOptions options-screen path and the
-- PalModOptions ESC-menu path share this schedule.
Config.frameworks.pollScheduleMs = { 250, 750, 1500, 3000 }
Config.frameworks.pollIntervalMs = 2000

-- Whether a framework's button is hidden even when its coverage could not be confirmed complete.
-- True, and it now governs BOTH screens: PalModOptions on the ESC menu and NativeModOptions on
-- the options screen.
--
-- Every way of confirming coverage has now failed on a real install, each for its own reason,
-- and each time the visible result was two buttons that open mod settings. PalModOptions is
-- judged from a live consumer registry read through `ModRef:GetSharedVariable`, whose surface
-- differs between UE4SS builds, so a read that worked yesterday returns nothing after a UE4SS
-- update (2026-09-04). NativeModOptions is judged from the boot scan's saved-value FILE
-- coverage, and a framework nobody has saved a value through yet has no such files at all: on
-- one real install its whole folder is 23 Scripts/*.lua and nothing else, so coverage was nil,
-- the gate read false, and the matcher returned before it ever looked at a button - no hide, and
-- no anomaly log either, since both sat behind the gate. The duplicate button came back a second
-- time on that install (2026-09-04), and only one thing may surface mod configuration.
--
-- An absent confirmation is therefore treated as what it is - an absent confirmation, not
-- evidence of a gap. Nothing is lost silently: an unconfirmed verdict is logged with the
-- consumers involved, so a mod whose settings this mod does not cover is recorded, not hidden.
-- Set false to keep a framework's button whenever its coverage cannot be positively confirmed.
Config.frameworks.hideFrameworkButtonWhenUnconfirmed = true
Config.frameworks.pollCap = 120

-- Found in game on 2026-09-01: a freshly constructed WBP_MenuESC_C reads as not-visible for
-- roughly its first 750ms while its own open animation plays, which sits squarely inside the
-- poll schedule above (the 750ms poll landed exactly on that window). The
-- two-consecutive-invisible stop rule (isPalModOptionsAlive in inject.lua) was treating that
-- transitional reading as real evidence the menu had closed, ending the chain before PalModOptions'
-- own button injection (observed ~500ms after Construct) was ever re-checked - so the "hid" log
-- never fired and, since the chain never reached a poll where the button was even present,
-- neither did the "was not found" anomaly log. The visibility signal is now ignored entirely
-- for the whole scheduled phase (the first #pollScheduleMs polls) PLUS this many further
-- steady-state polls once the schedule is exhausted, so an animation-timing edge never gets
-- mistaken for a genuinely closed menu. IsValid stays the hard stop throughout; this only widens
-- the window before the softer visibility signal is trusted.
Config.frameworks.pollVisibilityGracePolls = 2

-- PalModOptions 0.1.15. Source read: PalModOptions\Scripts\main.lua (the framework, all of
-- publish_values/discover_mods/shared_get/shared_set) and PalModOptions\Scripts\
-- PalModOptionsClient.lua (the consumer bridge; identical copy found in AlphaLuckyPalSurgery and
-- HUDLocator). Confirmed against a live registration call in AlphaLuckyPalSurgery\Scripts\
-- alpha_lucky_options.lua.
--
-- Unlike NativeModOptions, PalModOptions DOES publish a schema and its live values back over
-- shared variables after registration completes, under session-scoped keys a third party can
-- read with no registration handshake of its own. The reader for this framework is a plain
-- poll: read Session, then Registry.<session> for the id list, then Manifest.<session>.<id> and
-- Values.<session>.<id> per id.
Config.frameworks.palModOptions = {
    prefix = "PalModOptions.V1.",

    -- All keys below are ModRef:GetSharedVariable/SetSharedVariable names, written with the
    -- prefix above prepended (main.lua's shared_get/shared_set do this).
    sharedKeys = {
        -- Framework identity and readiness, set once at PalModOptions boot (main.lua lines
        -- 166-172). A reader must see FrameworkVersion/ApiVersion/ConfigDirectory non-nil and
        -- Session non-empty before trusting anything else.
        session = "Session",                    -- current session id string, built by main.lua line 161-165 as
                                                 -- string.format("%d_%s", os.time(), tostring({}):gsub("[^%w]", ""))
        apiVersion = "ApiVersion",               -- number, 1 on this build
        frameworkVersion = "FrameworkVersion",   -- string, "0.1.15" on this build
        configDirectory = "ConfigDirectory",     -- string, PalModOptions\config (per-consumer INI dir)
        captureActive = "CaptureActive",         -- boolean, true while a keybind row is capturing input

        -- The registration handshake a consumer uses BEFORE a session exists yet, or when its
        -- session has changed underneath it (client.register_when_ready in PalModOptionsClient.lua).
        -- "PendingRegistry" is a newline-separated list of ids, and the name is shared: it
        -- matches NativeModOptions' own key name for the same list exactly.
        pendingRegistry = "PendingRegistry",           -- newline-joined consumer ids awaiting pickup
        pendingManifestPrefix = "PendingManifest.",    -- + <id> -> that id's schema, JSON-encoded

        -- The CONFIRMED, session-scoped publication a reader consumes. Written by
        -- discover_mods() when it drains PendingRegistry/PendingManifest (main.lua lines 668-743),
        -- and again by publish_values() after every consumer registration and every settings apply
        -- (main.lua lines 647-666, 731, 1761).
        registryPrefix = "Registry.",           -- + <session> -> newline-joined ids registered THIS session
        manifestPrefix = "Manifest.",           -- + <session> "." <id> -> that id's schema, JSON-encoded
        valuesPrefix = "Values.",               -- + <session> "." <id> -> that id's CURRENT values, JSON-encoded flat map
        generationPrefix = "Generation.",       -- + <session> "." <id> -> integer, incremented each time values are re-applied
    },

    -- Registration handshake, exactly as PalModOptionsClient.lua performs it (queue_pending_schema,
    -- register_prepared): a consumer writes its schema JSON to
    -- "PalModOptions.V1.PendingManifest.<id>", then appends <id> to
    -- "PalModOptions.V1.PendingRegistry" (newline-joined, de-duplicated) if not already present.
    -- PalModOptions' own discover_mods() (main.lua lines 668-743, runs every ESC-menu Construct)
    -- drains PendingRegistry entirely on each pass: every id is moved into
    -- "Registry.<session>", its schema copied to "Manifest.<session>.<id>", and both
    -- "PendingManifest.<id>" and the whole "PendingRegistry" string are cleared to "" (main.lua
    -- lines 689-694). This differs from NativeModOptions, whose registry.lua reads
    -- PendingRegistry/PendingManifest.<id> but never clears either: the two frameworks share the
    -- SAME pending-handshake key names, but PalModOptions treats the pending keys as a one-shot
    -- mailbox while NativeModOptions treats them as a queue it merely drains from a separate copy.

    -- Schema JSON shape (the exact table normalize_schema in main.lua accepts, and the exact
    -- table AlphaLuckyPalSurgery's alpha_lucky_options.lua builds and hands to client.register /
    -- client.register_when_ready). This is the shape a reader must parse out of
    -- Manifest.<session>.<id> (equivalently PendingManifest.<id>).
    schemaShape = {
        api = "number, must equal apiVersion above (1 on this build) or the schema is rejected",
        id = "string, 1-64 chars of [A-Za-z0-9_.-], must equal the registry id the schema was filed under",
        title = "string, plain-text display name; falls back to id",
        titles = "optional table, i18n.localized()-shaped: language code -> localized title",
        description = "string, optional",
        descriptions = "optional table, i18n.localized()-shaped, same as titles",
        version = "integer >= 1, schema/settings-file version (bumping it does not migrate values)",
        apply_mode = '"event" (default) | "restart_mod" (calls RestartMod(mod_folder)) | "game_restart"',
        mod_folder = "string, defaults to id; used as the RestartMod() target for restart_mod",
        appearance = "optional table: text_color/button_text_color/input_text_color/input_background_color, each a #RRGGBB hex string",
        options = "array (1-128 entries) of option tables, shape below",
        initial_values = "optional table: option key -> value, seeds values on first-ever registration only",
        constraints = "optional array (0-32 entries) of cross-option validation rules, shape below",
    },

    -- One entry of schema.options[]. type = "section" is a label-only divider row (no key
    -- required beyond a generated one, no value, no default).
    optionShape = {
        key = "string, 1-64 chars of [A-Za-z0-9_.-], unique within the schema",
        type = '"boolean" | "integer" | "number" | "text" | "enum" | "keybind" | "section"',
        label = "string, plain-text row label; falls back to key",
        labels = "optional table, i18n.localized()-shaped",
        description = "string, optional row description shown under the label",
        descriptions = "optional table, i18n.localized()-shaped",
        disabled = "boolean, renders the row read-only",
        appearance = "optional table, same 4 color fields as schema.appearance, overrides it per row",
        default = "required for every non-section type; must satisfy the type's own validation below or the whole schema is rejected",
        -- integer / number only:
        minimum = "number, optional",
        maximum = "number, optional",
        step = "number > 0, optional; values are rounded to the nearest step from minimum (or 0)",
        -- text only:
        max_length = "integer, 1-256, defaults to 128",
        hint = "string, placeholder text",
        -- enum only:
        choices = "array (1-64 entries) of { value = string, label = string, labels = optional table }",
    },

    -- One entry of schema.constraints[]. left/right are option keys; both options' defaults
    -- must be numeric for the ordered operators (lt/lte/gt/gte); neq works on any type.
    constraintShape = {
        type = '"lt" | "lte" | "gt" | "gte" | "neq"',
        left = "string, an option key in the same schema",
        right = "string, an option key in the same schema",
        message = "string, shown when the constraint fails",
        messages = "optional table, i18n.localized()-shaped",
    },

    -- Values JSON shape at Values.<session>.<id>: a flat table of option key -> current value,
    -- one entry per non-section option (main.lua's publish_values/default_values). No wrapper,
    -- no metadata; decode with the framework's own pmo_json and read keys directly.

    -- Per-consumer saved-settings INI, one file per schema.id at
    -- "<ConfigDirectory>\<id>.ini" (main.lua's config_path/save_values). Confirmed from
    -- save_values (main.lua lines 612-645):
    --   line 1: "# Mod Options Framework API 1"
    --   line 2: "# <schema.id> schema <schema.version>"
    --   then one "<option.key>=<json-encoded value>" line per non-section option.
    -- Save mechanism, confirmed from the same function: write to "<path>.tmp", flush and close,
    -- delete any stale "<path>.bak", rename the existing "<path>" (if present) to "<path>.bak",
    -- then rename "<path>.tmp" to "<path>"; on a rename failure the .bak is restored and the .tmp
    -- is removed, so the previous file is never lost. This matches the tmp+backup+rename
    -- mechanism previously observed and is now confirmed from source.
    valuesFileHeaderLines = 2,
}

-- Category-button identity findings, read from source (no live deploy), game build 24575825,
-- 2026-09-01, for a matcher over the sibling buttons inject.lua:categorySiblingAddresses
-- already enumerates in WBP_OptionSettings_C's button container. Source read:
-- NativeModOptions\Scripts\inject_options.lua (the whole button lifecycle: MENU_BUTTON_CLASS,
-- LABEL, relabel(), inject()) and PalModOptions\Scripts\main.lua (PMO.esc_menu_class,
-- PMO.esc_button_class, inject(), lines 1968-2107) plus PalModOptions\Scripts\localization.lua
-- (the "mod_options" English string).
Config.frameworks.buttonIdentity = {
    nativeModOptions = {
        -- Exactly ONE button/page per WBP_OptionSettings_C screen instance, shared by every
        -- registered consumer mod -- confirmed from inject_options.lua's own idempotency guard:
        -- `injected[address]` short-circuits inject() on a second call for the same screen
        -- (line 535-537), and buildScreenState() is only ever invoked once per screen
        -- (line 578). All of a session's consumer settings render as rows inside that one page
        -- (PanelBuild.build aggregates every registered mod), not as separate buttons.
        buttonCountPerScreen = "exactly one, shared by all consumers (not one per consumer)",

        -- The button IS a real WBP_OptionSettings_MenuButton_C instance, constructed the exact
        -- same way this mod's own inject.lua builds ITS button: `Widgets.createUserWidget(
        -- instance, MENU_BUTTON_CLASS, MENU_BUTTON_ASSET)` where MENU_BUTTON_CLASS is
        -- "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/WBP_OptionSettings_MenuButton
        -- .WBP_OptionSettings_MenuButton_C" (inject_options.lua lines 24-25) -- identical string
        -- to this mod's own Config.ui.menuButtonAsset. It is added to the SAME buttonContainer
        -- this mod's categorySiblingAddresses walks (inject_options.lua lines 546-575:
        -- `anchorButton = instance.WBP_OptionSettings_MenuButton_Graphic`, then
        -- `buttonContainer = anchorButton:GetParent()`, then
        -- `buttonContainer:AddChildToHorizontalBox(ourButton)` etc -- the same anchor-and-walk
        -- this mod's own inject() uses). CLASS PATH ALONE CANNOT IDENTIFY IT: it is the same
        -- widget class as this mod's own button and (per WBP_OptionSettings_MenuButton_Graphic
        -- etc) plausibly vanilla's five real category buttons too.
        widgetClass = "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Option/"
            .. "WBP_OptionSettings_MenuButton.WBP_OptionSettings_MenuButton_C -- SAME class as "
            .. "this mod's own button; not a distinguishing signal by itself",

        -- The ONE reliable static signal: a hardcoded English literal caption, never localized.
        -- `local LABEL = "Mod Options"` (inject_options.lua line 32); relabel() sets it via
        -- `button.BP_PalTextBlock_Name:SetText(FText(LABEL))` (line 85) -- the exact same field
        -- name (BP_PalTextBlock_Name) this mod's own relabel() uses for "Mod Configs"
        -- (inject.lua line 50). Because LABEL is a plain Lua string constant with no i18n table
        -- anywhere in inject_options.lua, the caption reads "Mod Options" regardless of the
        -- player's game language.
        captionField = "BP_PalTextBlock_Name",
        captionLiteral = "Mod Options",
        matcher = "for each candidate in categorySiblingAddresses (or buttonContainer's raw "
            .. "children), pcall(function() return candidate.BP_PalTextBlock_Name:GetText():"
            .. "ToString() end) and compare the result to the literal string 'Mod Options' "
            .. "(exact match, case-sensitive) -- distinct from this mod's own 'Mod Configs' "
            .. "and from vanilla's five real captions (Graphic/Sound/Game/Key/Other, localized)",

        -- The scanner.lua/config.lua key this framework's saved-value files are tagged with
        -- (Config.frameworkPathPatterns above, and model.frameworkCoverage's key in Scanner.scan) --
        -- the gate that decides "fully absorbed".
        frameworkSource = "framework:nativemodoptions",
    },

    -- SURPRISE FINDING, and the reason this block exists: PalModOptions never touches
    -- WBP_OptionSettings_C at all. Its `option_settings_asset`/`option_settings_class` fields
    -- (main.lua lines 27, 31) exist ONLY to read the vanilla background image for its own
    -- ultrawide layout (line 2052-2053: `StaticFindObject(PMO.option_settings_class ..
    -- ":WidgetTree.Image_238")`); its actual injection target is a DIFFERENT screen entirely --
    -- `esc_menu_class = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC
    -- .WBP_MenuESC_C"` (line 25), hooked via `NotifyOnNewObject(PMO.esc_menu_class, ...)`
    -- (line 2148) and `RegisterHook(PMO.esc_menu_function .. "Construct", ...)` (line 1873).
    -- Its one button is `PMO.esc_button_class` = "/Game/Pal/Blueprint/UI/UserInterface/
    -- ESCMenu/WBP_MenuESC_Button.WBP_MenuESC_Button_C" (lines 26, 30) -- a wholly different
    -- Blueprint asset than WBP_OptionSettings_MenuButton -- inserted into the ESC menu's own
    -- button VerticalBox (`find_widget(menu, "VerticalBox_91")`, line 1979) directly after the
    -- vanilla "Option" button (`menu.WBP_MenuESC_Button_Option`, line 1986), via
    -- `insert_vertical_after(first_group, option_button, state.entry_button)` (line 2042).
    -- Clicking it opens PalModOptions' own hand-drawn CanvasPanel UI (render_mod_list /
    -- render_option_page: raw TextBlock/EditableTextBox/button widgets positioned by explicit
    -- x/y coordinates), never the options screen's category-button/ScrollBox system at all.
    palModOptions = {
        buttonCountPerScreen = "one, on the ESC menu, not on WBP_OptionSettings_C at all -- "
            .. "the whole premise of a per-consumer-vs-shared count on the options screen does "
            .. "not apply",
        widgetClass = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC_Button."
            .. "WBP_MenuESC_Button_C -- a different asset than WBP_OptionSettings_MenuButton",
        injectionTarget = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC."
            .. "WBP_MenuESC_C, inserted into its VerticalBox_91 button group -- NOT "
            .. "WBP_OptionSettings_C's category-button container",
        captionLiteral = "Mod Options (localization.lua's \"mod_options\" key, English) -- "
            .. "same English text as NativeModOptions coincidentally, but irrelevant on ITS OWN "
            .. "for a matcher: this button structurally cannot appear in WBP_OptionSettings_C's "
            .. "button container or in categorySiblingAddresses' results, on any build, under "
            .. "this architecture; hiding it needs a wholly separate matcher on its own screen "
            .. "(below), which this mod implements",

        -- Update, 2026-09-01: a matcher IS implemented, on WBP_MenuESC_C, not on
        -- WBP_OptionSettings_C (the earlier "matcherNeeded: none" verdict addressed only the
        -- options screen and is superseded by the fields below). Reaching PalModOptions' button
        -- without a recursive tree walk: PalModOptions.main.lua does NOT read VerticalBox_91
        -- through a raw field access (it uses its own recursive find_widget(), lines 745-794,
        -- which walks the FULL widget tree including nested WidgetTree.RootWidget hops -- exactly
        -- the pattern NativeModOptions\Scripts\native_style.lua's header comment warns is unsafe:
        -- "a recursive walk of these pages crashes the game natively, uncatchably"). Copying
        -- find_widget() is therefore not adopted here. Instead, PalModOptions' OWN button is
        -- inserted as the sibling immediately after vanilla's own "Option" button in that same
        -- VerticalBox (`option_button = menu.WBP_MenuESC_Button_Option`, main.lua line 1986;
        -- `insert_vertical_after(first_group, option_button, state.entry_button)`, line 2042) --
        -- and `menu.WBP_MenuESC_Button_Option` is a plain reflected field read requiring no walk
        -- at all, exactly the same anchor-and-GetParent() idiom this mod's own inject.lua and
        -- NativeModOptions both already use for THEIR button containers. Reading
        -- `menu.WBP_MenuESC_Button_Option:GetParent()` reaches the identical VerticalBox_91
        -- container find_widget() locates, in one field access and one GetParent() call.
        anchorField = "WBP_MenuESC_Button_Option",

        -- Why the exclusion list below exists (2026-09-01): the caption+class matcher
        -- alone cannot rule out a coincidental caption collision with one of vanilla's OWN
        -- ESC-menu buttons, which plausibly share the same WBP_MenuESC_Button_C class. Vanilla's
        -- own buttons are the menu's own NAMED widget fields (the same pattern
        -- `WBP_MenuESC_Button_Option` already is), so excluding every field name in this list
        -- before caption matching removes any vanilla button from consideration regardless of
        -- what its localized caption happens to read.
        --
        -- HONEST LIMIT: "WBP_MenuESC_Button_Option" (main.lua line 1986) is the ONLY vanilla
        -- ESC-menu button field name found anywhere in either framework's source read for this
        -- mod. Neither framework's code ever names Palworld's other ESC-menu entries (Save,
        -- Return to Title, Exit, etc.), so this list is a documented PARTIAL roster, not a
        -- complete one -- inventing the missing names without a live read would be exactly the
        -- kind of unverified symbol this project's discovery discipline forbids. Residual risk
        -- carried forward: an unlisted vanilla ESC button of the same class whose localized
        -- caption happens to match one of captionLiterals below, in some language, would still
        -- be misidentified and hidden. Judged low-probability (a coincidental phrase collision
        -- across a small, unrelated caption set) but not eliminated; a live property dump of a
        -- real WBP_MenuESC_C instance (out of scope here, no live deploy performed) is the only
        -- way to complete this roster and close the gap for good.
        vanillaStockButtonFields = { "WBP_MenuESC_Button_Option" },

        -- The short class name (child:GetClass():GetFName():ToString(), the exact idiom
        -- NativeModOptions\Scripts\native_style.lua uses at lines 32 and 86) every genuine
        -- PalModOptions ESC-menu button reports; PMO.esc_button_class = ".../WBP_MenuESC_Button.
        -- WBP_MenuESC_Button_C" (main.lua lines 26, 30) -- GetFName() returns the trailing
        -- "WBP_MenuESC_Button_C" segment only, not the full asset path.
        buttonClassName = "WBP_MenuESC_Button_C",

        -- The button's caption field, confirmed from main.lua's set_button_text() (lines
        -- 1064-1070): `button.Text_Main:SetText(FText(tostring(text or "")))`, and create_button()
        -- (lines 1095-1129), which also reads back `button.Text_Main` directly. Read with
        -- `pcall(function() return button.Text_Main:GetText():ToString() end)`.
        captionField = "Text_Main",

        -- UNLIKE NativeModOptions' hardcoded English literal, PalModOptions' caption IS localized:
        -- inject() calls `set_button_text(state.entry_button, i18n.text("mod_options"))`
        -- (main.lua line 2041), and localization.lua carries a real per-language translations
        -- table (16 distinct strings covering 17 Palworld language codes -- es-ES and es-419
        -- share one string -- confirmed by reading every entry of the "mod_options" key, index 1
        -- of each language's `compact` array, localization.lua lines 11-182). A single-literal
        -- match would miss every non-English client, so the matcher below tests set membership
        -- instead of equality against one string. Keys are the caption text; values record which
        -- language(s) produce it, for traceability only (not read by the matcher).
        captionLiterals = {
            ["Mod Options"] = "en",
            ["模组选项"] = "zh-Hans",
            ["模組選項"] = "zh-Hant",
            ["MODオプション"] = "ja",
            ["Options des mods"] = "fr",
            ["Opzioni mod"] = "it",
            ["Mod-Optionen"] = "de",
            ["Opciones de mods"] = "es-ES, es-419",
            ["Opções de mods"] = "pt-BR",
            ["Настройки модов"] = "ru",
            ["모드 옵션"] = "ko",
            ["Opsi Mod"] = "id",
            ["ตัวเลือกม็อด"] = "th",
            ["Mod Seçenekleri"] = "tr",
            ["Tùy Chọn Mod"] = "vi",
            ["Opcje modów"] = "pl",
        },

        -- The screen this button lives on, corrected 2026-09-01 after a run in game: the
        -- original RegisterHook(escMenuClass .. ":Construct", ...) approach fails
        -- at boot with "no UFunction with the specified name was found", because WBP_MenuESC_C
        -- is not loaded yet when Inject.install() runs. installEscMenuHook now uses
        -- NotifyOnNewObject(escMenuClass, ...) instead -- the same mechanism PalModOptions
        -- itself uses to watch for this class (main.lua line 2148), and the same idiom this
        -- mod's own Inject.install() already uses for WBP_OptionSettings_C. PalModOptions' own
        -- install_construct_hook() (main.lua lines 1868-1887) still drives its ENTIRE
        -- re-injection cycle every ESC-menu open from its own Construct hook, so this mod needs
        -- no separate OnSetup/OpenPanel-style re-trigger of its own; NotifyOnNewObject alone
        -- catches every fresh WBP_MenuESC_C instance.
        escMenuClass = "/Game/Pal/Blueprint/UI/UserInterface/ESCMenu/WBP_MenuESC.WBP_MenuESC_C",

        -- Added 2026-09-01, and the reason the poll matters here: RegisterHook order
        -- between this mod's Construct hook and PalModOptions' own (both on the same
        -- WBP_MenuESC_C:Construct) is not guaranteed. If ours runs first, PalModOptions' button
        -- has not been inserted into VerticalBox_91 yet and the first pass finds zero
        -- candidates. The bounded poll (Config.frameworks.pollScheduleMs/pollIntervalMs/pollCap
        -- above, also used by the NativeModOptions options-screen path) catches that ordering
        -- either way, and keeps re-hiding the button for as long as PalModOptions keeps
        -- re-asserting it.

        -- Same coverage key convention as nativeModOptions above.
        frameworkSource = "framework:palmodoptions",
    },
}

-- Other config frameworks' own interfaces, suppressed unconditionally: with this mod installed,
-- exactly one thing on screen renders mod configuration, and that is deliberately NOT a
-- setting. Scripts/suppress.lua walks these by short class name through FindAllOf and
-- collapses every instance it finds.
--
-- DekModConfigMenu (Nexus 577) is the case this exists for. Unlike NativeModOptions and
-- PalModOptions, which inject a button into the game's own screens (Config.frameworks handles
-- those), it adds its own widget to the viewport: the "Mod Config" label and gear in the title
-- screen's top-right corner, plus the window its key opens. Short class names, not asset paths:
-- the pak's index spells the package two ways, so a path would be a guess.
Config.suppress = {
    classes = {
        "WBP_ConfigMenuTitleUI_C",   -- the title-screen entry the player clicks
        "WBP_ModConfigMenuUI_C",     -- the menu itself, in case its own key opens it
        "WBP_ModConfigWindow_C",     -- the window that menu is drawn inside
    },
    -- The title screen is not up at boot, so the first pass waits, then sweeps briskly while the
    -- opening flow settles before dropping to a slow steady cadence for the session.
    firstDelayMs = 3000,
    openingPasses = 20,
    openingIntervalMs = 1000,
    steadyIntervalMs = 5000,
    -- Nothing found by the end of the opening phase does NOT mean the framework is absent: its
    -- widget only exists while the title screen is up, and a player who loads straight into a
    -- world is past that in seconds (seen 2026-09-06: the sweep reported itself idle and the
    -- gear came back on the next visit to the title screen). So the fast phase ends and
    -- a slow watch continues instead of stopping. Looking costs a read and touches nothing; the
    -- watch ends for good the moment the class is found and hooked.
    giveUpAfterPasses = 40,
    idleIntervalMs = 30000,
}

-- Publishing a description request to a file host, so a player can paste one link into the
-- request thread instead of the file's contents. A whole-install request on an uncatalogued
-- 36-mod install measured 57,480 bytes against a roughly 8,000-character Steam discussion post
-- (2026-09-06), which is the problem this solves.
--
-- The transport is Microsoft's own curl.exe, already in System32 on Windows 10 1803 and later.
-- The endpoint lives here so switching hosts is one line: litterbox is catbox's self-expiring
-- sibling at https://litterbox.catbox.moe/resources/internals/api.php, which takes the same
-- reqtype and fileToUpload plus a `time` of 1h/12h/24h/72h.
Config.upload = {
    -- catbox.moe, authenticated with the mod author's own account hash. Catbox refuses an
    -- ANONYMOUS api.php upload outright ("Invalid uploader", reproduced 2026-09-06); with the
    -- hash it accepts, the link is permanent, and every file lands in one account the author
    -- can delete from. The hash ships inside the mod, which is a deliberate trade: the account
    -- exists for this and nothing else.
    endpoint = "https://catbox.moe/user/api.php",
    -- Where the manual walkthrough sends a player to drop the file in themselves.
    hostPage = "https://catbox.moe/",
    userhash = "46b5d4d3b158d1fbfbc7e17ad",
    -- litterbox, the self-expiring sibling, is the only other host in the family that takes an
    -- anonymous upload: https://litterbox.catbox.moe/resources/internals/api.php with a `time`
    -- of 1h/12h/24h/72h. Set `expiry` to use it; catbox itself ignores the field.
    expiry = nil,
    curlSuffix = "\\System32\\curl.exe",
    timeoutSeconds = 30,
    -- Written beside the list, read once, deleted. The command goes in a batch file rather
    -- than one long string: the string form posted with no file attached inside the game.
    replySuffix = ".reply.txt",
    scriptSuffix = ".upload.cmd",
    -- Every upload lands in one shared account, so a pathological file is refused rather than
    -- sent. A request list is kilobytes.
    maxBytes = 2 * 1024 * 1024,
    -- A host's refusal is shown on a row that does not wrap, so it is kept short enough to
    -- read rather than cut off (review, 2026-09-06).
    maxReplyChars = 60,
    -- What a success looks like. Anything else the host says is the failure to show the
    -- player. Covers both hosts in the family, since the endpoint above is switchable.
    replyPattern = "https://[%w%.%-]*catbox%.moe/[%w%._%-]+",
}

-- Where a player posts the list they just compiled. Both threads are this mod's own, named on
-- its store pages, and they are the ONLY URLs this mod ever opens.
Config.requestForums = {
    { key = "nexus", labelKey = "forum_nexus",
      url = "https://www.nexusmods.com/palworld/mods/5545/?tab=forum&topic_id=17329161" },
    { key = "steam", labelKey = "forum_steam",
      url = "https://steamcommunity.com/workshop/filedetails/discussion/3796426213/582807520276484621/" },
}

return Config
