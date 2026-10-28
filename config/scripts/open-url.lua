-- open-url.lua — RMN-Player Advanced Online Stream Engine
-- Robust high-speed streaming, anti-hotlink referer injection,
-- canonical watch-later resumption, auto-episode detection/autoloading,
-- and smart zero-bloat cache pruning.

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

-- ============================================================================
-- Configuration & Paths
-- ============================================================================
local function get_config_dir()
	local ok, dir = pcall(function() return mp.command_native({"expand-path", "~~home/"}) end)
	if ok and dir and dir ~= "" then return dir end
	local appdata = os.getenv("APPDATA")
	if appdata then return appdata .. "/RMN-Player" end
	return "."
end

local config_dir = get_config_dir()
local history_file = config_dir .. "/stream-watch-history.json"
local cache_dir = config_dir .. "/temp_stream_cache"

-- Auto-cleanup limits
local MAX_CACHE_MB = 2500     -- 2.5 GB max cache size
local TARGET_CACHE_MB = 1000  -- Prune down to 1.0 GB
local MAX_CACHE_AGE_SEC = 172800 -- 48 hours

-- State
local stream_history = {}
local current_stream_key = nil
local pending_resume_pos = nil
local autoload_episodes = true
local last_saved_pos = 0

-- Ensure temp cache directory exists
local function ensure_cache_dir()
	local info = utils.file_info(cache_dir)
	if not info or not info.is_dir then
		pcall(function()
			mp.command_native({"subprocess", playback_only = false, args = {"powershell", "-NoProfile", "-Command", "New-Item -ItemType Directory -Path '" .. cache_dir .. "' -Force"}})
		end)
	end
end
ensure_cache_dir()

-- ============================================================================
-- JSON Persistence
-- ============================================================================
local function load_history()
	local f = io.open(history_file, "r")
	if f then
		local content = f:read("*a")
		f:close()
		if content and content ~= "" then
			local ok, data = pcall(utils.parse_json, content)
			if ok and type(data) == "table" then
				stream_history = data
				msg.debug("Loaded stream watch history (" .. #stream_history .. " entries)")
				return
			end
		end
	end
	stream_history = {}
end

local function save_history()
	if not stream_history then return end
	local ok, json_str = pcall(utils.format_json, stream_history)
	if ok and json_str then
		local f = io.open(history_file, "w")
		if f then
			f:write(json_str)
			f:close()
		end
	end
end

-- ============================================================================
-- Smart Cache Pruning Engine (LRU + TTL)
-- ============================================================================
local function prune_cache()
	local files = utils.readdir(cache_dir, "files")
	if not files or #files == 0 then return 0 end

	local file_list = {}
	local total_bytes = 0
	local now = os.time()

	for _, fn in ipairs(files) do
		local fp = cache_dir .. "/" .. fn
		local info = utils.file_info(fp)
		if info and info.is_file then
			total_bytes = total_bytes + info.size
			table.insert(file_list, {
				path = fp,
				size = info.size,
				mtime = info.mtime or 0,
			})
		end
	end

	local total_mb = math.floor(total_bytes / (1024 * 1024))
	local deleted_count = 0

	-- 1. TTL Check: Remove files older than 48 hours
	local remaining = {}
	for _, item in ipairs(file_list) do
		if item.mtime > 0 and (now - item.mtime) > MAX_CACHE_AGE_SEC then
			os.remove(item.path)
			deleted_count = deleted_count + 1
			total_bytes = total_bytes - item.size
		else
			table.insert(remaining, item)
		end
	end

	-- 2. LRU Check: If still exceeding MAX_CACHE_MB, sort oldest first and delete
	if total_bytes > (MAX_CACHE_MB * 1024 * 1024) then
		table.sort(remaining, function(a, b) return a.mtime < b.mtime end)
		local target_bytes = TARGET_CACHE_MB * 1024 * 1024
		for _, item in ipairs(remaining) do
			if total_bytes <= target_bytes then break end
			if os.remove(item.path) then
				deleted_count = deleted_count + 1
				total_bytes = total_bytes - item.size
			end
		end
	end

	local final_mb = math.max(0, math.floor(total_bytes / (1024 * 1024)))
	if deleted_count > 0 then
		msg.info(string.format("Stream cache pruned: removed %d files, current size: %d MB", deleted_count, final_mb))
	end
	return final_mb
end

local function get_cache_size_mb()
	local files = utils.readdir(cache_dir, "files")
	if not files then return 0 end
	local total = 0
	for _, fn in ipairs(files) do
		local info = utils.file_info(cache_dir .. "/" .. fn)
		if info and info.size then total = total + info.size end
	end
	return math.floor(total / (1024 * 1024))
end

-- ============================================================================
-- URL Processing & Canonical Keys (Anti-Expiry Resumption)
-- ============================================================================
local function is_web_url(url)
	if not url or type(url) ~= "string" then return false end
	return url:match("^https?://") ~= nil or url:match("^ytdl://") ~= nil
end

-- Extracts origin domain for Referer/Origin header injection
local function get_origin(url)
	if not url then return nil end
	local proto, host = url:match("^(https?://)([^/?#:]+)")
	if proto and host then
		return proto .. host .. "/"
	end
	return nil
end

-- Strips ephemeral query parameters to create a permanent signature
local function get_canonical_key(url)
	if not url then return "" end
	local base_path = url:match("^(https?://[^?#]+)") or url:match("^([^?#]+)") or url
	base_path = base_path:lower()

	-- Also extract clean filename
	local filename = base_path:match("([^/]+)$") or base_path
	return base_path, filename
end

-- ============================================================================
-- Episode Detection & Probing Engine
-- ============================================================================
local EP_PATTERNS = {
	-- S04E03 or s04.e03 or S4_EP03
	{pattern = "([Ss]%d+[%._%-%s]*[Ee][Pp]?)(%d+)", kind = "season_ep"},
	-- .E03. or _ep03_ or -E3-
	{pattern = "([%._%-%s][Ee][Pp]?)(%d+)([%._%-%s])", kind = "ep_only"},
	-- Episode_03 or episode.3
	{pattern = "([%._%-%s][Ee]pisode[%._%-%s]*)(%d+)", kind = "episode_word"},
	-- Part_03 or part.3
	{pattern = "([%._%-%s][Pp]art[%._%-%s]*)(%d+)", kind = "part_word"},
}

local function get_next_episode_url(url, step)
	step = step or 1
	for _, p in ipairs(EP_PATTERNS) do
		local pre, num_str, post = url:match(p.pattern)
		if pre and num_str then
			local num = tonumber(num_str)
			if num then
				local next_num = num + step
				local fmt = string.format("%%0%dd", #num_str)
				local next_num_str = string.format(fmt, next_num)

				local s_idx, e_idx = url:find(p.pattern)
				if s_idx and e_idx then
					local matched_sub = url:sub(s_idx, e_idx)
					local replaced_sub
					if post then
						replaced_sub = pre .. next_num_str .. post
					else
						replaced_sub = pre .. next_num_str
					end
					return url:sub(1, s_idx - 1) .. replaced_sub .. url:sub(e_idx + 1), next_num_str
				end
			end
		end
	end
	return nil, nil
end

-- Asynchronous probing of next episode via curl.exe HEAD request
local function probe_and_queue_next(base_url, origin, ep_offset, max_lookahead)
	if not autoload_episodes then return end
	ep_offset = ep_offset or 1
	max_lookahead = max_lookahead or 3
	if ep_offset > max_lookahead then return end

	local candidate_url, next_ep_label = get_next_episode_url(base_url, ep_offset)
	if not candidate_url then return end

	-- Check if candidate is already in playlist
	local count = mp.get_property_number("playlist-count", 0)
	for i = 0, count - 1 do
		local pl_path = mp.get_property("playlist/" .. i .. "/filename")
		if pl_path and pl_path == candidate_url then
			-- Already queued, probe the one after
			probe_and_queue_next(base_url, origin, ep_offset + 1, max_lookahead)
			return
		end
	end

	local user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	local args = {
		"curl.exe",
		"-I", "-L", "-s",
		"--connect-timeout", "4",
		"--max-time", "6",
		"-A", user_agent,
		candidate_url,
	}
	if origin and origin ~= "" then
		table.insert(args, 8, "-e")
		table.insert(args, 9, origin)
	end

	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		capture_stderr = true,
		args = args,
	}, function(success, res, err)
		if success and res and res.status == 0 and res.stdout then
			local status = res.stdout:match("HTTP/%d%.?%d?%s+(%d%d%d)")
			local code = tonumber(status)
			if code and (code == 200 or code == 206 or (code >= 300 and code < 400)) then
				msg.info("Autoloaded next online episode: " .. candidate_url)
				mp.commandv("loadfile", candidate_url, "append")
				mp.osd_message("Added next episode: E" .. tostring(next_ep_label), 3)

				-- Recursively probe the following episode!
				mp.add_timeout(1.0, function()
					probe_and_queue_next(base_url, origin, ep_offset + 1, max_lookahead)
				end)
				return
			end
		end
		msg.debug("Probe finished for candidate offset: " .. ep_offset)
	end)
end

-- ============================================================================
-- Stream Playback Engine (Header Injection & URL Loading)
-- ============================================================================
local function play_stream_url(url)
	if not url or url == "" then return end
	url = url:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^["\']', ''):gsub('["\']$', '')

	if not is_web_url(url) then
		mp.osd_message("Invalid URL protocol. Must start with http:// or https://", 3)
		return
	end

	-- Extract Origin & Referer
	local origin = get_origin(url)
	local user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

	-- Inject headers to bypass 403 Forbidden / anti-hotlink protections
	mp.set_property("user-agent", user_agent)
	if origin then
		mp.set_property("http-header-fields", "Referer: " .. origin .. ",Origin: " .. origin:gsub("/$", ""))
	end

	local canonical_key, filename = get_canonical_key(url)
	current_stream_key = canonical_key

	-- Check for saved watch-later position
	local entry = stream_history[canonical_key]
	if entry and entry.position and entry.position > 15 then
		pending_resume_pos = entry.position
	else
		pending_resume_pos = nil
	end

	mp.osd_message("Loading stream: " .. (filename ~= "" and filename or url:sub(1, 40)), 4)
	msg.info("Playing stream: " .. url .. " (Canonical: " .. canonical_key .. ")")

	-- Load file
	mp.commandv("loadfile", url, "replace")

	-- Background probe next episodes
	mp.add_timeout(2.5, function()
		probe_and_queue_next(url, origin, 1, 3)
	end)
end

-- ============================================================================
-- Watch-Later Resumption & Position Tracker
-- ============================================================================
mp.register_event("file-loaded", function()
	local path = mp.get_property("path") or ""
	if not is_web_url(path) then
		current_stream_key = nil
		pending_resume_pos = nil
		return
	end

	local canonical_key = get_canonical_key(path)
	current_stream_key = canonical_key

	if pending_resume_pos and pending_resume_pos > 15 then
		local pos = pending_resume_pos
		pending_resume_pos = nil
		mp.add_timeout(0.2, function()
			mp.commandv("seek", pos, "absolute", "exact")
			local mins = math.floor(pos / 60)
			local secs = math.floor(pos % 60)
			mp.osd_message(string.format("Resumed at %02d:%02d (Saved Stream Position)", mins, secs), 3)
		end)
	end
end)

-- Periodic position record
local function record_current_position()
	if not current_stream_key then return end
	local pos = mp.get_property_number("time-pos")
	local dur = mp.get_property_number("duration")
	if not pos or pos < 5 then return end

	local title = mp.get_property("media-title") or mp.get_property("filename") or current_stream_key
	local path = mp.get_property("path") or ""

	stream_history[current_stream_key] = {
		position = pos,
		duration = dur or 0,
		title = title,
		url = path,
		updated_at = os.time(),
	}
	save_history()
end

local save_timer = mp.add_periodic_timer(5, record_current_position)

mp.register_event("pause", record_current_position)
mp.register_event("end-file", record_current_position)
mp.register_event("shutdown", function()
	record_current_position()
	prune_cache()
end)

-- ============================================================================
-- Clipboard Helper
-- ============================================================================
local function get_clipboard_text()
	local text = mp.get_property("clipboard/text")
	if text and text ~= "" then
		text = text:gsub("^%s+", ""):gsub("%s+$", "")
		return text
	end
	return nil
end

-- ============================================================================
-- Interactive uosc Menu
-- ============================================================================
local function open_url_menu()
	local clip = get_clipboard_text()
	local clip_is_url = clip and is_web_url(clip)

	local menu_items = {}

	if clip_is_url then
		local _, clean_name = get_canonical_key(clip)
		local preview = clean_name ~= "" and clean_name or clip:sub(1, 45)
		table.insert(menu_items, {
			title = "▶ Play from Clipboard",
			hint = preview,
			value = "script-message open-url-play-clip",
			bold = true,
		})
	end

	table.insert(menu_items, {
		title = "Paste / Enter URL (Ctrl+V)",
		value = "script-message open-url-prompt",
		hint = "Paste or type link",
	})

	table.insert(menu_items, {separator = true})

	-- History submenu
	local hist_items = {}
	local sorted_history = {}
	for k, v in pairs(stream_history) do
		table.insert(sorted_history, {key = k, data = v})
	end
	table.sort(sorted_history, function(a, b) return (a.data.updated_at or 0) > (b.data.updated_at or 0) end)

	for i = 1, math.min(8, #sorted_history) do
		local item = sorted_history[i]
		local pos = item.data.position or 0
		local dur = item.data.duration or 0
		local pct = dur > 0 and math.floor((pos / dur) * 100) or 0
		local mins = math.floor(pos / 60)
		local secs = math.floor(pos % 60)
		local hint_text = string.format("%02d:%02d (%d%%)", mins, secs, pct)

		table.insert(hist_items, {
			title = item.data.title or item.key,
			hint = hint_text,
			value = "script-message open-url-load-history " .. item.key,
		})
	end

	if #hist_items > 0 then
		table.insert(menu_items, {
			title = "Recent Stream History",
			items = hist_items,
		})
	end

	-- Settings
	local cache_mb = get_cache_size_mb()
	table.insert(menu_items, {
		title = "Autoload Next Episodes",
		hint = autoload_episodes and "Enabled" or "Disabled",
		value = "script-message open-url-toggle-autoload",
		active = autoload_episodes,
	})

	table.insert(menu_items, {
		title = "Purge Stream Disk Cache",
		hint = tostring(cache_mb) .. " MB",
		value = "script-message open-url-purge-cache",
	})

	local menu_data = {
		type = "open-url-master",
		title = "Online Stream Engine",
		footnote = "Press Ctrl+V anytime to paste and stream directly",
		items = menu_items,
		on_paste = "script-message open-url-load",
		keep_open = false,
	}

	local ok, json = pcall(utils.format_json, menu_data)
	if ok and json then
		mp.commandv("script-message-to", "uosc", "open-menu", json)
	end
end

-- ============================================================================
-- Script Messages
-- ============================================================================
mp.register_script_message("open-url-menu", open_url_menu)

mp.register_script_message("open-url-load", function(url)
	play_stream_url(url)
end)

mp.register_script_message("open-url-play-clip", function()
	local clip = get_clipboard_text()
	if clip and is_web_url(clip) then
		play_stream_url(clip)
	else
		mp.osd_message("Clipboard does not contain a valid web URL", 2.5)
	end
end)

mp.register_script_message("open-url-load-history", function(key)
	local entry = stream_history[key]
	if entry and entry.url then
		play_stream_url(entry.url)
	else
		mp.osd_message("History entry not found", 2)
	end
end)

mp.register_script_message("open-url-toggle-autoload", function()
	autoload_episodes = not autoload_episodes
	mp.osd_message("Autoload Next Episodes: " .. (autoload_episodes and "Enabled" or "Disabled"), 2)
	open_url_menu()
end)

mp.register_script_message("open-url-purge-cache", function()
	local cleaned_mb = prune_cache()
	mp.osd_message("Stream cache cleared. Current size: " .. cleaned_mb .. " MB", 2.5)
	open_url_menu()
end)

-- Direct global shortcut: Paste & Play immediately
mp.register_script_message("paste-and-play-stream", function()
	local clip = get_clipboard_text()
	if clip and is_web_url(clip) then
		play_stream_url(clip)
	else
		open_url_menu()
	end
end)

-- Load initial history & clean old cache on startup
load_history()
prune_cache()

msg.info("open-url.lua (Online Stream Engine) loaded successfully")
