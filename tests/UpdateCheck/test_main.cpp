#include <Identity.hpp>
#include <Strings.hpp>
#include <Update.hpp>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

using namespace UpdateNotice;

namespace
{
    int g_failures = 0;

    auto Check(bool condition, const std::string& description) -> void
    {
        std::printf("  %s: %s\n", condition ? "PASS" : "FAIL", description.c_str());
        if (!condition)
        {
            ++g_failures;
        }
    }

    auto ReadFile(const std::filesystem::path& path) -> std::string
    {
        std::ifstream in(path, std::ios::binary);
        std::stringstream buffer;
        buffer << in.rdbuf();
        return buffer.str();
    }
}

// Arguments: the Palworld Mods category folder, then a saved copy of one live feed and the
// version that feed's newest line carries.
int main(int argc, char** argv)
{
    if (argc != 4)
    {
        std::printf("usage: UpdateNoticeTests <Palworld Mods folder> <feed.json> <feed's newest version>\n");
        return 2;
    }

    std::printf("Slugs\n");
    Check(Identity::SlugOf("Passive Pals") == "passive-pals", "Passive Pals");
    Check(Identity::SlugOf("Co-Op  Thing!") == "co-op-thing", "punctuation and double spaces collapse to one hyphen");
    Check(Identity::SlugOf("") == "", "empty name");

    std::printf("Every Lua mod's Info.json\n");
    int luaMods = 0;
    for (const auto& entry : std::filesystem::directory_iterator(argv[1]))
    {
        const auto info = entry.path() / "Info.json";
        if (!std::filesystem::exists(entry.path() / "Scripts" / "main.lua") || !std::filesystem::exists(info))
        {
            continue;
        }
        ++luaMods;
        const auto mod = Identity::ParseInfo(ReadFile(info));
        const auto name = entry.path().filename().string();
        Check(!mod.PackageName.empty() && !mod.Version.empty() && mod.ModName == name, name + ": PackageName, Version and ModName read");
        Check(mod.Slug == Identity::SlugOf(name), name + ": slug " + mod.Slug);
    }
    Check(luaMods > 0, "found Lua mods");

    std::printf("checkForUpdates in Lua sources\n");
    Check(Identity::SourceAllowsCheck(""), "absent means on");
    Check(Identity::SourceAllowsCheck("checkForUpdates = true\n"), "true");
    Check(!Identity::SourceAllowsCheck("checkForUpdates = false\n"), "false");
    Check(!Identity::SourceAllowsCheck("local s = {}\r\n    settings.CheckForUpdates=false, -- off\r\n"), "table prefix, CRLF, no spaces, trailing comma and comment");
    Check(Identity::SourceAllowsCheck("-- checkForUpdates = false\n"), "commented out");
    Check(Identity::SourceAllowsCheck("checkForUpdates = falsey\n"), "a longer word is not false");
    Check(Identity::SourceAllowsCheck("checkForUpdates == false\n"), "a comparison is not an assignment");
    Check(Identity::SourceAllowsCheck("noCheckForUpdates = false\n"), "another key that ends the same");

    std::printf("Notice text\n");
    const char* languages[] = {"de", "en", "es-MX", "es", "fr", "id", "it", "ja", "ko", "pl", "pt-BR", "ru", "th", "tr", "vi", "zh-Hans", "zh-Hant"};
    for (const char* code : languages)
    {
        const std::wstring wide(code, code + std::char_traits<char>::length(code));
        const auto text = Strings::Template(wide);
        Check(text.find(L"{mod}") != std::wstring::npos && text.find(L"{version}") != std::wstring::npos &&
                      (wide == L"en" || text != Strings::Template(L"en")),
              std::string(code) + ": own template with both placeholders");
    }
    Check(Strings::UpdateAvailable(L"en", L"Passive Pals", L"1.5.0") == L"Passive Pals 1.5.0 is available.", "English line");
    Check(Strings::Template(L"es-AR") == Strings::Template(L"es"), "unknown region falls back to its base language");
    Check(Strings::Template(L"xx") == Strings::Template(L"en"), "unknown language falls back to English");

    std::printf("Feed\n");
    const auto feed = ReadFile(argv[2]);
    const std::string newest = argv[3];
    Check(Update::LatestVersion(feed) == newest, "newest version read from the saved live feed is " + newest);
    Check(!Update::NewerThanInstalled(feed, newest).has_value(), "nothing announced when installed equals the newest");
    Check(Update::NewerThanInstalled(feed, "1.0.0") == newest, "announced when installed is older");

    std::printf("%s (%d failure%s)\n", g_failures ? "FAILED" : "PASSED", g_failures, g_failures == 1 ? "" : "s");
    return g_failures ? 1 : 0;
}
