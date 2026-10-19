local Dispatcher = require("dispatcher")
local AudioContext = require("audiobookshelf/audiocontext")
local AudiobookshelfBrowser = require("audiobookshelf/audiobookshelfbrowser")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

local Audiobookshelf = WidgetContainer:extend{
    name = "audiobookshelf",
    is_doc_only = false,
}

function Audiobookshelf:onDispatcherRegisterActions()
    -- none atm
end

function Audiobookshelf:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Audiobookshelf:addToMainMenu(menu_items)
    menu_items.audiobookshelf = {
        text = _("Audiobookshelf"),
        sorting_hint = "tools",
        callback = function()
            local connect_callback = function()
                UIManager:show(AudiobookshelfBrowser:new())
            end
            NetworkMgr:runWhenOnline(connect_callback)
        end
    }
end

-- Keep ABS in step with the player across device events. peek() avoids building
-- the audio context for people who only use the ebook side.
function Audiobookshelf:onSuspend()
    local ctx = AudioContext.peek()
    if ctx then ctx.session:suspend() end
end

function Audiobookshelf:onResume()
    local ctx = AudioContext.peek()
    if ctx then ctx.session:resume() end
end

function Audiobookshelf:onExit()
    local ctx = AudioContext.peek()
    if ctx then ctx.session:detach() end
end

return Audiobookshelf
