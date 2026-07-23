-- Episode Tracker v4
-- Fixes: watched status persists through EOF position reset
-- Adds: rewatch detection, manual mark watched/unwatched via uosc

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local WATCHED_THRESHOLD = 90    -- percentage to mark as watched
local REWATCH_THRESHOLD = 5     -- seconds into rewatch before tracking resets

local db_path = ""
local db = {}
local rewatch_active = false    -- true while re-tracking a previously-watched file
local current_path = nil        -- path of the currently playing file (saved before end-file)
local save_timer = nil

-- ── Config directory ───────────────────────────────────────────────────────

local function get_config_dir()
    local ok, dir = pcall(function() return mp.command_native({"expand-path", "~~home/"}) end)
    if ok and dir and dir ~= "" then return dir end
    local appdata = os.getenv("APPDATA")
    if appdata then return appdata .. "/mpv" end
    return "."
end

-- ── JSON encode ────────────────────────────────────────────────────────────

local function json_encode(val)
    if val == nil then return "null" end
    local t = type(val)
    if t == "boolean" then return val and "true" or "false" end
    if t == "number" then return tostring(val) end
    if t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    end
    if t == "table" then
        local is_arr = (#val > 0)
        if is_arr then
            local parts = {}
            for _, v in ipairs(val) do parts[#parts + 1] = json_encode(v) end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            local keys = {}
            for k in pairs(val) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                parts[#parts + 1] = json_encode(k) .. ":" .. json_encode(val[k])
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- ── JSON decode ────────────────────────────────────────────────────────────

local function json_decode(str)
    if not str or str == "" or str == "null" then return nil end
    local pos = 1
    local len = #str

    local function skip_ws()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1
            else break end
        end
    end

    local parse_val

    local function parse_str()
        if str:sub(pos, pos) ~= '"' then return nil end
        pos = pos + 1
        local parts = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(parts) end
            if c == '\\' then
                pos = pos + 1
                local e = str:sub(pos, pos)
                if e == 'n' then parts[#parts + 1] = '\n'
                elseif e == 't' then parts[#parts + 1] = '\t'
                elseif e == 'r' then parts[#parts + 1] = '\r'
                elseif e == '"' then parts[#parts + 1] = '"'
                elseif e == '\\' then parts[#parts + 1] = '\\'
                else parts[#parts + 1] = e end
            else
                parts[#parts + 1] = c
            end
            pos = pos + 1
        end
        return table.concat(parts)
    end

    local function parse_num()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= len and str:sub(pos, pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parse_obj()
        pos = pos + 1
        skip_ws()
        local obj = {}
        if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while true do
            skip_ws()
            local key = parse_str()
            skip_ws()
            if str:sub(pos, pos) == ':' then pos = pos + 1 end
            obj[key] = parse_val()
            skip_ws()
            if str:sub(pos, pos) == ',' then pos = pos + 1
            elseif str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        end
    end

    local function parse_arr()
        pos = pos + 1
        skip_ws()
        local arr = {}
        if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        while true do
            arr[#arr + 1] = parse_val()
            skip_ws()
            if str:sub(pos, pos) == ',' then pos = pos + 1
            elseif str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        end
    end

    parse_val = function()
        skip_ws()
        local c = str:sub(pos, pos)
        if c == '"' then return parse_str()
        elseif c == '{' then return parse_obj()
        elseif c == '[' then return parse_arr()
        elseif c == 't' then pos = pos + 4; return true
        elseif c == 'f' then pos = pos + 5; return false
        elseif c == 'n' then pos = pos + 4; return nil
        else return parse_num() end
    end

    local ok, result = pcall(parse_val)
    if ok then return result end
    return nil
end

-- ── Database ───────────────────────────────────────────────────────────────

local function init_db()
    db_path = get_config_dir() .. "/episode-tracker.json"
    local f = io.open(db_path, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        if raw and #raw > 2 then
            local data = json_decode(raw)
            if data and type(data) == "table" then db = data end
        end
    end
    if not db.episodes then db.episodes = {} end

    -- Normalize path keys: merge backslash entries into forward-slash entries
    local normalized = {}
    for key, entry in pairs(db.episodes) do
        local norm_key = key:gsub("\\", "/"):lower()
        if normalized[norm_key] then
            -- Merge: keep the entry with more data (higher position or duration)
            local existing = normalized[norm_key]
            if (entry.position or 0) > (existing.position or 0) or
               (entry.duration or 0) > (existing.duration or 0) then
                normalized[norm_key] = entry
            end
        else
            normalized[norm_key] = entry
        end
    end
    db.episodes = normalized
end

local function save_db()
    if not db_path or db_path == "" then return end
    local f = io.open(db_path, "w")
    if f then f:write(json_encode(db)); f:close() end
end

-- ── Utilities ──────────────────────────────────────────────────────────────

local function format_time(sec)
    if not sec or sec <= 0 then return "0:00" end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = math.floor(sec % 60)
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function progress_bar(pct, width)
    width = width or 16
    local filled = math.floor(pct / 100 * width + 0.5)
    return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function detect_episode(name)
    if not name then return nil, nil end
    local s, e = name:upper():match("S(%d+)%W*E(%d+)")
    if e then return tonumber(s), tonumber(e) end
    e = name:upper():match("E[Pp%.]?%s*(%d+)")
    if e and not name:upper():match("EXTENDED") and not name:upper():match("EXTRA") then
        return 0, tonumber(e)
    end
    e = name:match("%[(%d+)%]")
    if e then return 0, tonumber(e) end
    e = name:match("[%s%-_%.](%d+)[%s%-_%.]")
    if e and tonumber(e) and tonumber(e) < 100 then return 0, tonumber(e) end
    return nil, nil
end

local function parse_path(fullpath)
    if not fullpath or fullpath == "" then return nil, nil, nil, nil end
    local path = fullpath:gsub("\\", "/")
    local filename = path:match("([^/]+)$")
    local parent = path:match("(.+)/[^/]+$")
    local folder = parent and parent:match("([^/]+)$") or nil
    return path, filename, parent, folder
end

local function find_episodes_in_dir(dirpath)
    if not dirpath or dirpath == "" then return {} end
    local episodes = {}
    local files = utils.readdir(dirpath, "files")
    if not files then return {} end
    for _, fname in ipairs(files) do
        local lower = fname:lower()
        if lower:match("%.mkv$") or lower:match("%.mp4$") or lower:match("%.avi$") or
           lower:match("%.webm$") or lower:match("%.mov$") or lower:match("%.ts$") or
           lower:match("%.flv$") or lower:match("%.wmv$") or lower:match("%.m4v$") or
           lower:match("%.mpg$") or lower:match("%.mpeg$") or lower:match("%.m2ts$") then
            local s, e = detect_episode(fname)
            episodes[#episodes + 1] = {
                filepath = dirpath .. "/" .. fname,
                filename = fname,
                season = s or 0,
                episode = e or 0,
            }
        end
    end
    table.sort(episodes, function(a, b)
        if a.season ~= b.season then return a.season < b.season end
        return a.episode < b.episode
    end)
    return episodes
end

-- ── Core tracking ──────────────────────────────────────────────────────────

local function get_db_entry(key)
    if not db.episodes[key] then
        db.episodes[key] = { watched = false, position = 0, duration = 0 }
    end
    return db.episodes[key]
end

-- Called every 2 seconds while playing. Sets watched=true at 90% and never clears it.
local function track_playback()
    local raw_path = current_path or mp.get_property("path", "")
    if not raw_path or raw_path == "" then return end

    -- Normalize path (backslashes to forward) for consistent DB keys
    local path = raw_path:gsub("\\", "/")
    local _, filename, parent, folder = parse_path(path)
    local season, episode = detect_episode(filename)
    local pos = mp.get_property_number("time-pos", 0) or 0
    local dur = mp.get_property_number("duration", 0) or 0
    local pct = dur > 0 and (pos / dur * 100) or 0
    local key = path:lower()

    local entry = get_db_entry(key)

    -- If already watched and not in rewatch mode, check if user passed rewatch threshold
    if entry.watched and not rewatch_active then
        if pos >= REWATCH_THRESHOLD then
            rewatch_active = true
            msg.info("Rewatch mode activated for " .. filename)
        end
    end

    -- Update show metadata (always update duration regardless of watched status)
    entry.show = folder or entry.show or "Unknown"
    entry.season = season or entry.season or 0
    entry.episode = episode or entry.episode or 0
    entry.filename = filename
    entry.filepath = path
    entry.dirpath = parent
    if dur > 0 then entry.duration = dur end

    -- KEY FIX: once watched=true, never overwrite it with position data
    if pct >= WATCHED_THRESHOLD and not entry.watched then
        entry.watched = true
        entry.position = 0
        msg.info("Marked watched: " .. filename)
    end

    -- Only update position if not yet fully watched (or during active rewatch)
    if not entry.watched or rewatch_active then
        entry.position = pos
    end

    -- Always update last_watch timestamp
    entry.last_watch = os.time()

    -- Update last_played
    db.last_played = {
        path = path,
        position = pos,
        filename = filename,
        watched = entry.watched,
        timestamp = os.time(),
    }

    save_db()
end

-- ── Save progress for a specific path ──────────────────────────────────────

local function save_progress_for(raw_path)
    if not raw_path or raw_path == "" then return end
    local path = raw_path:gsub("\\", "/")
    local key = path:lower()
    local entry = db.episodes[key]
    if not entry then return end

    local pos = mp.get_property_number("time-pos", 0) or 0
    local dur = mp.get_property_number("duration", 0) or 0
    local pct = dur > 0 and (pos / dur * 100) or 0

    if pct >= WATCHED_THRESHOLD and not entry.watched then
        entry.watched = true
        entry.position = 0
    end

    if not entry.watched then
        entry.position = pos
    end

    entry.duration = dur
    save_db()
end

-- ── File loaded handler ────────────────────────────────────────────────────

local function on_file_loaded()
    local raw_new = mp.get_property("path", "")
    if not raw_new or raw_new == "" then return end
    local new_path = raw_new:gsub("\\", "/")

    -- Save the PREVIOUS file's progress before switching
    if current_path and current_path ~= new_path then
        save_progress_for(current_path)
    end

    current_path = new_path

    local _, filename, _, folder = parse_path(new_path)
    local key = new_path:lower()
    rewatch_active = false

    local entry = get_db_entry(key)

    -- Update metadata
    local season, episode = detect_episode(filename)
    entry.show = folder or entry.show or "Unknown"
    entry.season = season or entry.season or 0
    entry.episode = episode or entry.episode or 0
    entry.filename = filename
    entry.filepath = new_path
    entry.dirpath = folder and parse_path(new_path) or entry.dirpath
    save_db()

    -- Visual feedback
    if entry.watched then
        local ep_str = ""
        if season and season > 0 then ep_str = string.format(" S%02dE%02d", season, episode)
        elseif episode then ep_str = string.format(" EP%02d", episode) end
        mp.osd_message((folder or "") .. ep_str .. "  Status: Watched", 3)
    end

    msg.info("Loaded: " .. (folder or "?") .. "/" .. (filename or "?"))
end

-- ── End file handler ───────────────────────────────────────────────────────

local function on_end_file()
    if current_path and current_path ~= "" then
        save_progress_for(current_path)
        current_path = nil
    end
end

-- ── Episode Status command ─────────────────────────────────────────────────

local function cmd_episode_status()
    local path, filename, parent, folder = parse_path(mp.get_property("path", ""))
    if not filename then mp.osd_message("No file playing", 3) return end

    local season, episode = detect_episode(filename)
    local show = folder or "Unknown Show"
    local pos = mp.get_property_number("time-pos", 0) or 0
    local dur = mp.get_property_number("duration", 0) or 0
    local pct = dur > 0 and math.floor(pos / dur * 100) or 0

    local disk_episodes = parent and find_episodes_in_dir(parent) or {}
    local disk_total = #disk_episodes
    local disk_index = "?"
    local key_lower = path:lower()
    if disk_total > 0 then
        for i, ep in ipairs(disk_episodes) do
            if ep.filepath:lower() == key_lower then disk_index = tostring(i); break end
        end
    end

    local is_watched = db.episodes[key_lower] and db.episodes[key_lower].watched

    local ep_str = "N/A"
    if episode then
        if season and season > 0 then ep_str = string.format("S%02dE%02d", season, episode)
        else ep_str = string.format("EP%02d", episode) end
    end

    local lines = {
        show,
        string.format("Episode %s/%d  %s%s", disk_index, disk_total, ep_str, is_watched and " [WATCHED]" or ""),
        string.format("%s / %s  %d%%", format_time(pos), format_time(dur), pct),
        progress_bar(pct),
    }
    mp.osd_message(table.concat(lines, "\n"), 5)
end

-- ── TV Show Status command ─────────────────────────────────────────────────

local function cmd_tv_status()
    local path, filename, parent, folder = parse_path(mp.get_property("path", ""))
    if not folder then mp.osd_message("No show detected", 3) return end

    local disk_episodes = parent and find_episodes_in_dir(parent) or {}
    local disk_total = #disk_episodes

    local watched = 0
    local first_unwatched_idx = nil
    for i, ep in ipairs(disk_episodes) do
        local key = ep.filepath:lower()
        if db.episodes[key] and db.episodes[key].watched then
            watched = watched + 1
        elseif not first_unwatched_idx then
            first_unwatched_idx = i
        end
    end

    local pct = disk_total > 0 and math.floor(watched / disk_total * 100) or 0

    local lines = {
        folder,
        string.format("%d%% complete (%d/%d)", pct, watched, disk_total),
    }

    if first_unwatched_idx and disk_episodes[first_unwatched_idx] then
        local ep = disk_episodes[first_unwatched_idx]
        local code
        if ep.season > 0 then code = string.format("S%02dE%02d", ep.season, ep.episode)
        elseif ep.episode > 0 then code = string.format("EP%02d", ep.episode)
        else code = ep.filename end
        lines[#lines + 1] = "Resume: " .. code
    else
        lines[#lines + 1] = "All watched!"
    end

    lines[#lines + 1] = ""

    local bar_w = 8
    local range = 10
    local shown = 0

    -- Find current episode index in the sorted list
    local current_idx = nil
    local cur_path = mp.get_property("path", ""):gsub("\\", "/"):lower()
    for i, ep in ipairs(disk_episodes) do
        if ep.filepath:lower() == cur_path then current_idx = i; break end
    end

    -- Center window around current episode, or first unwatched if not found
    local center = current_idx or first_unwatched_idx or 1
    local start_idx = math.max(1, center - range)
    local end_idx = math.min(disk_total, center + range)

    if start_idx > 1 then lines[#lines + 1] = string.format("  ... (%d earlier)", start_idx - 1) end

    for i = start_idx, end_idx do
        local ep = disk_episodes[i]
        local key = ep.filepath:lower()
        local entry = db.episodes[key]
        local ep_watched = entry and entry.watched
        local ep_pos = entry and entry.position or 0
        local ep_dur = entry and entry.duration or 0
        local ep_pct = ep_dur > 0 and math.floor(ep_pos / ep_dur * 100) or 0

        local code
        if ep.season > 0 then code = string.format("S%02dE%02d", ep.season, ep.episode)
        elseif ep.episode > 0 then code = string.format("EP%02d", ep.episode)
        else code = ep.filename:sub(1, 12) end

        local filled = math.floor(ep_pct / 100 * bar_w + 0.5)
        local bar = string.rep("█", filled) .. string.rep("░", bar_w - filled)
        local mark = ep_watched and " ✓" or ""
        local cur_path = mp.get_property("path", ""):gsub("\\", "/")
        if cur_path and cur_path:lower() == key then mark = mark .. " ▶" end

        lines[#lines + 1] = string.format("%s %s %d%%%s", code, bar, ep_pct, mark)
        shown = shown + 1
    end

    mp.osd_message(table.concat(lines, "\n"), 8)
end

-- ── Open Last Played command ───────────────────────────────────────────────

local function cmd_open_last()
    local target, pos

    if db.last_played and db.last_played.path and db.last_played.path ~= "" then
        target = db.last_played.path
        pos = db.last_played.position or 0
    end

    if not target or target == "" then
        local wl_dir = get_config_dir() .. "/watch_later"
        local stat = utils.file_info(wl_dir)
        if stat and stat.is_dir then
            local files = utils.readdir(wl_dir, "files")
            if files then
                local newest_time, newest_file = 0, nil
                for _, fname in ipairs(files) do
                    local fpath = wl_dir .. "/" .. fname
                    local fi = utils.file_info(fpath)
                    if fi and fi.mtime and fi.mtime > newest_time then
                        newest_time = fi.mtime
                        newest_file = fpath
                    end
                end
                if newest_file then
                    local f = io.open(newest_file, "r")
                    if f then
                        local content = f:read("*a")
                        f:close()
                        local p = content:match("path=(.+)%s*$")
                        local s = content:match("start=(%d+%.?%d*)")
                        if p and p ~= "" then
                            target = p
                            pos = s and tonumber(s) or 0
                        end
                    end
                end
            end
        end
    end

    if not target or target == "" then
        mp.osd_message("No last played file found", 3)
        return
    end

    local stat = utils.file_info(target)
    if not stat then
        mp.osd_message("File not found: " .. (target:match("([^/\\]+)$") or target), 3)
        return
    end

    mp.commandv("loadfile", target)

    local function do_resume()
        local cur = mp.get_property("path", "")
        if cur and cur:lower() == target:lower() and pos and pos > 1 then
            mp.commandv("seek", tostring(pos), "absolute")
            mp.osd_message("Resumed at " .. format_time(pos), 3)
        end
        mp.unregister_event(do_resume)
    end
    mp.register_event("file-loaded", do_resume)
end

-- ── Mark Watched / Unwatched ───────────────────────────────────────────────

local function cmd_mark_watched()
    local path = mp.get_property("path", "")
    if not path or path == "" then mp.osd_message("No file playing", 3) return end
    local key = path:gsub("\\", "/"):lower()
    local entry = get_db_entry(key)
    entry.watched = true
    entry.position = 0
    save_db()
    mp.osd_message("Marked as Watched", 2)
end

local function cmd_mark_unwatched()
    local path = mp.get_property("path", "")
    if not path or path == "" then mp.osd_message("No file playing", 3) return end
    local key = path:gsub("\\", "/"):lower()
    local entry = get_db_entry(key)
    entry.watched = false
    entry.position = 0
    rewatch_active = false
    save_db()
    mp.osd_message("Marked as Unwatched", 2)
end

-- ── Event registration ─────────────────────────────────────────────────────

mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", on_end_file)
mp.register_event("shutdown", on_end_file)

-- Periodic tracking every 2 seconds while playing
save_timer = mp.add_periodic_timer(2, function()
    if mp.get_property_number("duration", 0) > 0 then
        track_playback()
    end
end)
save_timer:stop()

mp.observe_property("pause", "bool", function(_, paused)
    if paused then save_timer:stop() else save_timer:resume() end
end)

-- ── Open episode tracker uosc menu ─────────────────────────────────────────

local function open_episode_menu()
    local items = {
        {title = "Episode Status",   value = "script-message episode-tracker-ep-status"},
        {title = "TV Show Status",   value = "script-message episode-tracker-tv-status"},
        {title = "Open Last Played", value = "script-message episode-tracker-last-played"},
        {separator = true},
        {title = "Mark as Watched",   value = "script-message mark-watched"},
        {title = "Mark as Unwatched", value = "script-message mark-unwatched"},
    }
    local json = mp.utils.format_json({type = "episode-tracker", title = "Episode Tracker", items = items})
    mp.commandv("script-message-to", "uosc", "open-menu", json)
end

mp.register_script_message("episode-tracker-menu", open_episode_menu)

-- ── uosc menu message handlers ─────────────────────────────────────────────

mp.register_script_message("episode-tracker-ep-status", cmd_episode_status)
mp.register_script_message("episode-tracker-tv-status", cmd_tv_status)
mp.register_script_message("episode-tracker-last-played", cmd_open_last)
mp.register_script_message("mark-watched", cmd_mark_watched)
mp.register_script_message("mark-unwatched", cmd_mark_unwatched)

-- ── Init ───────────────────────────────────────────────────────────────────

init_db()
msg.info("Episode Tracker v5 loaded")
