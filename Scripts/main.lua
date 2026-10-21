local Config = require("config")
local I18n = require("i18n")
local Inject = require("inject")
local Present = require("present")
local Scanner = require("scanner")
local Staging = require("staging")
local Store = require("store")
local Suppress = require("suppress")
local log = require("logger")

log.info("loading Universal Config Manager v" .. Config.version)

local langOk, langErr = pcall(I18n.refresh)
if langOk then
    log.info("language: " .. I18n.language)
else
    log.warn("language files unreadable, English only: " .. tostring(langErr))
end

-- Boot scan: reports what the panel will offer, then reapplies the journal - every value the
-- user set through this mod is authoritative, so a config file a Workshop update clobbered (or
-- a hand edit changed) is written back to the user's value, each with a log line. The panel
-- itself re-scans on every screen open, so keys a mod update adds appear automatically.
local bootOk, bootErr = pcall(function()
    local model, err = Scanner.scan(function(line) log.info("scan: " .. line) end)
    if model == nil then
        log.warn("boot scan failed: " .. tostring(err))
        return
    end
    local fileCount = 0
    for _, mod in ipairs(model.mods) do
        fileCount = fileCount + #mod.files
    end
    log.info("boot scan: " .. #model.mods .. " mod(s), " .. fileCount .. " config file(s), "
        .. model.totalEntries .. " editable value(s)")
    -- Baselines first (first-seen values feed Restore to Default), then journal authority,
    -- then the model is cached: the panel refreshes values from it without ever re-listing
    -- directories (the shell listing fallback flashes a console window; this keeps listing to boot only).
    Store.recordBaselines(model)
    Staging.reapplyJournal(model)
    local managedModsDir = Scanner.managedModsDirectory()
    Present.decorate(model, managedModsDir)
    model.managedModsDir = managedModsDir
    Scanner.setCachedModel(model)
end)
if not bootOk then
    log.error("boot scan threw: " .. tostring(bootErr))
end

Inject.install()

-- With this mod installed, exactly one thing on screen renders mod configuration. Another
-- framework's own interface is collapsed on sight, unconditionally: two config menus on one
-- screen leave the player guessing which one the game actually reads. Costs nothing on an
-- install that has no such framework: the sweep stops itself once it has looked and found none.
local suppressOk, suppressErr = pcall(Suppress.start)
if not suppressOk then
    log.warn("could not start the config-menu suppression sweep: " .. tostring(suppressErr))
end

log.info("Universal Config Manager ready (open Options to find the Mod Configs tab)")
