-- Lists every scanned setting and whether it has a real description, as TSV on stdout.
-- Runs under desktop Lua 5.4 against a live install, read-only:
--   lua dump_gaps.lua <UE4SS Mods directory> <ManagedMods directory>
-- Columns: mod, class, file, key, rowKind, value, status (described | missing), ownLine, block.
local scriptDir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
package.path = scriptDir .. "\\..\\..\\Scripts\\?.lua;" .. package.path

local Present = require("present")
local Scanner = require("scanner")

local modsDir, managedModsDir = arg[1], arg[2]
assert(modsDir, "usage: lua dump_gaps.lua <Mods dir> <ManagedMods dir>")

local model, err = Scanner.scan(function() end, modsDir, { allMods = true })
assert(model, err)
Present.decorate(model, managedModsDir)

local function clean(text)
    if text == nil then
        return ""
    end
    return (tostring(text):gsub("[\r\n\t]+", " "))
end

print(table.concat({ "mod", "class", "file", "key", "rowKind", "value", "status", "ownLine",
    "block" }, "\t"))
for _, mod in ipairs(model.mods) do
    for _, file in ipairs(mod.files) do
        for _, entry in ipairs(file.entries) do
            local status = entry.undescribed and "missing" or "described"
            local ownLine, block = "", ""
            if file.content ~= nil then
                ownLine = clean(Present.ownLineFor(file.content, entry.from))
                block = clean(Present.commentBlockFor(file.content, entry.from))
            end
            print(table.concat({ mod.name, file.class or "", file.rel, entry.key,
                entry.rowKind or "", clean(entry.value), status, ownLine, block }, "\t"))
        end
    end
end
