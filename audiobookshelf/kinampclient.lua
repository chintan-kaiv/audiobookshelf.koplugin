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

-- Disconnect and reconnect the connected Bluetooth device through KinAMP's own
-- Bluetooth module (what its menu does). callback(ok) is always called once;
-- ok is false when there is nothing to reconnect or it did not work.
function Client.reconnectBluetooth(callback)
    local loaded, BT = pcall(require, "kinamp_bt")
    if not loaded or type(BT) ~= "table" or not BT.available or not BT.available() then
        callback(false)
        return
    end
    local function connect(mac)
        BT.connect(mac, function(connected) callback(connected and true or false) end)
    end
    local listed, devices = pcall(BT.getConnected)
    local device = listed and devices and devices[1]
    if device and device.mac then
        -- Connect whether or not the disconnect was seen to complete.
        BT.disconnect(device.mac, function() connect(device.mac) end)
        return
    end
    -- Nothing listed as connected yet (the radio was just cycled): connect the
    -- device KinAMP last used, if it remembers one.
    local last = BT.getLastDevice and BT.getLastDevice()
    if last and last.mac then
        connect(last.mac)
    else
        callback(false)
    end
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
