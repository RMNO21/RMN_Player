-- Auto-load last played file on startup (only when player is idle with no file)
local done = false

local function try_load_last()
    if done then return end

    local playlist = mp.get_property("playlist")
    if playlist and playlist ~= "[]" and playlist ~= "" then
        done = true
        return
    end

    done = true
    -- Small delay to ensure episode-tracker script is ready to receive
    mp.add_timeout(0.1, function()
        mp.commandv("script-message", "episode-tracker-last-played")
    end)
end

mp.register_idle(try_load_last)
