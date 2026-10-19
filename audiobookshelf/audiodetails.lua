local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local AudioContext = require("audiobookshelf/audiocontext")
local Downloader = require("audiobookshelf/audiodownloader")
local PositionMap = require("audiobookshelf/positionmap")
local Store = require("audiobookshelf/audiostore")

local AudioDetails = {}

local function toast(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

local function hms(seconds)
    seconds = math.floor(seconds or 0)
    return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60)
end

local function realFs()
    return {
        mkdir_p = function(dir)
            local path = ""
            for part in dir:gmatch("[^/]+") do
                path = path .. "/" .. part
                if lfs.attributes(path, "mode") ~= "directory" then
                    lfs.mkdir(path)
                    if lfs.attributes(path, "mode") ~= "directory" then return nil end
                end
            end
            return true
        end,
        size = function(path) return lfs.attributes(path, "size") end,
        rename = function(a, b) return os.rename(a, b) end,
        remove = function(path) return os.remove(path) end,
        write = function(path, text)
            local f = io.open(path, "w")
            if not f then return nil end
            f:write(text)
            f:close()
            return true
        end,
    }
end

local function ensureDownloadDir(ctx, callback)
    local dir = ctx.settings:readSetting("download_dir")
    if dir then
        callback(dir)
        return
    end
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            ctx.settings:saveSetting("download_dir", path)
            ctx.settings:flush()
            callback(path)
        end,
    }:chooseDir(G_reader_settings:readSetting("lastdir"))
end

local function preflightMessage(err)
    if err == "file_too_large" then
        return _("A file in this book is larger than 4 GB, which the Kindle storage cannot hold.")
    elseif err == "no_space" then
        return _("Not enough free space on the Kindle for this book.")
    end
    return T(_("Cannot download: %1"), tostring(err))
end

function AudioDetails.show(item_id)
    local ctx = AudioContext.get()
    local item = ctx.api:getLibraryItem(item_id)
    if not item then
        toast(_("Could not load book details. Check network and settings."))
        return
    end
    local tracks, total = PositionMap.buildTracks(item)
    if #tracks == 0 then
        toast(_("This item has no playable audio files."))
        return
    end
    local meta = (item.media and item.media.metadata) or {}
    local title = meta.title or _("Untitled")
    local author = meta.authorName or ""

    local dialog
    local render

    local function reopen()
        if dialog then UIManager:close(dialog) end
        render()
    end

    local function doDownload()
        ensureDownloadDir(ctx, function(download_dir)
            local dir = ctx.store:dirFor(download_dir, title, item_id)
            local entry = Store.makeEntry(item_id, title, author, dir, tracks, total)
            local free
            local ok, usage = pcall(util.diskUsage, download_dir)
            if ok and type(usage) == "table" then free = usage.available end
            local pre, perr = Downloader.preflight(entry, free)
            if not pre then
                toast(preflightMessage(perr), 5)
                return
            end
            local msg
            local done, err = Downloader.run({
                api = ctx.api, fs = realFs(), entry = entry,
                on_progress = function(i, n)
                    if msg then UIManager:close(msg) end
                    msg = InfoMessage:new{ text = T(_("Downloading %1 of %2…"), i, n) }
                    UIManager:show(msg)
                    UIManager:forceRePaint()
                end,
            })
            if msg then UIManager:close(msg) end
            if done then
                ctx.store:put(entry)
                toast(T(_("Saved to:\n%1"), entry.dir), 4)
                reopen()
            else
                toast(T(_("Download failed: %1"), tostring(err)), 5)
            end
        end)
    end

    local function doDelete()
        local entry = ctx.store:get(item_id)
        if not entry then return end
        if ctx.session:isActive(item_id) then ctx.session:stop() end
        for i = 1, #entry.tracks do os.remove(entry.tracks[i].path) end
        os.remove(entry.m3u)
        lfs.rmdir(entry.dir)
        ctx.store:remove(item_id)
        reopen()
    end

    local function doPlay()
        local entry = ctx.store:get(item_id)
        local ok, note = ctx.session:start(entry)
        if not ok then
            if note == "kinamp_missing" then
                toast(_("KinAMP's KOReader plugin was not found. Install KinAMP first."), 5)
            else
                toast(T(_("Cannot start playback: %1"), tostring(note)), 5)
            end
            return
        end
        if note == "offline" then
            toast(_("Audiobookshelf is unreachable. Resuming from the last position saved on this Kindle."), 5)
        end
        reopen()
    end

    local function doSyncNow()
        local pos, why = ctx.session:syncNow()
        if pos then
            toast(T(_("Synced at %1"), hms(pos)))
        else
            toast(T(_("Nothing synced (%1)"), tostring(why)))
        end
    end

    render = function()
        local entry = ctx.store:get(item_id)
        local downloaded = entry and entry.complete
        local playing = ctx.session:isActive(item_id)
        local info = T(_("%1\n%2\nLength: %3\nTracks: %4\n%5"),
            title, author, hms(total), #tracks,
            downloaded and _("Downloaded") or _("Not downloaded"))
        local buttons = {
            {
                downloaded
                    and { text = _("Delete download"), callback = doDelete }
                    or { text = _("Download"), callback = doDownload },
            },
            {
                downloaded and (playing
                    and { text = _("Stop"), callback = function() ctx.session:stop(); reopen() end }
                    or { text = _("Play / Resume"), callback = doPlay })
                    or { text = _("Play / Resume"), enabled = false, callback = function() end },
                { text = _("Sync now"), enabled = playing and true or false, callback = doSyncNow },
            },
            {
                { text = _("Close"), callback = function() UIManager:close(dialog) end },
            },
        }
        dialog = ButtonDialog:new{ title = info, buttons = buttons }
        UIManager:show(dialog)
    end

    render()
end

return AudioDetails
