-- One active audiobook: starts playback at the right place and keeps ABS in
-- step with the player. All collaborators are injected (see the plan).
local PositionMap = require("audiobookshelf/positionmap")
local Policy = require("audiobookshelf/progresspolicy")
local AbsProgress = require("audiobookshelf/absprogress")
local Store = require("audiobookshelf/audiostore")

local Session = { TICK_SECONDS = 30, MAX_MISSES = 3 }
Session.__index = Session

function Session.new(deps)
    local self = setmetatable({ deps = deps, active = nil }, Session)
    self.tick_fn = function() self:_tick() end
    return self
end

function Session:isActive(item_id)
    return self.active ~= nil and (item_id == nil or self.active.entry.item_id == item_id)
end

function Session:_schedule()
    if not self.active then return end
    self.deps.sched.unschedule(self.tick_fn)
    self.deps.sched.scheduleIn(Session.TICK_SECONDS, self.tick_fn)
end

function Session:_end()
    self.deps.sched.unschedule(self.tick_fn)
    self.active = nil
end

function Session:_tick()
    if not self.active then return end
    self:_sync(false)
    self:_schedule()
end

function Session:_sync(force)
    local a = self.active
    if not a then return nil, "inactive" end
    local d = self.deps
    local pos, reason = Policy.decide({
        status = d.kinamp.getStatus(),
        tracks = a.entry.tracks,
        paths = a.paths,
        last_sent = a.last_sent,
        min_delta = force and 1 or nil,
    })
    if not pos then
        if reason == "no_daemon" then
            a.misses = a.misses + 1
            if a.misses >= Session.MAX_MISSES then self:_end() end
        else
            a.misses = 0
        end
        return nil, reason
    end
    a.misses = 0
    d.store:setLastSent(a.entry.item_id, pos) -- always keep it locally for offline resume
    if d.api:setProgress(a.entry.item_id, AbsProgress.body(pos, a.entry.total)) then
        a.last_sent = pos
        return pos
    end
    return nil, "offline"
end

function Session:start(entry)
    local d = self.deps
    if not d.kinamp.available() then return nil, "kinamp_missing" end
    if not entry or not entry.tracks or #entry.tracks == 0 then return nil, "no_tracks" end
    if self.active then
        self:_sync(true)
        self:_end()
    end

    local remote, code = d.api:getProgress(entry.item_id)
    local offline = (remote == nil and code ~= 404)
    local seconds, last_sent
    if remote and remote.isFinished then
        seconds, last_sent = 0, nil
    elseif remote and remote.currentTime then
        seconds, last_sent = remote.currentTime, remote.currentTime
    else
        seconds, last_sent = entry.last_sent or 0, entry.last_sent
    end

    local index, offset = PositionMap.toTrackPos(entry.tracks, seconds)
    local paths = Store.paths(entry)
    self.active = { entry = entry, paths = paths, last_sent = last_sent, misses = 0 }

    local function afterStart()
        if not self.active or self.active.entry ~= entry then return end
        if offset > 0 then d.kinamp.seek(offset) end
        self:_schedule()
    end

    if d.kinamp.playFromIndex(index, paths) then
        d.sched.scheduleIn(0.5, afterStart)
    else
        d.kinamp.waitUntilRunning(function(up)
            if up then
                d.sched.scheduleIn(1.0, afterStart)
            else
                self:_end()
                d.notify("KinAMP did not start.")
            end
        end)
    end
    return true, offline and "offline" or nil
end

function Session:stop()
    if not self.active then return end
    self:_sync(true)
    self:_end()
    self.deps.kinamp.stop()
end

function Session:detach()
    if not self.active then return end
    self:_sync(true)
    self:_end()
end

function Session:suspend()
    if not self.active then return end
    self:_sync(true)
    self.deps.sched.unschedule(self.tick_fn)
end

function Session:resume()
    if self.active then self:_tick() end
end

function Session:syncNow()
    return self:_sync(true)
end

return Session
