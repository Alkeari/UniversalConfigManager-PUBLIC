Universal Config Manager
by Alkeari

Edit every installed UE4SS Lua mod's config from one "Mod Configs" tab in
Palworld's options menu (title screen and pause menu): switches, sliders,
dropdowns, and text boxes, saved back into each mod's own config file in
place. Descriptions show as tooltips, in all 17 languages the game ships.

Mods configured through "Mod Config Menu (UI)" appear here as well, with the
author's own descriptions, ranges and choices already filled in, whether that
mod keeps its .modconfig.json in its own folder or beside its pak in LogicMods.

The tab is fully usable with a controller: it opens focused, the D-pad
reaches every row and button, sliders adjust in the steps a setting is
actually written in, and free-form text opens an on-screen keyboard.
None of that shows on a mouse and keyboard.

Installed automatically by subscribing on the Steam Workshop; enable it in
Options -> Mod Management. Requires the "UE4SS Experimental (Palworld)"
Workshop item, which the loader enables as a dependency.

Where things live (inside this package's folder under Mods\NativeMods\UE4SS\Mods):
  presets\    Named sets of every setting, one .tsv file each. Copy a file in
              or out to share it; the Presets page shows the exact path.
  requests\   The lists Request Support compiles, naming settings that still
              lack a description. Upload one yourself, or let the tab upload it
              and copy the link, then post that link in the request thread.
              Nothing is uploaded unless you press Automated Uploading, and the
              list holds mod and setting names, never their values. The
              .upload.cmd beside a list is the exact command that was run, left
              there to be read rather than deleted.
  values.tsv  The values you set here. A mod update that resets its config gets
              them written back at the next launch.

A mod that re-reads its own config applies your change within seconds; any other mod's
settings take effect the next time it loads, so reload into your world after saving.
Client side only: it edits files on your own machine and changes nothing in a
world hosted by someone else.

License terms are in LICENSE.md in this folder.
