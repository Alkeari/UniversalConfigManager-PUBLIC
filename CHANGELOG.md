# Changelog

## v1.4.0 - 2026-09-07

Added: the tab can be used with a controller. The button you are on is outlined, opening Mod Configs puts the controller on the page, and every row of buttons is stepped along with left and right.
Added: on a controller, a setting whose accepted values are known is picked from a list, free-form text opens an on-screen keyboard, and a dropdown opens its choices as rows you can move between.
Fixed: a slider could not be adjusted with a controller. Pressing A on the row now puts it into the game's own editing mode, where the D-pad moves the bar and B leaves again, one whole number per press for a whole-numbered setting and one decimal place for a setting written with decimals.
Fixed: after using this tab with a controller, Escape and B stopped leaving the settings screen for the rest of the session, on every tab, because rows this mod removed left input bindings on the screen behind them.
Fixed: moving onto a row with a text box trapped a controller inside it, with no way to type and no way back out; a text box is skipped when navigating with a controller now.
Fixed: the Mod Configs page had a second scrollbar of its own inside the options screen's, so the outer one barely moved and the wheel scrolled whichever the pointer happened to be over; the page now scrolls with the screen.
Fixed: a setting whose name is long no longer draws over the box, dropdown or slider at the right of its row, and on the Presets page a long preset name no longer pushes Load, Overwrite or Delete out of view.
Fixed: every slider adjusts in the interval its own setting is written in, instead of a step sized from its range: a scale written in hundredths no longer lands on 0.80525404214859, and a bar that took millions of presses to cross can now be crossed.
Changed: a config file's full path sits on the file's own header line with a Copy button at the end, replacing the separate folder line and a path box too narrow to read; on a controller the header is selected as a whole row that expands and collapses, and right reaches its Copy button.
Added: descriptions and a range for the setting that controls how often Passive Pals and Tidy Base Info re-read their own config, which had none.
Changed: none of the controller behavior shows on a mouse or keyboard, where the tab looks and behaves exactly as it did.

## v1.3.0 - 2026-09-06

Changed: editing a mod setting no longer raises the game's "a restart is required" prompt, which was wrong for the mods that reload with your world; your changes are saved when you leave the screen.
Added: that prompt still appears for a mod that is known to need a full game restart, and answering it saves or discards your changes.
Added: Save and Revert buttons on a mod's page for that mod, and on the first page for every mod, each appearing only while there is something to save.
Added: mods configured through Mod Config Menu (UI) appear in the tab with the author's own descriptions, ranges and choices, whether the setting sits in the mod's own folder or beside its pak in LogicMods.
Added: Restore to Default uses the author's declared default for those mods, rather than the first value seen.
Added: a Request Support page that compiles the list of settings still missing a description, and either walks you through uploading it yourself or uploads it for you and copies the link.
Added: the list can cover every mod or only the ones you pick, and both the list and its link are remembered so you can copy either again later.
Added: every setting description and list of accepted values is translated into all 16 other languages, so nothing in the tab falls back to English.
Fixed: an accepted value that is a long asset path no longer runs off the right edge of the Possible Entries strip, where it was cut and unreadable.
Changed: a config file's full path sits on the file's own header line with a Copy button at the end, replacing the separate folder line and a path box too narrow to read; a long setting name no longer draws over the control at the right of its row, and on the Presets page a long preset name no longer pushes Load, Overwrite or Delete out of view.
Fixed: the per-value notes under a dropdown now appear in Japanese, Korean and both Chinese, which write a note without a space before the bracket, and a setting whose author published its list of choices is a dropdown wherever that list came from.
Fixed: 44 catalog entries that broke the house wording rules, including a list that named two of its choices twice.

## v1.2.2 - 2026-09-06

Fixed: hotkey and command settings are asked about again when their accepted values are unknown, after a change meant to stop pointless questions silenced almost every question.
Fixed: a setting whose name says it takes a choice is asked about wherever it lives, instead of being written off because of the file around it.
Fixed: a long column of one-off labels is no longer offered as a list of accepted values because two of them happened to match.
Fixed: a setting whose name carries a player id stays editable, and is only left out of description requests.

## v1.2.1 - 2026-09-06

Fixed: a hotkey list no longer suggests mouse buttons, which cannot be bound safely.
Fixed: settings that share a name across two of a mod's files are described one file at a time, instead of one sentence that was half right on each.
Changed: descriptions that could not be checked against anything the mod's author published are marked as inferred.

## v1.2.0 - 2026-09-06

Added: descriptions for 681 more settings across 28 mods, from the first player-sent request, written from each mod's own page on the Steam Workshop, Nexus Mods or CurseForge.
Added: the accepted values for 39 more settings, where the author publishes the list.
Fixed: a setting whose value is a free-form label is no longer reported as missing its accepted values, which asked players for a list that cannot exist.
Added: a setting repeated through one file takes its accepted values from the other rows in that file, so a list you already have is never asked for.
Fixed: a request for a mod the Steam loader did not install now points at Nexus Mods and CurseForge instead of calling its Workshop id unknown.
Added: a config that documents a setting in a sibling key, such as "_maxRadius" describing "maxRadius", shows the author's own words as that setting's description.
Fixed: keys that are documentation, a config format number, or one player's saved row are no longer offered as editable settings.

## v1.1.0 - 2026-09-05

Changed: a mod that re-reads its own config no longer carries the "changes apply after the game is relaunched" notice, because for those mods it was not true.
Added: each mod's page says whether its settings take effect immediately or when the mod next loads.

## v1.0.0 - 2026-09-05

Added: a Mod Configs tab in the game's options menu, opened from the options screen or from a new button on the pause (ESC) menu, with a clickable list of the mods running this session, one page per mod, Q/E paging, and every word in the game's own language for all 17 languages Palworld ships.
Added: every value edits as the control it really is - switches for booleans and flags, sliders for numbers with the exact value typeable beside the bar, a real dropdown for documented choice lists of words or numbers, an editable text box for free-form strings and hotkeys, and read-only text for anything else.
Added: an Advanced Mode switch that also shows a mod's code-side options, minus anything its real config already exposes.
Added: each setting's description shows as a hover tooltip, from a curated catalog written for every setting of the popular mods (marked "(?)" when read from code rather than the author's words) or from the config author's own English comment, with a prompt to notify Alkeari when neither exists.
Added: edits save through the game's own apply prompt and write into each mod's config file in place, preserving comments, and Restore to Default stages a mod's own example config values when one exists, otherwise the setting's value from before any edits made here; changes apply when that mod next loads.
Added: sliders take their range from real evidence in the config's comments or the mod's own code before falling back to the value's magnitude, and values set here are authoritative - a mod update that resets its config gets your values written back at the next launch.
Added: the tab follows the Alkeari design: gold accents, raised gray OFF switches, gold section titles, and the game's own arrow for chevrons; a row holding a folder path reads "Click to Copy" and copies it when clicked.
Added: a Search box filters the mod list by name, a Presets page saves, loads, overwrites, and deletes named sets of every setting - one row per preset, shareable as plain files - and a Copy request button writes the settings that still lack a description or accepted values to a text file you can send to Alkeari.
Added: a "Possible Entries" line opens in place into everything a setting accepts, with a filter box inside - under every text box, and under a dropdown whose values carry an explanation of what each one does; inferred entries end with "(?)".
Changed: another mod-options framework's own button is hidden on both the settings screen and the pause menu, so mod settings are never offered from two places at once.
Fixed: Backspace in a text box no longer closes the options screen, and a setting exposed by both an ini file and a config.lua is listed once, from the ini.
Fixed: a mod whose only real config is config.lua no longer loses it to another same-named file, a slider's value text no longer overlaps the bar, translation tables and mod name records are no longer listed as settings, a config file after a subfolder is no longer skipped on the Steam Workshop UE4SS build, the tab appears on an Options screen that was already open when the mod finished loading, and a mod that keeps its config outside the Mods folder (beside the game executable, or under Pal\Saved) now shows its settings instead of nothing.
