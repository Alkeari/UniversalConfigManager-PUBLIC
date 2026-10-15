local Logger = {}

local PREFIX = "[UniversalConfigManager] "

function Logger.info(message)
    print(PREFIX .. "[INFO] " .. tostring(message) .. "\n")
end

function Logger.warn(message)
    print(PREFIX .. "[WARN] " .. tostring(message) .. "\n")
end

function Logger.error(message)
    print(PREFIX .. "[ERROR] " .. tostring(message) .. "\n")
end

return Logger
