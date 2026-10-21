local projectName = "UniversalConfigManager"

target(projectName)
    add_rules("ue4ss.mod")
    add_includedirs("include")
    add_files("src/dllmain.cpp", "src/Identity.cpp", "src/IdentityParse.cpp", "src/Notice.cpp", "src/Strings.cpp", "src/Text.cpp", "src/Update.cpp", "src/UpdateFetch.cpp")
