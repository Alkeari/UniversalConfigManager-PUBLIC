#pragma once

#include <string>
#include <string_view>

namespace UpdateNotice::Strings
{
    // The notice template for a game language code ("ja", "pt-BR"): the exact code, else its base
    // language ("es-AR" uses "es"), else English. Holds {mod} and {version}.
    auto Template(std::wstring_view language) -> std::wstring_view;

    // "<mod> <version> is available." in that language.
    auto UpdateAvailable(std::wstring_view language, std::wstring_view modName, std::wstring_view version) -> std::wstring;
}
