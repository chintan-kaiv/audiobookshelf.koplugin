-- Builds the real collaborators once and shares them between the UI and the
-- plugin's suspend/resume/exit handlers.
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")

local Api = require("audiobookshelf/audiobookshelfapi")
local Kinamp = require("audiobookshelf/kinampclient")
local Session = require("audiobookshelf/audiosession")
local Store = require("audiobookshelf/audiostore")

local Context = {}
local instance

function Context.get()
    if instance then return instance end
    local config_file = string.gsub(debug.getinfo(1).source, "^@(.+/)[^/]+$", "%1") .. "/../audiobookshelf_config.lua"
    local settings = LuaSettings:open(config_file)
    local store = Store.new(LuaSettings:open(DataStorage:getSettingsDir() .. "/audiobookshelf_audio.lua"))
    local session = Session.new({
        api = Api,
        store = store,
        kinamp = Kinamp,
        sched = {
            scheduleIn = function(seconds, fn) UIManager:scheduleIn(seconds, fn) end,
            unschedule = function(fn) UIManager:unschedule(fn) end,
        },
        notify = function(message)
            UIManager:show(InfoMessage:new{ text = message, timeout = 3 })
        end,
    })
    instance = { api = Api, settings = settings, store = store, session = session, kinamp = Kinamp }
    return instance
end

function Context.peek()
    return instance
end

return Context
