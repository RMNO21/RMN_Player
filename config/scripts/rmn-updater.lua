-- rmn-updater.lua
-- Feature: "Check and update latest version" for RMN-Player
-- Non-blocking update checker with interactive uosc menu and automatic updater.

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local REPO = "RMNO21/RMN_Player"
local GITHUB_URL = "https://github.com/" .. REPO
local RAW_VERSION_URL = "https://raw.githubusercontent.com/" .. REPO .. "/main/version.json"
local API_RELEASES_URL = "https://api.github.com/repos/" .. REPO .. "/releases/latest"

local is_checking = false
local is_updating = false

local function get_config_dir()
    local dir = mp.command_native({"expand-path", "~~home/"})
    if dir and dir ~= "" then
        return dir:gsub("[/\\]$", "")
    end
    local appdata = os.getenv("APPDATA")
    if appdata then return appdata .. "\\RMN-Player" end
    return "."
end

local function get_local_version()
    local config_dir = get_config_dir()
    local path = config_dir .. "/version.json"
    local f = io.open(path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        local data = utils.parse_json(content)
        if data and data.version then
            return data
        end
    end
    -- Fallback default
    return {
        name = "RMN-Player",
        version = "1.0.0",
        version_code = 100,
        release_date = "2026-07-25",
        changelog = "Initial release"
    }
end

local function parse_version(v_str)
    if not v_str then return {0, 0, 0} end
    local clean = tostring(v_str):lower():gsub("^(version|v)", ""):gsub("[^%d%.]", "")
    local parts = {}
    for num in clean:gmatch("(%d+)") do
        parts[#parts + 1] = tonumber(num) or 0
    end
    while #parts < 3 do parts[#parts + 1] = 0 end
    return parts
end

local function is_version_newer(local_v, remote_v)
    local p_local = parse_version(local_v)
    local p_remote = parse_version(remote_v)
    for i = 1, math.max(#p_local, #p_remote) do
        local l = p_local[i] or 0
        local r = p_remote[i] or 0
        if r > l then return true end
        if r < l then return false end
    end
    return false
end

local function open_browser_url(url)
    if not url or url == "" then url = GITHUB_URL end
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        args = { "explorer.exe", url }
    }, function() end)
end

local function show_checking_menu()
    local menu_data = {
        type = "rmn-updater",
        title = "RMN-Player Update",
        items = {
            {
                title = "Checking GitHub for updates...",
                value = "ignore",
                selectable = false,
                italic = true,
                muted = true,
                align = "center",
            }
        },
        keep_open = true,
        search_style = "disabled",
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
end

local function show_update_available_menu(local_v, remote_data)
    local items = {}

    items[#items + 1] = {
        title = "New Version Available: v" .. tostring(remote_data.version),
        hint = "Current: v" .. tostring(local_v.version),
        bold = true,
        selectable = false,
    }

    if remote_data.release_date and #remote_data.release_date > 0 then
        local date_str = tostring(remote_data.release_date):sub(1, 10)
        items[#items + 1] = {
            title = "Release Date: " .. date_str,
            selectable = false,
            muted = true,
        }
    end

    if remote_data.changelog and #remote_data.changelog > 0 then
        local desc = remote_data.changelog:gsub("\r\n", " "):gsub("\n", " ")
        if #desc > 85 then desc = desc:sub(1, 82) .. "..." end
        items[#items + 1] = {
            title = desc,
            selectable = false,
            italic = true,
            muted = true,
        }
    end

    items[#items + 1] = { separator = true }

    items[#items + 1] = {
        title = "Update Now (Download & Install)",
        value = "script-message rmn-apply-update " .. tostring(remote_data.version),
        bold = true,
        hint = "One-click safe update",
    }

    items[#items + 1] = {
        title = "Open GitHub Release Page",
        value = "script-message rmn-open-url " .. (remote_data.html_url or GITHUB_URL),
        hint = "Browser",
    }

    items[#items + 1] = {
        title = "Check Again",
        value = "script-message check-rmn-update",
    }

    local menu_data = {
        type = "rmn-updater",
        title = "RMN-Player Update",
        items = items,
        search_style = "disabled",
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
end

local function show_up_to_date_menu(local_v)
    local items = {
        {
            title = "RMN-Player is up to date!",
            hint = "v" .. tostring(local_v.version),
            bold = true,
            selectable = false,
        },
        {
            title = "You are running the latest version.",
            selectable = false,
            muted = true,
        },
        { separator = true },
        {
            title = "Check Again",
            value = "script-message check-rmn-update",
        },
        {
            title = "Open GitHub Repository",
            value = "script-message rmn-open-url " .. GITHUB_URL,
            hint = "Browser",
        },
    }

    local menu_data = {
        type = "rmn-updater",
        title = "RMN-Player Update",
        items = items,
        search_style = "disabled",
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
end

local function show_error_menu(err_msg)
    local items = {
        {
            title = "Could not check for updates",
            hint = "Network / Offline",
            bold = true,
            selectable = false,
        },
        {
            title = tostring(err_msg or "Please check your internet connection."),
            selectable = false,
            muted = true,
        },
        { separator = true },
        {
            title = "Retry Check",
            value = "script-message check-rmn-update",
        },
        {
            title = "Visit GitHub Repository",
            value = "script-message rmn-open-url " .. GITHUB_URL,
            hint = "Browser",
        },
    }

    local menu_data = {
        type = "rmn-updater",
        title = "RMN-Player Update",
        items = items,
        search_style = "disabled",
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu_data))
end

local function fetch_remote_version(callback)
    -- Step 1: Query raw version.json on main branch via curl.exe
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl.exe", "-s", "--max-time", "6",
            "-H", "User-Agent: RMN-Player-Updater",
            RAW_VERSION_URL
        }
    }, function(success, res, err)
        if success and res and res.status == 0 and res.stdout and #res.stdout > 0 then
            local data = utils.parse_json(res.stdout)
            if data and data.version then
                callback(true, data)
                return
            end
        end

        -- Step 2: Query GitHub Releases API
        mp.command_native_async({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            capture_stderr = true,
            args = {
                "curl.exe", "-s", "--max-time", "6",
                "-H", "User-Agent: RMN-Player-Updater",
                API_RELEASES_URL
            }
        }, function(api_success, api_res)
            if api_success and api_res and api_res.status == 0 and api_res.stdout and #api_res.stdout > 0 then
                local release = utils.parse_json(api_res.stdout)
                if release and release.tag_name then
                    local v = release.tag_name:gsub("^[Vv]ersion", ""):gsub("^[Vv]", "")
                    if v:match("^%d+$") then v = "1.0." .. tostring(tonumber(v) or v) end
                    callback(true, {
                        version = v,
                        release_date = release.published_at or "",
                        changelog = release.body or "Latest release from GitHub",
                        html_url = release.html_url or GITHUB_URL
                    })
                    return
                end
            end

            -- Step 3: Fallback to PowerShell update-rmn.ps1 -CheckOnly
            local config_dir = get_config_dir()
            local ps_script = config_dir .. "\\update-rmn.ps1"
            mp.command_native_async({
                name = "subprocess",
                playback_only = false,
                capture_stdout = true,
                capture_stderr = true,
                args = {
                    "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-Command", "& { if (Test-Path '" .. ps_script .. "') { & '" .. ps_script .. "' -CheckOnly } else { Write-Output '{\"error\":\"no script\"}' } }"
                }
            }, function(ps_success, ps_res)
                if ps_success and ps_res and ps_res.stdout and #ps_res.stdout > 0 then
                    local ps_data = utils.parse_json(ps_res.stdout)
                    if ps_data and ps_data.success then
                        callback(true, {
                            version = ps_data.latest_version,
                            release_date = ps_data.release_date or "",
                            changelog = ps_data.changelog or "",
                            html_url = ps_data.repo_url or GITHUB_URL
                        })
                        return
                    end
                end

                callback(false, nil, "Could not fetch update info from GitHub")
            end)
        end)
    end)
end

local function check_update()
    if is_checking then
        mp.osd_message("Update check in progress...", 2)
        return
    end

    is_checking = true
    mp.osd_message("Checking for RMN-Player updates...", 3)
    show_checking_menu()

    local local_v = get_local_version()

    fetch_remote_version(function(success, remote_data, err_msg)
        is_checking = false

        if not success or not remote_data then
            msg.warn("Update check failed: " .. tostring(err_msg))
            mp.osd_message("Failed to check for updates.", 3)
            show_error_menu(err_msg)
            return
        end

        local is_newer = is_version_newer(local_v.version, remote_data.version)
        if is_newer then
            msg.info("Update available: v" .. remote_data.version .. " (current: v" .. local_v.version .. ")")
            mp.osd_message("New RMN-Player update available: v" .. remote_data.version, 4)
            show_update_available_menu(local_v, remote_data)
        else
            msg.info("RMN-Player is up to date (v" .. local_v.version .. ")")
            mp.osd_message("RMN-Player is up to date (v" .. local_v.version .. ")", 3)
            show_up_to_date_menu(local_v)
        end
    end)
end

local function apply_update(target_version)
    if is_updating then
        mp.osd_message("Update already in progress...", 3)
        return
    end
    is_updating = true
    mp.osd_message("Downloading and applying RMN-Player update...", 5)

    local progress_menu = {
        type = "rmn-updater",
        title = "Updating RMN-Player...",
        items = {
            {
                title = "Downloading latest package from GitHub...",
                value = "ignore",
                selectable = false,
                italic = true,
                align = "center",
            }
        },
        keep_open = true,
        search_style = "disabled",
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(progress_menu))

    local config_dir = get_config_dir()
    local ps_script = config_dir .. "\\update-rmn.ps1"

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-Command", "& { & '" .. ps_script .. "' -ApplyUpdate -Force }"
        }
    }, function(success, res, err)
        is_updating = false
        if success and res and res.status == 0 then
            local data = utils.parse_json(res.stdout or "")
            if data and data.success then
                mp.osd_message("RMN-Player updated successfully! Restart player to take full effect.", 6)
                local done_menu = {
                    type = "rmn-updater",
                    title = "Update Complete!",
                    items = {
                        {
                            title = "RMN-Player updated to v" .. tostring(data.new_version or target_version or "latest"),
                            bold = true,
                            selectable = false,
                        },
                        {
                            title = "Please restart RMN-Player to apply all changes.",
                            selectable = false,
                            muted = true,
                        },
                        { separator = true },
                        {
                            title = "Restart RMN-Player Now",
                            value = "quit",
                        },
                        {
                            title = "Close",
                            value = "ignore",
                        },
                    },
                    search_style = "disabled",
                }
                mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(done_menu))
                return
            end
        end

        mp.osd_message("Update failed. You can update manually via GitHub.", 5)
        local fail_menu = {
            type = "rmn-updater",
            title = "Update Failed",
            items = {
                {
                    title = "Failed to apply automatic update",
                    bold = true,
                    selectable = false,
                },
                { separator = true },
                {
                    title = "Open GitHub to Download Manually",
                    value = "script-message rmn-open-url " .. GITHUB_URL,
                },
                {
                    title = "Close",
                    value = "ignore",
                }
            },
            search_style = "disabled",
        }
        mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(fail_menu))
    end)
end

mp.register_script_message("check-rmn-update", check_update)
mp.register_script_message("rmn-apply-update", apply_update)
mp.register_script_message("rmn-open-url", open_browser_url)

msg.info("rmn-updater.lua loaded")
