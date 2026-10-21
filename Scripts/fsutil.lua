-- Filesystem helpers. Directory listing rides UE4SS's IterateGameDirectories inside the game and
-- io.popen("dir /b") only outside it; everything else is plain io.
local FsUtil = {}

-- The absolute directory this script file lives in.
function FsUtil.scriptDirectory()
    local source = debug.getinfo(1, "S").source or ""
    source = source:sub(1, 1) == "@" and source:sub(2) or source
    return source:match("^(.*)[/\\][^/\\]+$") or "."
end

function FsUtil.parent(path)
    return path:match("^(.*)[/\\][^/\\]+$")
end

-- True when `path` is an existing directory. Uses the os.rename(path, path) trick (renaming a
-- path onto itself succeeds only if it exists) rather than spawning a cmd process, so a caller
-- can check before deciding whether to create a folder without an io.popen round trip.
function FsUtil.directoryExists(path)
    return os.rename(path, path) and true or false
end

function FsUtil.readFile(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, tostring(err)
    end
    local content = file:read("a")
    file:close()
    return content
end

function FsUtil.writeFile(path, content)
    local file, err = io.open(path, "wb")
    if file == nil then
        return false, tostring(err)
    end
    -- Both results are checked. Ignoring them reported a truncated file as written, and a
    -- truncated request list would have been compiled, uploaded and linked (review,
    -- 2026-09-06).
    local wrote, writeErr = file:write(content)
    local closed, closeErr = file:close()
    if not wrote then
        return false, "could not write: " .. tostring(writeErr)
    end
    if not closed then
        return false, "could not finish writing: " .. tostring(closeErr)
    end
    return true
end

local function listLines(command)
    local ok, pipe = pcall(io.popen, command)
    if not ok or pipe == nil then
        return nil, "io.popen unavailable"
    end
    local lines = {}
    for line in pipe:lines() do
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    pipe:close()
    return lines
end

-- Runs the cmd.exe form first; when that yields nothing (a setup where cmd is unavailable or
-- broken, e.g. some Wine/Proton prefixes), tries the POSIX form. An empty result from both is
-- returned as an empty list only if the POSIX probe also ran, else nil.
local function listWithFallback(cmdCommand, posixCommand)
    local lines, err = listLines(cmdCommand)
    if lines ~= nil and #lines > 0 then
        return lines
    end
    local posixLines = listLines(posixCommand)
    if posixLines ~= nil and #posixLines > 0 then
        return posixLines
    end
    return lines or posixLines, err
end

-- Palworld.exe has no console, so io.popen hands cmd.exe a brand-new visible console window on
-- the player's desktop. UE4SS's IterateGameDirectories walks the game tree in-process instead;
-- the shell listing above stays as the fallback outside UE4SS (the offline suite) and for a path
-- outside the game root.
local function pathSegments(path)
    local out = {}
    for segment in path:gsub("/", "\\"):gmatch("[^\\]+") do
        if segment == ".." then
            out[#out] = nil
        elseif segment ~= "." then
            out[#out + 1] = segment
        end
    end
    return out
end

local function treeChildren(node)
    local children = {}
    for key, child in pairs(node) do
        if type(key) == "string" and key:sub(1, 2) ~= "__" and type(child) == "table"
            and type(child.__name) == "string" then
            children[#children + 1] = child
        end
    end
    table.sort(children, function(a, b) return a.__name:lower() < b.__name:lower() end)
    return children
end

-- The tree node for `path`: false when the path lies inside the game root but does not exist,
-- nil when the tree cannot answer (no UE4SS, or a path outside the game root).
local function treeNode(path)
    if type(IterateGameDirectories) ~= "function" then
        return nil
    end
    local ok, tree = pcall(IterateGameDirectories)
    if not ok or type(tree) ~= "table" then
        return nil
    end
    local gameRoot = nil
    for _, child in ipairs(treeChildren(tree)) do
        if type(child.__absolute_path) == "string" then
            gameRoot = child.__absolute_path:match("^(.*)[\\/][^\\/]+$")
            break
        end
    end
    if gameRoot == nil then
        return nil
    end
    local want, have = pathSegments(path), pathSegments(gameRoot)
    if #want < #have then
        return nil
    end
    for i = 1, #have do
        if want[i]:lower() ~= have[i]:lower() then
            return nil
        end
    end
    local node = tree
    for i = #have + 1, #want do
        local next = nil
        for _, child in ipairs(treeChildren(node)) do
            if child.__name:lower() == want[i]:lower() then
                next = child
                break
            end
        end
        if next == nil then
            return false
        end
        node = next
    end
    return node
end

-- `__files` is walked with pairs, never ipairs or #: the Steam Workshop UE4SS build advances the
-- array index for subdirectories too, so a file that sorts after a subfolder sits behind a hole.
local function treeFilesRecursive(node, out)
    local ok, files = pcall(function() return node.__files end)
    if ok and type(files) == "table" then
        local paths = {}
        for index, file in pairs(files) do
            if type(index) == "number" and type(file) == "table"
                and type(file.__absolute_path) == "string" then
                paths[#paths + 1] = file.__absolute_path
            end
        end
        table.sort(paths, function(a, b) return a:lower() < b:lower() end)
        for _, path in ipairs(paths) do
            out[#out + 1] = path
        end
    end
    for _, child in ipairs(treeChildren(node)) do
        treeFilesRecursive(child, out)
    end
    return out
end

-- Immediate subdirectory names of `path`.
function FsUtil.listDirectories(path)
    local node = treeNode(path)
    if node == false then
        return {}
    end
    if node ~= nil then
        local names = {}
        for _, child in ipairs(treeChildren(node)) do
            names[#names + 1] = child.__name
        end
        return names
    end
    return listWithFallback(
        string.format('dir /b /ad "%s" 2>nul', path),
        string.format('find "%s" -maxdepth 1 -mindepth 1 -type d -printf "%%f\\n" 2>/dev/null',
            path))
end

-- Every file under `path`, recursively, as absolute paths. Records which lister answered
-- (FsUtil.lastListingSource: "game tree" or "shell") for the scan's diagnostic log line.
function FsUtil.listFilesRecursive(path)
    local node = treeNode(path)
    if node == false then
        FsUtil.lastListingSource = "game tree"
        return {}
    end
    if node ~= nil then
        FsUtil.lastListingSource = "game tree"
        return treeFilesRecursive(node, {})
    end
    FsUtil.lastListingSource = "shell"
    return listWithFallback(
        string.format('dir /b /s /a-d "%s" 2>nul', path),
        string.format('find "%s" -type f 2>/dev/null', path))
end

return FsUtil
