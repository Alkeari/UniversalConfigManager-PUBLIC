#include <Strings.hpp>

#include <array>
#include <utility>

namespace UpdateNotice::Strings
{
    namespace
    {
        // Palworld's 17 languages, keyed by the code KismetInternationalizationLibrary reports.
        // Generated from Palpedia Enhancer's update_available line, so both mods word it alike.
        constexpr std::array<std::pair<std::wstring_view, std::wstring_view>, 17> Templates{{
            {L"de", L"{mod} {version} ist verfügbar."},
            {L"en", L"{mod} {version} is available."},
            {L"es-MX", L"{mod} {version} está disponible."},
            {L"es", L"{mod} {version} está disponible."},
            {L"fr", L"{mod} {version} est disponible."},
            {L"id", L"{mod} {version} sudah tersedia."},
            {L"it", L"{mod} {version} è disponibile."},
            {L"ja", L"{mod} {version} が公開されています。"},
            {L"ko", L"{mod} {version} 버전이 출시되었습니다."},
            {L"pl", L"Dostępna jest wersja {mod} {version}."},
            {L"pt-BR", L"{mod} {version} está disponível."},
            {L"ru", L"Доступна версия {mod} {version}."},
            {L"th", L"{mod} {version} พร้อมให้ใช้งานแล้ว"},
            {L"tr", L"{mod} {version} yayımlandı."},
            {L"vi", L"{mod} {version} đã có bản mới."},
            {L"zh-Hans", L"{mod} {version} 已发布。"},
            {L"zh-Hant", L"{mod} {version} 已發布。"},
        }};

        auto Find(std::wstring_view code) -> std::wstring_view
        {
            for (const auto& [key, text] : Templates)
            {
                if (key == code)
                {
                    return text;
                }
            }
            return {};
        }

        auto Replace(std::wstring text, std::wstring_view token, std::wstring_view value) -> std::wstring
        {
            if (const auto at = text.find(token); at != std::wstring::npos)
            {
                text.replace(at, token.size(), value);
            }
            return text;
        }
    }

    auto Template(std::wstring_view language) -> std::wstring_view
    {
        if (const auto exact = Find(language); !exact.empty())
        {
            return exact;
        }
        if (const auto dash = language.find(L'-'); dash != std::wstring_view::npos)
        {
            if (const auto base = Find(language.substr(0, dash)); !base.empty())
            {
                return base;
            }
        }
        return Find(L"en");
    }

    auto UpdateAvailable(std::wstring_view language, std::wstring_view modName, std::wstring_view version) -> std::wstring
    {
        return Replace(Replace(std::wstring(Template(language)), L"{mod}", modName), L"{version}", version);
    }
}
