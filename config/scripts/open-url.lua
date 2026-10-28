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
			os.execute('mkdir "' .. cache_dir:gsub('/', '\\') .. '" 2>nul')
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
		"-I", "-L", "-s", "-k",
		"--connect-timeout", "5",
		"--max-time", "8",
		"-A", user_agent,
	}
	if origin and origin ~= "" then
		table.insert(args, "-e")
		table.insert(args, origin)
	end
	table.insert(args, candidate_url)

	mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		capture_stderr = true,
		args = args,
	}, function(success, res, err)
		if success and res and res.status == 0 and res.stdout then
			local is_valid = false
			for status_line in res.stdout:gmatch("HTTP/%d%.?%d?%s+(%d%d%d)") do
				local code = tonumber(status_line)
				if code and (code == 200 or code == 206 or (code >= 300 and code < 400)) then
					is_valid = true
					break
				end
			end

			if is_valid then
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
local function play_stream_url(url, target_pos)
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
	local resume_pos = target_pos
	if not resume_pos and entry and entry.position and entry.position > 15 then
		resume_pos = entry.position
	end

	if resume_pos and resume_pos > 15 then
		pending_resume_pos = resume_pos
		-- Pre-set start position so demuxer directly requests byte range without downloading prior parts!
		mp.set_property("start", tostring(math.floor(resume_pos)))
	else
		pending_resume_pos = nil
		mp.set_property("start", "none")
	end

	local display_title = (entry and entry.title and entry.title ~= "") and entry.title or (filename ~= "" and filename or url:sub(1, 40))
	mp.osd_message("Loading stream: " .. display_title, 4)
	msg.info("Playing stream: " .. url .. " (Canonical: " .. canonical_key .. ", Start: " .. tostring(pending_resume_pos or 0) .. "s)")

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

	local origin = get_origin(path)
	local canonical_key = get_canonical_key(path)
	current_stream_key = canonical_key

	-- Ensure headers are injected on any stream file
	local user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	mp.set_property("user-agent", user_agent)
	if origin then
		mp.set_property("http-header-fields", "Referer: " .. origin .. ",Origin: " .. origin:gsub("/$", ""))
	end

	-- Check for saved watch-later position
	if pending_resume_pos and pending_resume_pos > 15 then
		local pos = pending_resume_pos
		pending_resume_pos = nil
		local mins = math.floor(pos / 60)
		local secs = math.floor(pos % 60)
		mp.osd_message(string.format("▶ Resumed at %02d:%02d (Saved Stream Position)", mins, secs), 3.5)
		mp.set_property("start", "none")
	else
		local entry = stream_history[canonical_key]
		if entry and entry.position and entry.position > 15 then
			local cur_time = mp.get_property_number("time-pos") or 0
			if cur_time < 10 then
				local pos = entry.position
				mp.add_timeout(0.1, function()
					mp.commandv("seek", pos, "absolute", "exact")
					local mins = math.floor(pos / 60)
					local secs = math.floor(pos % 60)
					mp.osd_message(string.format("▶ Resumed at %02d:%02d (Saved Stream Position)", mins, secs), 3.5)
				end)
			end
		end
	end

	-- Trigger background probing for next episodes on any online stream
	mp.add_timeout(2.0, function()
		probe_and_queue_next(path, origin, 1, 3)
	end)
end)

-- Periodic position record
local function record_current_position()
	if not current_stream_key then return end
	local pos = mp.get_property_number("time-pos")
	local dur = mp.get_property_number("duration")
	if not pos or pos < 5 then return end

	local title = mp.get_property("media-title") or mp.get_property("filename") or current_stream_key
	local path = mp.get_property("path") or ""

	local save_pos = pos
	local is_completed = false
	if dur and dur > 0 and pos >= (dur * 0.92) then
		save_pos = 0
		is_completed = true
	end

	stream_history[current_stream_key] = {
		position = save_pos,
		duration = dur or 0,
		title = title,
		url = path,
		completed = is_completed,
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
local function get_recent_history_items(max_count)
	local sorted = {}
	for k, v in pairs(stream_history) do
		if v and (v.url or v.title) then
			table.insert(sorted, {key = k, data = v})
		end
	end
	table.sort(sorted, function(a, b) return (a.data.updated_at or 0) > (b.data.updated_at or 0) end)

	local items = {}
	for i = 1, math.min(max_count or 10, #sorted) do
		local entry = sorted[i]
		local d = entry.data
		local pos = d.position or 0
		local dur = d.duration or 0
		local pct = dur > 0 and math.floor((pos / dur) * 100) or 0
		local mins = math.floor(pos / 60)
		local secs = math.floor(pos % 60)
		local dur_mins = math.floor(dur / 60)
		local dur_secs = math.floor(dur % 60)

		local time_str = ""
		if d.completed then
			time_str = "Completed (Replay from 00:00)"
		elseif dur > 0 then
			time_str = string.format("%02d:%02d / %02d:%02d (%d%%)", mins, secs, dur_mins, dur_secs, pct)
		elseif pos > 0 then
			time_str = string.format("%02d:%02d", mins, secs)
		else
			time_str = "Watched"
		end

		local title = d.title or entry.key
		if title:match("^https?://") then
			local _, fn = get_canonical_key(title)
			title = fn ~= "" and fn or title:sub(1, 40)
		end

		table.insert(items, {
			title = title,
			hint = time_str,
			icon = "play_arrow",
			value = "script-message open-url-load-history " .. entry.key,
		})
	end
	return items
end

local function open_url_prompt()
	local clip = get_clipboard_text()
	local recent_items = get_recent_history_items(8)

	local palette_items = {}
	if #recent_items > 0 then
		table.insert(palette_items, {
			title = "─── Recently Watched (Click to Resume) ───",
			align = "center",
			muted = true,
			selectable = false,
		})
		for _, item in ipairs(recent_items) do
			table.insert(palette_items, item)
		end
	else
		table.insert(palette_items, {
			title = "Type or paste link and press Enter",
			align = "center",
			muted = true,
			italic = true,
			selectable = false,
		})
	end

	local menu_data = {
		type = "open-url-input",
		title = "Paste / Enter Stream URL",
		footnote = "Paste link or click a recently watched stream to resume",
		search_style = "palette",
		search_debounce = "submit",
		search_suggestion = (clip and is_web_url(clip)) and clip or "",
		on_search = "script-message open-url-load",
		on_paste = "script-message open-url-load",
		items = palette_items,
		keep_open = false,
	}
	local ok, json = pcall(utils.format_json, menu_data)
	if ok and json then
		mp.commandv("script-message-to", "uosc", "open-menu", json)
	end
end

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
		end)
	end

	table.insert(menu_items, {
		title = "Enter Stream URL...",
		value = "script-message open-url-prompt",
		hint = "Type or paste link",
		icon = "edit",
		separator = true,
	end)

	-- Recently Watched Section
	local recent_items = get_recent_history_items(10)
	if #recent_items > 0 then
		table.insert(menu_items, {
			title = "Recently Watched Streams",
			hint = tostring(#recent_items) .. " saved",
			icon = "history",
			items = recent_items,
		end)

		-- Show top recent items directly in the main list for 1-click instant resume!
		for i = 1, math.min(3, #recent_items) do
			local item = recent_items[i]
			table.insert(menu_items, {
				title = "Resume: " .. item.title,
				hint = item.hint,
				icon = "play_arrow",
				value = item.value,
			end)
		end

		table.insert(menu_items, {
			title = "Clear Stream Watch History",
			value = "script-message open-url-clear-history",
			icon = "delete",
			separator = true,
		end)
	end

	-- Engine Settings
	local cache_mb = get_cache_size_mb()
	table.insert(menu_items, {
		title = "Autoload Next Episodes",
		hint = autoload_episodes and "Enabled" or "Disabled",
		value = "script-message open-url-toggle-autoload",
		active = autoload_episodes,
	end)

	table.insert(menu_items, {
		title = "Purge Stream Disk Cache",
		hint = tostring(cache_mb) .. " MB",
		value = "script-message open-url-purge-cache",
	end)

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
mp.register_script_message("open-url-prompt", open_url_prompt)

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
		play_stream_url(entry.url, entry.position)
	else
		mp.osd_message("History entry not found", 2)
	end
end)

mp.register_script_message("open-url-clear-history", function()
	stream_history = {}
	save_history()
	mp.osd_message("Stream watch history cleared", 2)
	open_url_menu()
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
mp.add_timeout(1.0, prune_cache)

msg.info("open-url.lua (Online Stream Engine) loaded successfully")
