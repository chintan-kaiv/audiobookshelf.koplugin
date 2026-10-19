-- Thin adapter over KinAMP's own KOReader module. KinAMP must be installed.
local Client = {}

local function backend()
    local ok, B = pcall(require, "kinamp_backend")
    if ok and type(B) == "table" then return B end
    return nil
end

function Client.available()
    return backend() ~= nil
end

-- true when the commands reached a running daemon; false when KinAMP had to be
-- launched (the caller then waits for it). Overwrites KinAMP's internal queue.
function Client.playFromIndex(index, paths)
    local B = backend()
    if not B then return false end
    return B.play_from_index(index, paths) and true or false
end

function Client.seek(seconds)
    local B = backend()
    if B then B.seek(seconds) end
end

function Client.stop()
    local B = backend()
    if B then B.stop() end
end

function Client.getStatus()
    local B = backend()
    if not B then return nil end
    return B.get_status()
end

function Client.waitUntilRunning(callback)
    local B = backend()
    if not B then
        callback(false)
        return
    end
    B.wait_until_running(callback)
end

return Client
