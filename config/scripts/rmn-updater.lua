-- rmn-updater.lua: Simple Check & Auto-Update for RMN-Player
-- Checks version on GitHub; if newer, automatically downloads and applies update.

local mp = require("mp")
local msg = require("mp.msg")

local is_running = false

local function check_and_update()
    if is_running then
        mp.osd_message("Update check already in progress...", 2)
        return
    end

    is_running = true
    mp.osd_message("Checking for updates...", 3)
    msg.info("Checking for RMN-Player updates...")

    local appdata = os.getenv("APPDATA") or ""
    local script_path = appdata .. "\\RMN-Player\\update-rmn.ps1"

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", script_path
        }
    }, function(success, res)
        is_running = false

        if not success or not res or res.status ~= 0 then
            mp.osd_message("Update check failed. Please check internet connection.", 4)
            msg.warn("Update check failed")
            return
        end

        local out = (res.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")

        if out:match("^UP_TO_DATE:(.+)") then
            local v = out:match("^UP_TO_DATE:(.+)")
            mp.osd_message("RMN-Player is up to date (v" .. v .. ")", 3)
            msg.info("RMN-Player is up to date (v" .. v .. ")")
        elseif out:match("^UPDATED:(.+)") then
            local v = out:match("^UPDATED:(.+)")
            mp.osd_message("New update installed: v" .. v .. "! Restart player to apply.", 7)
            msg.info("New update installed: v" .. v)
        elseif out:match("^ERROR:") then
            local err = out:gsub("^ERROR:%s*", "")
            mp.osd_message("Update error: " .. err, 4)
            msg.warn("Update error: " .. err)
        else
            mp.osd_message("RMN-Player is up to date.", 3)
        end
    end)
end

mp.register_script_message("check-rmn-update", check_and_update)
msg.info("rmn-updater.lua loaded")
