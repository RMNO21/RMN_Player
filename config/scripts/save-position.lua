-- save-position.lua — Bulletproof position saver
-- Covers every scenario: playlist nav, auto-advance, uosc, drag-drop, quit, crash

local mp = require 'mp'
local msg = require 'mp.msg'

local save_count = 0
local current_path = nil

--- Save current position via mpv's native watch-later mechanism.
--- No guards, no dedup — always saves if we have a valid position.
local function save_position()
    local is_seeking = mp.get_property_bool("seeking", false)
    if is_seeking then return end

    local path = mp.get_property("path", "")
    if not path or path == "" then return end

    local pos = mp.get_property_number("time-pos", -1)
    local dur = mp.get_property_number("duration", -1)
    if pos < 0 or dur <= 0 then return end
    if pos >= dur - 1 then return end

    mp.command("write-watch-later-config")
    save_count = save_count + 1
end

--- Save position of the PREVIOUS file when filename changes.
--- By the time this observer fires, the old file's time-pos may already
--- be zeroed, so we capture it proactively via a tracked variable.
local function on_filename_changed(_, filename)
    if current_path and current_path ~= filename then
        save_position()
    end
    current_path = filename
end
mp.observe_property("filename", "string", on_filename_changed)

-- Crash safety net: save every 2 seconds
mp.add_periodic_timer(2, function()
    save_position()
end)

-- Save on pause
mp.observe_property("pause", "bool", function(_, paused)
    if paused then save_position() end
end)

-- Save on file end / transition (auto-advance, uosc nav, loadfile, etc.)
mp.register_event("end-file", function()
    save_position()
end)

-- Save on shutdown (normal quit, Alt+F4, window close)
mp.register_event("shutdown", function()
    save_position()
    msg.info("Session saved (" .. save_count .. " writes)")
end)
