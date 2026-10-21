#include <atomic>
#include <chrono>
#include <exception>
#include <format>
#include <memory>
#include <optional>
#include <string>
#include <thread>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/Core/Containers/FString.hpp>
#include <Unreal/Hooks.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/UObjectGlobals.hpp>

#include <Identity.hpp>
#include <Notice.hpp>
#include <Strings.hpp>
#include <Update.hpp>

namespace
{
    struct CheckState
    {
        std::atomic<bool> Done{};
        std::optional<std::string> Newer{};
    };

    auto Wide(const std::string& ascii) -> RC::StringType
    {
        return RC::StringType(ascii.begin(), ascii.end());
    }

    // The engine's view of the player's language: "en", "ja", "zh-Hans", "pt-BR", ...
    auto CurrentLanguage() -> RC::StringType
    {
        using namespace RC::Unreal;
        auto* library = UObjectGlobals::StaticFindObject<UObject*>(nullptr, nullptr, STR("/Script/Engine.Default__KismetInternationalizationLibrary"));
        auto* function = library ? library->GetFunctionByNameInChain(STR("GetCurrentLanguage")) : nullptr;
        if (!function)
        {
            return {};
        }
        struct Params
        {
            FString ReturnValue{};
        } params{};
        library->ProcessEvent(function, &params);
        const RC::CharType* chars = *params.ReturnValue;
        return chars ? RC::StringType{chars} : RC::StringType{};
    }
}

// Ships inside a Lua mod's folder as dlls\main.dll, beside that mod's Scripts\, because UE4SS Lua
// has no HTTP. It checks the mod's own feed once per game start and, only when a newer version is
// published, adds one line to the game's on-screen log.
class UpdateNoticeMod : public RC::CppUserModBase
{
public:
    UpdateNoticeMod() : CppUserModBase()
    {
        const auto& mod = UpdateNotice::Identity::Current();
        ModName = UpdateNotice::Identity::Tag();
        ModVersion = Wide(mod.Version);
        ModDescription = STR("Tells the player when a newer version of this mod is published.");
        ModAuthors = STR("Alkeari");
        if (mod.PackageName.empty() || mod.Version.empty() || mod.Slug.empty())
        {
            m_disabled = true;
            RC::Output::send<RC::LogLevel::Warning>(std::format(STR("{} Update check off: dlls\\Info.json is missing or lacks PackageName, ModName or Version\n"),
                                                                UpdateNotice::Identity::Tag()));
            return;
        }
        if (!UpdateNotice::Identity::UpdatesEnabled())
        {
            RC::Output::send<RC::LogLevel::Normal>(std::format(STR("{} Update check off by checkForUpdates = false\n"), UpdateNotice::Identity::Tag()));
            return;
        }
        StartCheck(mod);
    }

    auto on_unreal_init() -> void override
    {
        if (m_disabled)
        {
            return;
        }
        try
        {
            RC::Unreal::Hook::RegisterEngineTickPreCallback(
                    [this](RC::Unreal::Hook::TCallbackIterationData<void>&, RC::Unreal::UEngine*, float, bool) { GameThreadTick(); },
                    {false, true, UpdateNotice::Identity::Tag(), STR("UpdateNoticeTick")});
        }
        catch (...)
        {
            m_disabled = true;
            RC::Output::send<RC::LogLevel::Error>(std::format(STR("{} Could not hook the engine tick; the update notice is off\n"), UpdateNotice::Identity::Tag()));
        }
    }

private:
    // The request runs on its own thread so a slow or absent network never holds up loading; the
    // state it fills is shared rather than owned by the mod, so a fetch in flight outlives nothing.
    auto StartCheck(const UpdateNotice::Identity::Mod& mod) -> void
    {
        const std::wstring path = L"/updates/" + Wide(mod.Slug) + L".json";
        std::thread([state = m_state, path, installed = mod.Version] {
            if (const auto feed = UpdateNotice::Update::FetchFeed(path))
            {
                state->Newer = UpdateNotice::Update::NewerThanInstalled(*feed, installed);
            }
            state->Done.store(true, std::memory_order_release);
        }).detach();
        m_checking = true;
        RC::Output::send<RC::LogLevel::Normal>(std::format(STR("{} Update check started: installed {}, feed {}{}\n"),
                                                           UpdateNotice::Identity::Tag(),
                                                           ModVersion,
                                                           UpdateNotice::Update::FeedHost,
                                                           path));
    }

    // Shows the newer version once, as soon as a player is in a world to see it; the title screen
    // draws no log, so a line posted there would be lost. Retried every few seconds, not every tick.
    auto GameThreadTick() -> void
    {
        if (m_disabled || m_announced || !m_checking || !m_state->Done.load(std::memory_order_acquire))
        {
            return;
        }
        if (!m_state->Newer)
        {
            m_announced = true;
            RC::Output::send<RC::LogLevel::Normal>(std::format(STR("{} Update check done: no newer version than {}\n"), UpdateNotice::Identity::Tag(), ModVersion));
            return;
        }
        if (!m_reportedFound)
        {
            m_reportedFound = true;
            RC::Output::send<RC::LogLevel::Normal>(std::format(STR("{} Update check done: {} is published; the notice shows once you are in a world\n"),
                                                               UpdateNotice::Identity::Tag(),
                                                               Wide(*m_state->Newer)));
        }
        const auto now = std::chrono::steady_clock::now();
        if (now - m_lastTry < std::chrono::seconds(3))
        {
            return;
        }
        m_lastTry = now;
        if (!UpdateNotice::Notice::PlayerInWorld())
        {
            return;
        }
        m_announced = true;
        // Read again here, so turning the setting off after launch still silences the notice.
        if (!UpdateNotice::Identity::UpdatesEnabled())
        {
            return;
        }
        const auto& mod = UpdateNotice::Identity::Current();
        const auto newer = Wide(*m_state->Newer);
        const auto line = UpdateNotice::Strings::UpdateAvailable(CurrentLanguage(), Wide(mod.ModName), newer);
        const bool shown = UpdateNotice::Notice::PostGameLog(line);
        RC::Output::send<RC::LogLevel::Normal>(std::format(STR("{} Version {} is available (installed {}){}\n"),
                                                           UpdateNotice::Identity::Tag(),
                                                           newer,
                                                           ModVersion,
                                                           shown ? STR("") : STR("; the in-game log could not be reached")));
    }

    std::shared_ptr<CheckState> m_state{std::make_shared<CheckState>()};
    std::chrono::steady_clock::time_point m_lastTry{};
    bool m_disabled{};
    bool m_checking{};
    bool m_announced{};
    bool m_reportedFound{};
};

#define UPDATE_NOTICE_API __declspec(dllexport)
extern "C"
{
    UPDATE_NOTICE_API RC::CppUserModBase* start_mod()
    {
        return new UpdateNoticeMod();
    }

    UPDATE_NOTICE_API void uninstall_mod(RC::CppUserModBase* mod)
    {
        delete mod;
    }
}
