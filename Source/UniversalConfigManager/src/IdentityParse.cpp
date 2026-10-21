#include <Identity.hpp>

#include <cctype>

namespace UpdateNotice::Identity
{
    namespace
    {
        auto SkipSpace(std::string_view text, size_t at) -> size_t
        {
            while (at < text.size() && std::isspace(static_cast<unsigned char>(text[at])))
            {
                ++at;
            }
            return at;
        }

        auto IsWordChar(char c) -> bool
        {
            return std::isalnum(static_cast<unsigned char>(c)) || c == '_';
        }

        // The first string value of a top-level "key": "value" pair. Info.json carries no escapes
        // in the three fields read here.
        auto StringField(std::string_view json, std::string_view key) -> std::string
        {
            const std::string quoted = "\"" + std::string(key) + "\"";
            size_t at = 0;
            while ((at = json.find(quoted, at)) != std::string_view::npos)
            {
                at = SkipSpace(json, at + quoted.size());
                if (at >= json.size() || json[at] != ':')
                {
                    continue;
                }
                at = SkipSpace(json, at + 1);
                if (at >= json.size() || json[at] != '"')
                {
                    continue;
                }
                const size_t end = json.find('"', at + 1);
                if (end == std::string_view::npos)
                {
                    return {};
                }
                return std::string(json.substr(at + 1, end - at - 1));
            }
            return {};
        }
    }

    auto SlugOf(std::string_view modName) -> std::string
    {
        std::string slug;
        bool pendingHyphen = false;
        for (const char c : modName)
        {
            if (std::isalnum(static_cast<unsigned char>(c)))
            {
                if (pendingHyphen && !slug.empty())
                {
                    slug.push_back('-');
                }
                pendingHyphen = false;
                slug.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
            }
            else
            {
                pendingHyphen = true;
            }
        }
        return slug;
    }

    auto ParseInfo(std::string_view infoJson) -> Mod
    {
        Mod mod;
        mod.PackageName = StringField(infoJson, "PackageName");
        mod.ModName = StringField(infoJson, "ModName");
        mod.Version = StringField(infoJson, "Version");
        mod.Slug = SlugOf(mod.ModName);
        return mod;
    }

    auto SourceAllowsCheck(std::string_view luaSource) -> bool
    {
        constexpr std::string_view key = "checkforupdates";
        size_t lineStart = 0;
        while (lineStart <= luaSource.size())
        {
            size_t lineEnd = luaSource.find('\n', lineStart);
            if (lineEnd == std::string_view::npos)
            {
                lineEnd = luaSource.size();
            }
            std::string_view line = luaSource.substr(lineStart, lineEnd - lineStart);
            lineStart = lineEnd + 1;
            if (const size_t comment = line.find("--"); comment != std::string_view::npos)
            {
                line = line.substr(0, comment);
            }
            std::string lower(line);
            for (char& c : lower)
            {
                c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            }
            size_t at = 0;
            while ((at = lower.find(key, at)) != std::string::npos)
            {
                const bool startsWord = at == 0 || !IsWordChar(lower[at - 1]);
                size_t next = at + key.size();
                at = next;
                if (!startsWord || (next < lower.size() && IsWordChar(lower[next])))
                {
                    continue;
                }
                next = SkipSpace(lower, next);
                if (next >= lower.size() || lower[next] != '=' || (next + 1 < lower.size() && lower[next + 1] == '='))
                {
                    continue;
                }
                next = SkipSpace(lower, next + 1);
                if (lower.compare(next, 5, "false") == 0 && (next + 5 >= lower.size() || !IsWordChar(lower[next + 5])))
                {
                    return false;
                }
            }
            if (lineEnd == luaSource.size())
            {
                break;
            }
        }
        return true;
    }
}
