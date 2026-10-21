-- Walks the UE4SS Mods directory for config files and parses them into an editable model.
--
-- Model shape:
--   { mods = { { name, files = { { path, rel, format, entries } } } }, totalEntries }
-- Entries come straight from the format parser: { key, type, value, from, to }.
local Config = require("config")
local FsUtil = require("fsutil")
local ParseIni = require("parse_ini")
local ParseJson = require("parse_json")
local ParseLua = require("parse_lua")
local ParseFramework = require("parse_framework")
local ParseModconfig = require("parse_modconfig")
local Frameworks = require("frameworks")
local Scope = require("scope")

local Scanner = {}

local PARSERS = { lua = ParseLua, ini = ParseIni, json = ParseJson,
    modconfig = ParseModconfig }

-- DekModConfigMenu (Nexus 577) names its files "<Mod>.modconfig.json". They are JSON, but the
-- generic JSON reader would surface the schema itself (`type`, `desc`, `opts.min`) as editable
-- rows, so they get their own parser and their own format name.
local MODCONFIG_SUFFIX = ".modconfig.json"

-- Routes a file record to the right parser: the format-keyed table above for plain config
-- files, or ParseFramework (with the headerLines recorded on the file) for a reattributed
-- framework saved-value store (file.format = "framework:nativemodoptions" / "framework:palmodoptions").
local function parserFor(file)
    if type(file.format) == "string" and file.format:sub(1, 10) == "framework:" then
        local headerLines = file.headerLines or 0
        return {
            parse = function(content) return ParseFramework.parse(content, headerLines) end,
            rewrite = function(content, edits)
                return ParseFramework.rewrite(content, headerLines, edits)
            end,
        }
    end
    return PARSERS[file.format]
end

-- <UE4SS>\Mods, derived from this script's own location:
-- <Mods>\UniversalConfigManager\Scripts -> <Mods>.
function Scanner.modsDirectory()
    local scripts = FsUtil.scriptDirectory()
    local modRoot = FsUtil.parent(scripts)
    return modRoot and FsUtil.parent(modRoot) or nil
end

-- <Palworld>\Mods\ManagedMods, derived from modsDirectory: three parents up from
-- <UE4SS>\Mods is <Palworld>\Mods. Shared by main.lua's boot scan and Panel.build's
-- cache-miss fallback so both decorate a freshly scanned model the same way.
function Scanner.managedModsDirectory(modsDirOverride)
    local modsDir = modsDirOverride or Scanner.modsDirectory()
    if modsDir == nil then
        return nil
    end
    local ue4ssRoot = FsUtil.parent(FsUtil.parent(modsDir) or "")
    local palMods = ue4ssRoot and FsUtil.parent(ue4ssRoot) or nil
    return palMods and (palMods .. "\\ManagedMods") or nil
end

local function formatOf(fileName)
    local lower = fileName:lower()
    if #lower > #MODCONFIG_SUFFIX and lower:sub(-#MODCONFIG_SUFFIX) == MODCONFIG_SUFFIX then
        return "modconfig"
    end
    local extension = lower:match("%.[^%.]+$")
    return extension and Config.extensions[extension] or nil
end

local function isExcludedPath(modName, relPath)
    local combined = (modName .. "\\" .. relPath):lower()
    for _, prefix in ipairs(Config.excludedPathPrefixes) do
        if combined:sub(1, #prefix) == prefix then
            return true
        end
    end
    local firstSegment = relPath:match("^([^\\/]+)[\\/]")
    if firstSegment ~= nil and Config.excludedFolderNames[firstSegment:lower()] then
        return true
    end
    return false
end

-- A mod folder that carries neither a Scripts directory nor a C++ dll runs no code this
-- session, whatever mods.txt says: what is left is the leftovers of a removed mod, and its
-- saved state is not settings (audit, 2026-09-03: an UltraGraphics folder holding only its own
-- state ini was listed as a mod with two editable "settings").
local function runsCode(files)
    for _, path in ipairs(files) do
        local lowered = path:lower()
        if lowered:find("\\scripts\\", 1, true) or lowered:find("/scripts/", 1, true)
            or lowered:find("\\dlls\\main.dll", 1, true) or lowered:find("/dlls/main.dll", 1, true) then
            return true
        end
    end
    return false
end

-- Windows path comparison: separators and case both vary by source. UE4SS's script path uses
-- forward slashes while its directory walker returns backslashes, and comparing the two raw is
-- what let every file read as living outside its own mod folder (2026-09-04). Never compare two
-- paths with `==`; the length-based slices elsewhere are safe because both separators are one
-- character wide.
local function samePrefix(path, prefix)
    if path == nil or prefix == nil then
        return false
    end
    local head = path:sub(1, #prefix):gsub("/", "\\"):lower()
    return head == (prefix:gsub("/", "\\"):lower())
end

local function depthOf(relPath)
    local segments = 0
    for _ in relPath:gmatch("[^\\/]+") do
        segments = segments + 1
    end
    return segments
end

local UTF8_BOM = "\239\187\191"

-- Normalizes a raw file read for parsing: strips a UTF-8 BOM (returned separately so writes can
-- keep it), and refuses encodings the byte-splice parsers cannot handle (UTF-16 BOMs, embedded
-- NULs) with a reason instead of producing garbage entries.
local function prepareContent(raw)
    if raw:sub(1, 2) == "\255\254" or raw:sub(1, 2) == "\254\255" then
        return nil, nil, "UTF-16 encoding is not supported"
    end
    local bom = ""
    if raw:sub(1, 3) == UTF8_BOM then
        bom = UTF8_BOM
        raw = raw:sub(4)
    end
    if raw:find("%z") then
        return nil, nil, "binary or unsupported encoding"
    end
    return raw, bom
end

-- The gate for loose-INI candidates (.txt/.cfg): the file must be overwhelmingly key=value
-- shaped, so a prose readme named "settings.txt" never yields junk rows.
local function passesLooseIniGate(content, entryCount)
    if entryCount < Config.looseIniMinEntries then
        return false
    end
    local meaningful, structured = 0, 0
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and not trimmed:match("^[;#]") then
            meaningful = meaningful + 1
            if trimmed:match("^%[[^%]]*%]$")
                or trimmed:match("^[^=%[%]]+=") then
                structured = structured + 1
            end
        end
    end
    return meaningful > 0
        and structured / meaningful >= Config.looseIniMinStructureRatio
end

-- Detects another framework's saved-values file by BEHAVIOR rather than by the framework's
-- folder name: a config file sitting at some mod's root, named exactly after a DIFFERENT
-- installed mod, is that framework's store for the other mod (the NativeModOptions pattern) and
-- must not be edited from a second surface. Works whatever the framework is called.
local function isForeignValueStore(rel, fileName, ownModName, installedMods)
    if depthOf(rel) ~= 1 then
        return false
    end
    local base = fileName:match("^(.*)%.[^%.]+$")
    if base == nil then
        return false
    end
    local lowered = base:lower()
    if lowered == ownModName:lower() then
        return false
    end
    return installedMods[lowered] == true
end

-- Returns (source, consumerId, headerLines) if `rel` (relative to the Mods directory) matches a
-- framework's per-consumer saved-value path from Config.frameworkPathPatterns, else nil. Unlike
-- isForeignValueStore, this identifies WHICH mod the file belongs to instead of merely flagging
-- it, so the caller can reattribute it rather than exclude it.
local function frameworkAttribution(rel, fileName)
    local lowered = rel:lower()
    for _, pattern in ipairs(Config.frameworkPathPatterns) do
        local prefix = pattern.folder .. "\\"
        if lowered:sub(1, #prefix) == prefix then
            local id = pattern.idFromFile(fileName)
            if id ~= nil then
                return pattern.source, id, pattern.headerLines
            end
        end
    end
    return nil
end

-- Reads, decodes, parses, and classifies one file (Scripts/scope.lua), appending it to
-- model.files when it is a user config, pure-data Lua, or advanced Lua with real entries.
-- Templates and ignored files never become file records; a template's path is remembered so
-- its sibling can name it as the defaults source.
local function processCandidate(model, modName, path, rel, fileName, format, siblingNames,
                                templatesByBase, log)
    local raw, readErr = FsUtil.readFile(path)
    if raw == nil then
        log("cannot read " .. path .. ": " .. tostring(readErr))
        return
    end
    local content, bom, encodingErr = prepareContent(raw)
    if content == nil then
        log("skipped " .. modName .. "\\" .. rel .. ": " .. tostring(encodingErr))
        return
    end
    local looseIni = Config.looseIniExtensions[fileName:lower():match("%.[^%.]+$") or ""]
    local entries, parseErr = PARSERS[format].parse(content)
    if entries == nil then
        log("skipped " .. modName .. "\\" .. rel .. ": " .. tostring(parseErr))
        return
    end
    -- A DekModConfigMenu file DECLARES its settings: each one states its type, its description,
    -- its range or its vocabulary, and its default. Every heuristic below exists to guess
    -- whether an UNDECLARED file holds settings, and each of them would throw this one out for
    -- the wrong reason: `live` equals `init` until the player changes something (runtime
    -- state), the same four member names repeat per setting (record library), and the schema
    -- text makes the file large for its setting count (sparse data). So the declaration is
    -- taken at its word, and the only question asked is whether the file really is one.
    if format == "modconfig" then
        local recognized, why = ParseModconfig.looksLikeModconfig(content)
        if not recognized then
            log("skipped " .. modName .. "\\" .. rel .. ": " .. tostring(why))
            return
        end
        model.files[#model.files + 1] = {
            path = path, rel = rel, format = format, class = "user",
            entries = entries, content = content, bom = bom,
        }
        return
    end
    if looseIni and not passesLooseIniGate(content, #entries) then
        log("skipped " .. modName .. "\\" .. rel .. ": not key=value shaped enough to be a config")
        return
    end
    if Scope.isTranslationTable(fileName, entries) then
        log("skipped " .. modName .. "\\" .. rel .. ": translation table, not settings")
        return
    end
    if Scope.isMetadataTable(entries) then
        log("skipped " .. modName .. "\\" .. rel .. ": mod identity record, not settings")
        return
    end
    if Scope.isRuntimeState(content, entries) then
        log("skipped " .. modName .. "\\" .. rel .. ": every value is a default and nothing is "
            .. "commented, so this is a mod's starting state")
        return
    end
    if Scope.isSparseData(content, #entries) then
        log("skipped " .. modName .. "\\" .. rel .. ": " .. #content .. " bytes for "
            .. #entries .. " setting(s), so this is a data store rather than a config")
        return
    end
    local class = Scope.classify(fileName, rel, format, content, #entries, siblingNames)
    if class == "template" then
        local sibling = Scope.templateSibling(siblingNames, fileName)
        if sibling ~= nil then
            templatesByBase[sibling:lower()] = { rel = rel, entries = entries }
        end
        return
    end
    if class == "ignored" then
        if #entries > Config.maxSettingsPerFile then
            log("skipped " .. modName .. "\\" .. rel .. ": " .. #entries
                .. " entries, reference data rather than settings")
        end
        return
    end
    if class == "advanced" then
        for _, entry in ipairs(entries) do
            entry.advanced = true
        end
    end
    model.files[#model.files + 1] = {
        path = path, rel = rel, format = format, class = class,
        entries = entries, content = content, bom = bom,
    }
end

-- Orders a mod's file list with every advanced-class file after every non-advanced file
-- (ties broken by rel path), so the panel's "Advanced" header always follows every user file
-- regardless of alphabetical accident. Shared by scanMod and mergeFrameworkFiles so a
-- framework merge can never undo scanMod's ordering.
local function classRank(class) return class == "advanced" and 1 or 0 end
local function fileOrderLess(a, b)
    local ra, rb = classRank(a.class), classRank(b.class)
    if ra ~= rb then
        return ra < rb
    end
    return a.rel:lower() < b.rel:lower()
end

-- Drops files a dedupe pass emptied out (every entry was already exposed by a sibling
-- file), so a zero-entry heading never survives into a mod's file list. Shared by scanMod (boot
-- scan) and Scanner.refresh (a later dedupe can empty a file that had entries at boot).
local function dropEmptyFiles(files)
    local kept = {}
    for _, file in ipairs(files) do
        if #file.entries > 0 then
            kept[#kept + 1] = file
        end
    end
    return kept
end

-- Scans one mod folder from the pre-listed file inventory. Returns a mod model, or nil when it
-- contributes nothing. `installedMods` is the lowercased set of every mod folder name, for the
-- foreign-store rule. Every parseable file within Config.maxDepth is classified by content
-- (Scripts/scope.lua); nothing here keys on a file's name beyond its extension.
-- Two places a mod may keep the config it asks the player to edit, both OUTSIDE the Mods tree
-- because a Workshop update replaces everything inside it: `Pal\Saved\<ModFolder>\` (the folder
-- name is the attribution) and `Pal\Binaries\Win64\` beside the executable (the file's stem,
-- minus a trailing "config"/"settings", must prefix-match a mod folder). Both were invisible
-- here, so two active mods showed nothing at all (audit, 2026-09-03).
local EXTERNAL_STEM_SUFFIXES = { "_config", "config", "_settings", "settings", "_cfg", "cfg" }

-- DekModConfigMenu's consumers are usually Blueprint paks with no UE4SS mod folder at all, and
-- their config sits beside the pak in `Pal\Content\Paks\LogicMods`. ONLY "*.modconfig.json" is
-- read there: that folder is otherwise full of .pak binaries, and sweeping it would be a far
-- larger surface than this framework needs. The file's presence is the gate, since the
-- enabled.txt / mods.txt rule cannot speak for a mod UE4SS never loads: an author ships one of
-- these only to be configured.
local function logicModsModconfigs(gameRoot)
    local found = {}
    if gameRoot == nil then
        return found
    end
    local dir = gameRoot .. "\\Pal\\Content\\Paks\\LogicMods"
    for _, path in ipairs(FsUtil.listFilesRecursive(dir) or {}) do
        local fileName = path:match("[^\\/]+$") or ""
        if formatOf(fileName) == "modconfig" then
            found[#found + 1] = { path = path,
                stem = fileName:sub(1, #fileName - #MODCONFIG_SUFFIX) }
        end
    end
    return found
end

local function externalConfigsFor(gameRoot, modNames, log)
    local found = {}
    if gameRoot == nil then
        return found
    end
    for _, modName in ipairs(modNames) do
        local savedDir = gameRoot .. "\\Pal\\Saved\\" .. modName
        for _, path in ipairs(FsUtil.listFilesRecursive(savedDir) or {}) do
            found[modName] = found[modName] or {}
            table.insert(found[modName], path)
        end
    end
    local binariesDir = gameRoot .. "\\Pal\\Binaries\\Win64"
    local byLowerName = {}
    for _, modName in ipairs(modNames) do
        byLowerName[modName:lower()] = modName
    end
    for _, path in ipairs(FsUtil.listFilesRecursive(binariesDir) or {}) do
        local rest = path:sub(#binariesDir + 2)
        local stem = rest:match("^([^\\/]+)%.[^%.\\/]+$")
        if stem ~= nil and formatOf(rest) ~= nil then
            local base = stem:lower()
            for _, suffix in ipairs(EXTERNAL_STEM_SUFFIXES) do
                if #base > #suffix and base:sub(-#suffix) == suffix then
                    base = base:sub(1, #base - #suffix)
                    break
                end
            end
            if #base >= 6 then
                for lowered, modName in pairs(byLowerName) do
                    if lowered == base or lowered:sub(1, #base) == base then
                        found[modName] = found[modName] or {}
                        table.insert(found[modName], path)
                        log("found " .. modName .. "'s config outside the Mods tree: " .. rest)
                        break
                    end
                end
            end
        end
    end
    return found
end

-- Boot diagnostic, one launch's worth. The in-game scan produced 162 config files and 2,872
-- values where the same code offline on the same install produced 60 and 871 (2026-09-04), so
-- the two disagree about which files qualify. `rel` is derived by slicing the mods-directory
-- prefix off an absolute path by string length, which is the step most likely to differ when the
-- listing comes from UE4SS's directory walker instead of a shell, and every gate below it keys
-- off `rel`. This records the raw path beside the derived one for a bounded sample, plus the
-- tally of what each gate rejected, so the log answers it without another guess.
Scanner.diagSamples = 14
local diagShown, diagTally = 0, nil

function Scanner.diag(modName, path, rel, format, depthOk, excluded)
    if diagTally == nil then
        return
    end
    diagTally.seen = diagTally.seen + 1
    if format == nil then
        diagTally.notConfigFormat = diagTally.notConfigFormat + 1
    elseif not depthOk then
        diagTally.tooDeep = diagTally.tooDeep + 1
    elseif excluded then
        diagTally.excluded = diagTally.excluded + 1
    else
        diagTally.admitted = diagTally.admitted + 1
    end
    if diagShown < Scanner.diagSamples and format ~= nil then
        diagShown = diagShown + 1
        diagTally.log("path[" .. diagShown .. "] raw=" .. tostring(path))
        diagTally.log("path[" .. diagShown .. "] mod=" .. tostring(modName)
            .. " rel=" .. tostring(rel) .. " depth=" .. depthOf(rel)
            .. "/" .. Config.maxDepth .. " format=" .. tostring(format)
            .. " depthOk=" .. tostring(depthOk) .. " excluded=" .. tostring(excluded))
    end
end

function Scanner.beginDiag(log, modsDir)
    diagShown = 0
    diagTally = { seen = 0, notConfigFormat = 0, tooDeep = 0, excluded = 0, admitted = 0,
        log = log }
    log("diag: modsDir=" .. tostring(modsDir))
end

function Scanner.endDiag()
    if diagTally == nil then
        return
    end
    diagTally.log("diag: candidates " .. diagTally.seen
        .. " -> admitted " .. diagTally.admitted
        .. ", rejected notConfigFormat " .. diagTally.notConfigFormat
        .. ", tooDeep " .. diagTally.tooDeep
        .. ", excluded " .. diagTally.excluded)
    diagTally = nil
end

local function scanMod(modsDir, modName, files, installedMods, log, gameRoot)
    if not runsCode(files) then
        log("skipped " .. modName .. ": no Scripts folder and no dll, so nothing runs from it")
        return nil
    end
    local modDir = modsDir .. "\\" .. modName
    local model = { name = modName, dir = modDir, files = {}, allFiles = files }
    local siblingNames = {}
    for _, path in ipairs(files) do
        siblingNames[#siblingNames + 1] = path:match("[^\\/]+$") or ""
    end
    local templatesByBase = {}
    for _, path in ipairs(files) do
        -- A file outside the mod's own folder (Pal\Saved, Pal\Binaries\Win64) is shown by its
        -- path from the game root, so the header names where it really lives.
        local rel
        local external = not samePrefix(path, modDir)
        if not external then
            rel = path:sub(#modDir + 2)
        elseif samePrefix(path, gameRoot) then
            rel = path:sub(#gameRoot + 2)
        else
            rel = path:match("[^\\/]+$") or path
        end
        local fileName = path:match("[^\\/]+$") or ""
        local format = formatOf(fileName)
        -- The depth cap keeps a mod's own asset tree out of the scan; an external config was
        -- already located by name, so its depth from the game root proves nothing.
        local depthOk = external or depthOf(rel) <= Config.maxDepth
        local excluded = isExcludedPath(modName, rel)
        Scanner.diag(modName, path, rel, format, depthOk, excluded)
        if format ~= nil and depthOk and not excluded then
            if isForeignValueStore(rel, fileName, modName, installedMods) then
                log("skipped " .. modName .. "\\" .. rel
                    .. ": another mod's saved values (a framework store)")
            else
                processCandidate(model, modName, path, rel, fileName, format, siblingNames,
                    templatesByBase, log)
            end
        end
    end
    for _, file in ipairs(model.files) do
        local fileName = file.rel:match("[^\\/]+$") or ""
        local template = templatesByBase[fileName:lower()]
        if template ~= nil then
            file.templateRel = template.rel
            file.templateEntries = template.entries
        end
    end
    local removed = Scope.dedupeExposed(model.files)
    if removed > 0 then
        log(modName .. ": " .. removed .. " key(s) already exposed by a higher-precedence file")
    end
    model.files = dropEmptyFiles(model.files)
    if #model.files == 0 then
        return nil
    end
    table.sort(model.files, fileOrderLess)
    return model
end

-- Parses each of a consumer mod's claimed framework saved-value files, tags every entry with
-- its owning framework (entry.source) and, best-effort, that option's schema (entry.schema),
-- and folds them into that mod's model - creating the model when the mod contributed nothing
-- of its own (a framework-only consumer with no other config file). Records true/false into
-- `coverage[frameworkSource].consumers[modName]`: true on a successful parse, false when the
-- file exists but fails to parse. Schema is fetched at most once per framework per consumer
-- (there is normally exactly one file per framework per consumer anyway).
local function mergeFrameworkFiles(model, modsDir, modName, frameworkFiles, filesByMod, coverage,
    log)
    local schemaCache = {}
    for _, ff in ipairs(frameworkFiles) do
        local frameworkKey = ff.source:match("^framework:(.+)$")
        coverage[ff.source] = coverage[ff.source] or { consumers = {} }
        local raw, readErr = FsUtil.readFile(ff.path)
        if raw == nil then
            log("cannot read " .. ff.path .. ": " .. tostring(readErr))
            coverage[ff.source].consumers[modName] = false
        else
            local content, bom, encodingErr = prepareContent(raw)
            if content == nil then
                log("skipped " .. modName .. "\\" .. ff.rel .. ": " .. tostring(encodingErr))
                coverage[ff.source].consumers[modName] = false
            else
                local entries, parseErr = ParseFramework.parse(content, ff.headerLines)
                if entries == nil then
                    log("skipped " .. modName .. "\\" .. ff.rel .. ": " .. tostring(parseErr))
                    coverage[ff.source].consumers[modName] = false
                else
                    coverage[ff.source].consumers[modName] = true
                    if schemaCache[frameworkKey] == nil then
                        schemaCache[frameworkKey] = Frameworks.schemaFor(frameworkKey, modName)
                            or false
                    end
                    local schema = schemaCache[frameworkKey]
                    for _, entry in ipairs(entries) do
                        entry.source = ff.source
                        if schema and schema.options ~= nil then
                            entry.schema = schema.options[entry.key]
                        end
                    end
                    if model == nil then
                        model = { name = modName, dir = modsDir .. "\\" .. modName,
                            files = {}, allFiles = filesByMod[modName] or {} }
                    end
                    if schema and schema.title ~= nil then
                        model.schemaTitle = model.schemaTitle or schema.title
                    end
                    model.files[#model.files + 1] = { path = ff.path, rel = ff.rel,
                        format = ff.source, class = "user", headerLines = ff.headerLines,
                        entries = entries, content = content, bom = bom }
                end
            end
        end
    end
    if model ~= nil then
        table.sort(model.files, fileOrderLess)
    end
    return model
end

-- UE4SS starts a mod this session when its folder holds an enabled.txt (whatever mods.txt
-- says: UE4SSProgram's enabled.txt pass only skips mods already started), or when
-- Mods\mods.txt lists it as "<Name> : 1". Only those mods run, so only their settings are
-- offered. Returns a set keyed by lowercased folder name, or nil when mods.txt is unreadable
-- (a layout this code does not know: every folder then counts as active, logged).
function Scanner.activeModSet(modsDir, modNames, log)
    local content = FsUtil.readFile(modsDir .. "\\mods.txt")
    if content == nil then
        return nil
    end
    local listed = {}
    for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        local name, flag = line:match("^%s*([^;#:][^:]*):%s*([01])")
        if name ~= nil then
            listed[name:match("^%s*(.-)%s*$"):lower()] = (flag == "1")
        end
    end
    local active = {}
    for _, modName in ipairs(modNames) do
        local lower = modName:lower()
        active[lower] = listed[lower] == true
            or FsUtil.readFile(modsDir .. "\\" .. modName .. "\\enabled.txt") ~= nil
    end
    return active
end

-- Full scan. One single whole-tree listing (in-process through UE4SS's game tree; the shell
-- fallback spawns a visible console window, so this stays THE one listing per scan), then
-- everything else is plain io.
-- `log` receives one line per skipped-with-reason file; pass a no-op to silence.
-- `modsDirOverride` exists for the offline test harness, which runs outside the install;
-- `options.allMods` makes it ignore mods.txt (the live-install sweep and the catalog tools
-- must see every installed mod, whatever happens to be enabled at that moment).
function Scanner.scan(log, modsDirOverride, options)
    log = log or function() end
    options = options or {}
    local modsDir = modsDirOverride or Scanner.modsDirectory()
    if modsDir == nil then
        return nil, "could not derive the Mods directory from the script path"
    end
    -- In game the script path comes back with FORWARD slashes
    -- ("D:/Steam/.../UE4SS/Mods") while UE4SS's directory walker returns file paths with
    -- BACKslashes, so every prefix comparison below silently failed: every file looked like it
    -- lived outside its own mod folder, which skipped the depth cap, reduced `rel` to a bare
    -- filename so no path exclusion could match, and let every mod's internal code files through.
    -- That is 2,872 "settings" in game against 875 offline (2026-09-04, the boot diagnostic).
    -- Normalizing here fixes the comparisons and every path built from modsDir at once.
    modsDir = (modsDir:gsub("/", "\\"))
    Scanner.beginDiag(log, modsDir)
    local allFiles = FsUtil.listFilesRecursive(modsDir)
    if allFiles == nil then
        Scanner.endDiag()
        return nil, "could not list the Mods directory (no game tree and io.popen unavailable)"
    end
    -- Mod folders and their file inventories fall out of the one listing.
    local filesByMod = {}
    local modNames = {}
    for _, path in ipairs(allFiles) do
        local rel = path:sub(#modsDir + 2)
        local modName = rel:match("^([^\\/]+)[\\/]")
        if modName ~= nil then
            if filesByMod[modName] == nil then
                filesByMod[modName] = {}
                modNames[#modNames + 1] = modName
            end
            local bucket = filesByMod[modName]
            bucket[#bucket + 1] = path
        end
    end
    -- The recursive listing does not traverse junctions or symlinks, and link-deployed mods
    -- are real (mod managers deploy that way). One directory listing finds the mod folders the
    -- tree walk produced no files for; only those few get a direct (link-resolving) listing.
    local modDirs = FsUtil.listDirectories(modsDir)
    for _, modName in ipairs(modDirs or {}) do
        if filesByMod[modName] == nil then
            local linkedFiles = FsUtil.listFilesRecursive(modsDir .. "\\" .. modName)
            if linkedFiles ~= nil and #linkedFiles > 0 then
                filesByMod[modName] = linkedFiles
                modNames[#modNames + 1] = modName
            end
        end
    end
    -- `<game>\Mods\NativeMods\UE4SS\Mods` is the only shape the external roots hang off; a test
    -- harness pointed anywhere else gets nil and skips them entirely.
    local gameRoot = nil
    local suffix = "\\mods\\nativemods\\ue4ss\\mods"
    local normalized = modsDir:gsub("/", "\\"):lower()
    if #modsDir > #suffix and normalized:sub(-#suffix) == suffix then
        gameRoot = modsDir:sub(1, #modsDir - #suffix)
    end
    for modName, paths in pairs(externalConfigsFor(gameRoot, modNames, log)) do
        local bucket = filesByMod[modName]
        for _, path in ipairs(paths) do
            bucket[#bucket + 1] = path
        end
    end
    -- installedMods covers every mod FOLDER on disk, not just the ones that contributed a
    -- config-like file, so a framework saved-value file can be reattributed to a consumer that
    -- otherwise has nothing else in its folder for the main loop to find.
    local installedMods = {}
    local modNameByLower = {}
    for _, modName in ipairs(modNames) do
        installedMods[modName:lower()] = true
        modNameByLower[modName:lower()] = modName
    end
    -- One diagnostic line per scan naming the lister and every folder's file count, so a
    -- listing that silently misses files (the 2026-09-02 tree-walk deploy scanned 61 files
    -- where the shell listing found 68) is visible in the log without a debugger.
    local counts = {}
    local sortedNames = {}
    for _, modName in ipairs(modNames) do
        sortedNames[#sortedNames + 1] = modName
    end
    table.sort(sortedNames, function(a, b) return a:lower() < b:lower() end)
    for _, modName in ipairs(sortedNames) do
        counts[#counts + 1] = modName .. "=" .. #filesByMod[modName]
    end
    local empty = {}
    for _, modName in ipairs(modDirs or {}) do
        if filesByMod[modName] == nil then
            empty[#empty + 1] = modName
        end
    end
    if #allFiles > 0 then
        log("listed " .. #allFiles .. " file(s) via " .. tostring(FsUtil.lastListingSource)
            .. ": " .. table.concat(counts, " ")
            .. (#empty > 0 and ("; folders with no files listed: " .. table.concat(empty, " ")) or ""))
    end
    for _, modName in ipairs(modDirs or {}) do
        if installedMods[modName:lower()] == nil then
            installedMods[modName:lower()] = true
            modNameByLower[modName:lower()] = modName
        end
    end
    -- A LogicMods modconfig belongs to a UE4SS mod folder when its stem names one (the pak's
    -- "_P" suffix is not part of that name), and stands alone otherwise. Attaching it to the
    -- folder keeps one mod on one page rather than splitting it in two.
    local modconfigOrphans = {}
    for _, item in ipairs(logicModsModconfigs(gameRoot)) do
        local base = item.stem:gsub("_P$", "")
        local owner = modNameByLower[item.stem:lower()] or modNameByLower[base:lower()]
        if owner ~= nil and filesByMod[owner] ~= nil then
            local bucket = filesByMod[owner]
            bucket[#bucket + 1] = item.path
            log("found " .. owner .. "'s DekModConfigMenu config in LogicMods: " .. item.stem)
        else
            modconfigOrphans[#modconfigOrphans + 1] = { path = item.path, name = base }
        end
    end
    local active = nil
    if not options.allMods then
        active = Scanner.activeModSet(modsDir, modNames, log)
    end
    local function isActive(modName)
        return active == nil or active[modName:lower()] == true
    end
    if active ~= nil then
        local hidden = {}
        for _, modName in ipairs(sortedNames) do
            if not isActive(modName) and not Config.excludedMods[modName] then
                hidden[#hidden + 1] = modName
            end
        end
        if #hidden > 0 then
            log("not active this session, hidden: " .. table.concat(hidden, " "))
        end
    end

    -- Framework saved-value reattribution: a pre-pass over the two frameworks' own folders,
    -- claiming per-consumer value files before the main per-mod scan sees them, so they end up
    -- in the consumer's own model instead of the framework's.
    local frameworkModFolders = { nativemodoptions = true, palmodoptions = true }
    local claimedPaths = {}
    local frameworkFilesByConsumer = {}
    local frameworkCoverage = {}
    for _, modName in ipairs(modNames) do
        if frameworkModFolders[modName:lower()] then
            for _, path in ipairs(filesByMod[modName]) do
                local rel = path:sub(#modsDir + 2)
                local fileName = path:match("[^\\/]+$") or ""
                local source, consumerId, headerLines = frameworkAttribution(rel, fileName)
                if source ~= nil then
                    claimedPaths[path] = true
                    local lowerId = consumerId:lower()
                    if installedMods[lowerId] then
                        local bucket = frameworkFilesByConsumer[lowerId]
                        if bucket == nil then
                            bucket = {}
                            frameworkFilesByConsumer[lowerId] = bucket
                        end
                        bucket[#bucket + 1] = { path = path, rel = rel, fileName = fileName,
                            source = source, headerLines = headerLines }
                    else
                        log("skipped " .. modName .. "\\" .. rel
                            .. ": stale framework saved values (no installed mod named '"
                            .. consumerId .. "')")
                    end
                end
            end
        end
    end

    local result = { mods = {}, totalEntries = 0, modsDir = modsDir }
    for _, modName in ipairs(modNames) do
        if not Config.excludedMods[modName] and isActive(modName) then
            local files = filesByMod[modName]
            if frameworkModFolders[modName:lower()] then
                local filtered = {}
                for _, path in ipairs(files) do
                    if not claimedPaths[path] then
                        filtered[#filtered + 1] = path
                    end
                end
                files = filtered
            end
            local model = scanMod(modsDir, modName, files, installedMods, log, gameRoot)
            local frameworkFiles = frameworkFilesByConsumer[modName:lower()]
            if frameworkFiles ~= nil then
                model = mergeFrameworkFiles(model, modsDir, modName, frameworkFiles, filesByMod,
                    frameworkCoverage, log)
            end
            if model ~= nil then
                result.mods[#result.mods + 1] = model
                for _, file in ipairs(model.files) do
                    result.totalEntries = result.totalEntries + #file.entries
                end
            end
        end
    end
    -- Consumers that own no config-like file of their own (nothing for the loop above to have
    -- visited) but DO have a framework saved-value file still need a model of their own.
    for lowerId, frameworkFiles in pairs(frameworkFilesByConsumer) do
        if filesByMod[modNameByLower[lowerId]] == nil then
            local modName = modNameByLower[lowerId]
            if not Config.excludedMods[modName] and isActive(modName) then
                local model = mergeFrameworkFiles(nil, modsDir, modName, frameworkFiles,
                    filesByMod, frameworkCoverage, log)
                if model ~= nil then
                    result.mods[#result.mods + 1] = model
                    for _, file in ipairs(model.files) do
                        result.totalEntries = result.totalEntries + #file.entries
                    end
                end
            end
        end
    end
    -- A DekModConfigMenu consumer with no UE4SS folder at all: a Blueprint pak whose only
    -- editable surface is the file beside it. It gets a model of its own, with no mod directory,
    -- so the bounds ladder mines nothing (there is no source to mine) and reads the author's
    -- declared range instead.
    for _, orphan in ipairs(modconfigOrphans) do
        if not Config.excludedMods[orphan.name] then
            local rel = gameRoot ~= nil and samePrefix(orphan.path, gameRoot)
                and orphan.path:sub(#gameRoot + 2) or orphan.path
            local model = { name = orphan.name, dir = nil, files = {}, allFiles = { orphan.path } }
            local fileName = orphan.path:match("[^\\/]+$") or ""
            processCandidate(model, orphan.name, orphan.path, rel, fileName, "modconfig", {},
                {}, log)
            if #model.files > 0 then
                result.mods[#result.mods + 1] = model
                for _, file in ipairs(model.files) do
                    result.totalEntries = result.totalEntries + #file.entries
                end
            end
        end
    end
    table.sort(result.mods, function(a, b) return a.name:lower() < b.name:lower() end)
    result.frameworkCoverage = frameworkCoverage
    Scanner.endDiag()
    return result
end

-- Refreshes a scanned model's values from disk without any directory listing (no console
-- window): every known config file is re-read and re-parsed in place. Files that vanished are
-- dropped; files ADDED since launch are picked up at the next game launch (the file inventory
-- is listed once, at boot). Cheap enough to run on every panel open.
function Scanner.refresh(model, log)
    log = log or function() end
    model.totalEntries = 0
    local keptMods = {}
    for _, mod in ipairs(model.mods) do
        local keptFiles = {}
        for _, file in ipairs(mod.files) do
            local raw = FsUtil.readFile(file.path)
            if raw == nil then
                log("dropped " .. mod.name .. "\\" .. file.rel .. ": no longer readable")
            else
                local content = raw
                if content:sub(1, 3) == UTF8_BOM then
                    content = content:sub(4)
                end
                local entries = parserFor(file).parse(content)
                if entries == nil or #entries == 0 then
                    log("dropped " .. mod.name .. "\\" .. file.rel
                        .. ": no longer parseable")
                else
                    -- A freshly re-parsed framework file loses its source/schema tagging;
                    -- reattach it the same way the boot-time scan did.
                    if type(file.format) == "string" and file.format:sub(1, 10) == "framework:" then
                        local frameworkKey = file.format:match("^framework:(.+)$")
                        local schema = Frameworks.schemaFor(frameworkKey, mod.name)
                        for _, entry in ipairs(entries) do
                            entry.source = file.format
                            if schema and schema.options ~= nil then
                                entry.schema = schema.options[entry.key]
                            end
                        end
                    end
                    if file.class == "advanced" then
                        for _, entry in ipairs(entries) do
                            entry.advanced = true
                        end
                    end
                    file.entries = entries
                    file.content = content
                    keptFiles[#keptFiles + 1] = file
                    model.totalEntries = model.totalEntries + #entries
                end
            end
        end
        local removed = Scope.dedupeExposed(keptFiles)
        if removed > 0 then
            model.totalEntries = model.totalEntries - removed
            log(mod.name .. ": " .. removed
                .. " key(s) already exposed by a higher-precedence file")
        end
        mod.files = dropEmptyFiles(keptFiles)
        if #mod.files > 0 then
            keptMods[#keptMods + 1] = mod
        end
    end
    model.mods = keptMods
    return model
end

-- The boot-time model, scanned once at launch and refreshed (values only, no listing) on each
-- panel open. Holding it here lets the panel open without spawning a console window.
local cachedModel = nil

function Scanner.setCachedModel(model)
    cachedModel = model
end

function Scanner.cachedModel()
    return cachedModel
end

-- Rewrites one file with `edits` (key -> new value), verifying by re-parse before the write
-- touches disk. Returns true, or false and a reason.
function Scanner.writeEdits(file, edits)
    local parser = parserFor(file)
    local raw, readErr = FsUtil.readFile(file.path)
    if raw == nil then
        return false, "cannot read: " .. tostring(readErr)
    end
    local content, bom, encodingErr = prepareContent(raw)
    if content == nil then
        return false, tostring(encodingErr)
    end
    local rewritten, rewriteErr = parser.rewrite(content, edits)
    if rewritten == nil then
        return false, "rewrite failed: " .. tostring(rewriteErr)
    end
    local reparsed = parser.parse(rewritten)
    if reparsed == nil then
        return false, "rewrite produced unparseable content; write aborted"
    end
    local byKey = {}
    for _, entry in ipairs(reparsed) do
        byKey[entry.key] = entry
    end
    for key, newValue in pairs(edits) do
        local entry = byKey[key]
        if entry == nil or entry.value ~= newValue then
            return false, "rewrite verification failed for '" .. key .. "'; write aborted"
        end
    end
    -- A UTF-8 BOM the file arrived with goes back exactly where it was.
    local ok, writeErr = FsUtil.writeFile(file.path, bom .. rewritten)
    if not ok then
        return false, "cannot write: " .. tostring(writeErr)
    end
    return true
end

return Scanner
