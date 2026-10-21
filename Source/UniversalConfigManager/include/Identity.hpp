#pragma once

#include <filesystem>
#include <string>
#include <string_view>

namespace UpdateNotice::Identity
{
    // The Lua mod this copy of the add-on ships inside, read from the Info.json that packaging
    // places beside the dll. Every field is empty when that file is missing or unreadable.
    struct Mod
    {
        std::string PackageName{};
        std::string ModName{};
        std::string Version{};
        // The feed name on alkeari.com/updates/: the display name in lower case with every run of
        // other characters turned into one hyphen ("Passive Pals" is "passive-pals").
        std::string Slug{};
    };

    auto ParseInfo(std::string_view infoJson) -> Mod;
    auto SlugOf(std::string_view modName) -> std::string;

    // Whether a Lua source turns the check off: an uncommented checkForUpdates = false, in any
    // letter case and under any table prefix (settings.checkForUpdates = false). True otherwise.
    auto SourceAllowsCheck(std::string_view luaSource) -> bool;

    // The folder holding Scripts\ and dlls\ for this copy.
    auto ModDirectory() -> std::filesystem::path;

    // Loaded once from dlls\Info.json on first use.
    auto Current() -> const Mod&;

    // "[PackageName]", the same tag the Lua half logs under, so one search finds both halves.
    auto Tag() -> const std::wstring&;

    // Reads every Scripts\*.lua of this mod now, so an edit made while the game runs counts.
    auto UpdatesEnabled() -> bool;
}
