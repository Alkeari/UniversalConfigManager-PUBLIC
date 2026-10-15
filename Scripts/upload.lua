-- Publishes a compiled request list to catbox.moe and returns the link, so a player pastes one
-- URL into the request thread instead of the file's contents.
--
-- The upload is authenticated with the mod author's own catbox account hash
-- (Config.upload.userhash). Catbox refuses an ANONYMOUS api.php upload outright ("Invalid
-- uploader", reproduced against both hosts 2026-09-06); with the hash it accepts, the link is
-- permanent, and the files land in one account the author can delete from. The hash ships inside
-- the mod, which is a deliberate trade: the account exists for exactly this and nothing else,
-- so a leaked hash costs nothing but that account.
--
-- Transport is `curl.exe`, which Microsoft ships in System32 on every Windows 10 1803 and later.
-- It is driven through a GENERATED .cmd FILE rather than one long command string. The string
-- form worked from desktop Lua and failed inside the game with the server reporting "No file!",
-- meaning curl posted with no file attached: something between UE4SS's os.execute and cmd.exe
-- was eating the quoting that a leading-quote command depends on. A batch file has no such
-- parsing: every argument sits on its own line exactly as written, and the only thing quoted at
-- the call site is the batch file's own path.
--
-- Nothing here decides to upload. The page shows the player what is published and where before
-- offering the action; this module runs the transport once that choice is made.
local Config = require("config")
local FsUtil = require("fsutil")
local log = require("logger")

local Upload = {}

-- A path this module will not write into a command. The request file is written by this mod into
-- its own folder with a sanitized name, so a quote or a newline here means something is wrong
-- rather than something to escape around.
local FORBIDDEN = "[\"\r\n%%]"

function Upload.pathIsSafe(path)
    return type(path) == "string" and path ~= "" and path:find(FORBIDDEN) == nil
end

-- Windows accepts either separator, but curl and cmd have both been seen to disagree about a
-- mixed path, and the path this mod builds IS mixed: the script directory comes back with
-- forward slashes and everything appended to it uses backslashes.
function Upload.windowsPath(path)
    return (tostring(path or ""):gsub("/", "\\"))
end

-- Whether the transport exists on this machine. A plain file probe, never a spawn: asking curl
-- its version would cost the very console flash this only pays for on a real click.
function Upload.available()
    local root = os.getenv("SystemRoot")
    if root == nil or root == "" then
        return false
    end
    local handle = io.open(root .. Config.upload.curlSuffix, "rb")
    if handle == nil then
        return false
    end
    handle:close()
    return true
end

function Upload.curlPath()
    return Upload.windowsPath((os.getenv("SystemRoot") or "") .. Config.upload.curlSuffix)
end

-- The batch file's contents. Pure, so the suite reads exactly what will run without running it.
-- Returns nil plus a reason when it would not be safe to write.
function Upload.script(filePath, outputPath)
    if not Upload.pathIsSafe(filePath) then
        return nil, "the list's path cannot be put in a command"
    end
    if not Upload.pathIsSafe(outputPath) then
        return nil, "the reply file's path cannot be put in a command"
    end
    local settings = Config.upload
    local parts = {
        "@echo off",
        "\"" .. Upload.curlPath() .. "\""
            .. " -s -S --max-time " .. tostring(settings.timeoutSeconds)
            .. " -F \"reqtype=fileupload\""
            .. (settings.userhash ~= nil and settings.userhash ~= ""
                and (" -F \"userhash=" .. settings.userhash .. "\"") or "")
            .. (settings.expiry ~= nil and settings.expiry ~= ""
                and (" -F \"time=" .. settings.expiry .. "\"") or "")
            .. " -F \"fileToUpload=@" .. Upload.windowsPath(filePath) .. "\""
            .. " \"" .. settings.endpoint .. "\""
            .. " > \"" .. Upload.windowsPath(outputPath) .. "\" 2>&1",
    }
    return table.concat(parts, "\r\n") .. "\r\n"
end

-- How the batch file is handed to the shell. cmd /c strips the first and last quote of a
-- command that begins with one as soon as anything special sits between them, and
-- "C:\Program Files (x86)\..." is exactly that. A single pair therefore leaves cmd running
-- `C:\Program`, the batch never runs, and the player is told the upload produced no reply.
-- A second pair survives the strip as a correctly quoted path (review, 2026-09-06).
function Upload.launchCommand(scriptPath)
    return "\"\"" .. Upload.windowsPath(scriptPath) .. "\"\""
end

-- Every upload lands in ONE account belonging to the mod's author, so a pathological file is
-- the author's problem rather than the player's. A request list is kilobytes; anything past
-- the cap is a bug upstream and is refused rather than sent.
function Upload.sizeIsSane(filePath)
    local handle = io.open(filePath, "rb")
    if handle == nil then
        return false, "the list could not be opened to upload"
    end
    local size = handle:seek("end") or 0
    handle:close()
    if size <= 0 then
        return false, "the list is empty"
    end
    if size > Config.upload.maxBytes then
        return false, "the list is larger than this mod will upload"
    end
    return true
end

-- What the host said, turned into a link or a reason. Catbox answers with the bare URL on
-- success and a plain sentence on failure, so anything that is not a URL is the failure text.
-- What the host said, turned into a link or a reason. Catbox answers with the bare URL on
-- success and a plain sentence on failure. curl's own warnings land in the same file (-S
-- writes them to stderr and the batch merges the streams), so the reply is read LINE BY LINE
-- rather than as one blob: a stray warning beside a good URL used to turn a successful
-- public upload into a failure whose link was then unrecoverable (review, 2026-09-06).
function Upload.parseReply(reply)
    local text = tostring(reply or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil, "the file host said nothing"
    end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed:match("^" .. Config.upload.replyPattern .. "$") ~= nil then
            return trimmed
        end
    end
    -- Keep the host's own words, trimmed: they are the only diagnosis a player can act on.
    return nil, (text:gsub("%s+", " "):sub(1, Config.upload.maxReplyChars))
end

-- Runs the transport. Returns the URL, or nil plus a reason. Never raises.
function Upload.publish(filePath)
    if not Upload.available() then
        return nil, "curl.exe was not found in this Windows installation"
    end
    local outputPath = filePath .. Config.upload.replySuffix
    local scriptPath = filePath .. Config.upload.scriptSuffix
    local script, why = Upload.script(filePath, outputPath)
    if script == nil then
        return nil, why
    end
    local sizeOk, why = Upload.sizeIsSane(filePath)
    if not sizeOk then
        return nil, why
    end
    local written, writeErr = FsUtil.writeFile(scriptPath, script)
    if not written then
        return nil, "could not write the upload command: " .. tostring(writeErr)
    end
    -- Any answer left by a previous attempt goes first: reading a stale one would report an
    -- old link, or an old failure, as though it belonged to this upload.
    pcall(function() os.remove(outputPath) end)
    -- Doubled quotes on purpose: see Upload.launchCommand.
    local ok, how, code = pcall(function()
        return os.execute(Upload.launchCommand(scriptPath))
    end)
    if not ok then
        return nil, "the upload command could not be started"
    end
    -- os.execute answers false or nil when the command itself could not run. Checking it is
    -- what makes the branch above reachable at all (review, 2026-09-06).
    if how == false or how == nil then
        return nil, "the upload command did not run (" .. tostring(code) .. ")"
    end
    local reply = FsUtil.readFile(outputPath)
    pcall(function() os.remove(outputPath) end)
    -- The batch file is deliberately NOT deleted. A game that writes a script, runs it and
    -- then erases it is the shape of a dropper whatever it actually did; leaving it in the
    -- mod's own requests folder lets a suspicious player, or an antivirus vendor, read exactly
    -- what ran (review, 2026-09-06).
    if reply == nil then
        return nil, "the upload produced no reply to read"
    end
    local url, failure = Upload.parseReply(reply)
    if url == nil then
        -- The host's exact words, and the reply verbatim: the previous failure ("No file!") was
        -- only diagnosable because the raw answer survived (2026-09-06).
        log.warn("upload refused: " .. tostring(failure)
            .. " | raw reply: " .. tostring(reply):gsub("%s+", " "):sub(1, 200))
        return nil, failure
    end
    log.info("list published: " .. url)
    return url
end

return Upload
