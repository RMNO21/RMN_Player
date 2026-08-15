-- loop-cycle.lua: Unified 3-State Loop Controller
-- Cycles: Off -> Loop Playlist (All) -> Loop File (One) -> Off
-- Syncs with user-data/loop-mode for uosc UI button integration

local mp = require("mp")

local function get_current_loop_mode()
    local lf = mp.get_property("loop-file", "no")
    local lp = mp.get_property("loop-playlist", "no")
    if lf == "inf" or lf == "yes" then
        return "file"
    elseif lp == "inf" or lp == "yes" or lp == "force" then
        return "playlist"
    else
        return "off"
    end
end

local function sync_user_data(mode)
    mp.set_property("user-data/loop-mode", mode)
end

local function cycle_loop()
    local current = get_current_loop_mode()
    if current == "off" then
        mp.set_property("loop-file", "no")
        mp.set_property("loop-playlist", "inf")
        sync_user_data("playlist")
        mp.osd_message("Loop: Playlist (All)", 2)
    elseif current == "playlist" then
        mp.set_property("loop-playlist", "no")
        mp.set_property("loop-file", "inf")
        sync_user_data("file")
        mp.osd_message("Loop: Current Episode (One)", 2)
    else
        mp.set_property("loop-file", "no")
        mp.set_property("loop-playlist", "no")
        sync_user_data("off")
        mp.osd_message("Loop: Off", 2)
    end
end

local function on_property_change()
    sync_user_data(get_current_loop_mode())
end

-- Listen to user-data changes from uosc cycle button
local function on_user_data_change(name, value)
    if value == nil or value == "" then return end
    local current = get_current_loop_mode()
    if value == current then return end

    if value == "playlist" then
        mp.set_property("loop-file", "no")
        mp.set_property("loop-playlist", "inf")
        mp.osd_message("Loop: Playlist (All)", 2)
    elseif value == "file" then
        mp.set_property("loop-playlist", "no")
        mp.set_property("loop-file", "inf")
        mp.osd_message("Loop: Current Episode (One)", 2)
    elseif value == "off" then
        mp.set_property("loop-file", "no")
        mp.set_property("loop-playlist", "no")
        mp.osd_message("Loop: Off", 2)
    end
end

mp.register_script_message("cycle-loop", cycle_loop)
mp.observe_property("loop-file", "string", on_property_change)
mp.observe_property("loop-playlist", "string", on_property_change)
mp.observe_property("user-data/loop-mode", "string", on_user_data_change)

-- Initialize on load
sync_user_data(get_current_loop_mode())
