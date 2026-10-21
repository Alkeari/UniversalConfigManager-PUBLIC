#include <Identity.hpp>

#include <fstream>
#include <iterator>
#include <system_error>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>

namespace UpdateNotice::Identity
{
    namespace
    {
        auto ReadFile(const std::filesystem::path& file) -> std::string
        {
            std::ifstream in(file, std::ios::binary);
            if (!in)
            {
                return {};
            }
            return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        }

        auto DllDirectory() -> std::filesystem::path
        {
            HMODULE module{};
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               reinterpret_cast<LPCWSTR>(&DllDirectory),
                               &module);
            wchar_t buffer[MAX_PATH]{};
            GetModuleFileNameW(module, buffer, MAX_PATH);
            return std::filesystem::path(buffer).parent_path();
        }
    }

    auto ModDirectory() -> std::filesystem::path
    {
        return DllDirectory().parent_path();
    }

    auto Current() -> const Mod&
    {
        static const Mod mod = ParseInfo(ReadFile(DllDirectory() / L"Info.json"));
        return mod;
    }

    auto Tag() -> const std::wstring&
    {
        static const std::wstring tag = [] {
            const auto& name = Current().PackageName;
            // The folder name stands in when Info.json is missing, so the log still says whose copy it is.
            const std::wstring package = name.empty() ? ModDirectory().filename().wstring() : std::wstring(name.begin(), name.end());
            return L"[" + package + L"]";
        }();
        return tag;
    }

    auto UpdatesEnabled() -> bool
    {
        std::error_code error;
        for (const auto& entry : std::filesystem::directory_iterator(ModDirectory() / L"Scripts", error))
        {
            if (entry.path().extension() == L".lua" && !SourceAllowsCheck(ReadFile(entry.path())))
            {
                return false;
            }
        }
        return true;
    }
}
