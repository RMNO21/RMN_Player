-- drop-load.lua — Drag & drop subtitles or audio tracks onto the player
-- Loads them instantly on the current video instead of adding to playlist

local mp = require("mp")
local msg = require("mp.msg")

local sub_exts = {
    srt = true, ass = true, ssa = true, sub = true,
    idx = true, vtt = true, sup = true, lrc = true,
}
local audio_exts = {
    ac3 = true, dts = true, flac = true, mka = true,
    ogg = true, opus = true, wav = true, m4a = true,
    aiff = true, ape = true, mp3 = true,
}

local function get_ext(path)
    return path:match("%.([^%.]+)$")
end

-- Primary: mpv ≥0.39 fires a "drop" event before loading the file
mp.register_event("drop", function(event)
    if not event or not event.data then return end

    local path = event.data
    local ext = get_ext(path)
    if not ext then return end
    ext = ext:lower()

    if sub_exts[ext] then
        msg.info("Loading subtitle: " .. path)
        mp.commandv("sub-add", path, "select")
    elseif audio_exts[ext] then
        msg.info("Loading audio track: " .. path)
        mp.commandv("audio-add", path, "select")
    end
    -- For video files, do nothing — let mpv handle it normally (playlist append)
end)

-- Fallback: if "drop" event isn't available, detect via file-loaded
-- This catches files that slipped through and got added to the playlist
local handled_files = {}

mp.register_event("file-loaded", function()
    local path = mp.get_property("path")
    if not path then return end

    -- Skip if already handled by the drop event
    if handled_files[path] then
        handled_files[path] = nil
        return
    end

    local ext = get_ext(path)
    if not ext then return end
    ext = ext:lower()

    if sub_exts[ext] then
        msg.info("Fallback: loading subtitle from playlist: " .. path)
        mp.commandv("sub-add", path, "select")
        mp.commandv("playlist-remove", "current")
    elseif audio_exts[ext] then
        msg.info("Fallback: loading audio track from playlist: " .. path)
        mp.commandv("audio-add", path, "select")
        mp.commandv("playlist-remove", "current")
    end
end)

msg.info("drop-load.lua loaded — drag subtitles or audio onto the player")
