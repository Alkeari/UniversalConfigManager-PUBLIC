-- Maps a live row widget's address to the owner record it belongs to. Interaction hooks are
-- class-level and fire for every instance of that class system-wide (vanilla's rows and other
-- mods' rows included), so every callback resolves its Context here and no-ops on a miss.
-- Identity is the object's address; Lua == does not work for UObjects.
local RowTrack = {}

local byAddress = {}

function RowTrack.addressOf(object)
    if object == nil then
        return nil
    end
    local ok, address = pcall(function() return object:GetAddress() end)
    if ok and address ~= nil and address ~= 0 then
        return address
    end
    return nil
end

function RowTrack.track(widget, owner)
    local address = RowTrack.addressOf(widget)
    if address == nil then
        return nil
    end
    byAddress[address] = owner
    return address
end

function RowTrack.untrack(widget)
    local address = RowTrack.addressOf(widget)
    if address ~= nil then
        byAddress[address] = nil
    end
end

function RowTrack.resolve(object)
    local address = RowTrack.addressOf(object)
    if address == nil then
        return nil
    end
    return byAddress[address]
end

return RowTrack
