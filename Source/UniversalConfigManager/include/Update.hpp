#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace UpdateNotice::Update
{
    // The published-version feeds, one per mod at /updates/<slug>.json, each listing the mod's
    // release lines with their versions; nothing is sent to it but the request itself.
    inline constexpr std::wstring_view FeedHost = L"alkeari.com";

    // The highest "version" value anywhere in the feed, or nothing when it carries none.
    auto LatestVersion(std::string_view feedJson) -> std::optional<std::string>;

    // Compares dotted numeric versions ("1.11.1"): negative, zero or positive like strcmp.
    // A missing part counts as 0, so "1.2" equals "1.2.0".
    auto CompareVersions(std::string_view left, std::string_view right) -> int;

    // The version to announce, only when the feed names one newer than the installed version.
    auto NewerThanInstalled(std::string_view feedJson, std::string_view installed) -> std::optional<std::string>;

    // Fetches FeedHost + path over HTTPS on the calling thread. Nothing on any failure.
    auto FetchFeed(std::wstring_view path) -> std::optional<std::string>;
}
