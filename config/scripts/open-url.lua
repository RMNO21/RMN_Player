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
	local ok2, dir2 = pcall(function() return mp.command_native({"expand-path", "~~/"}) end)
	if ok2 and dir2 and dir2 ~= "" then return dir2 end
	local appdata = os.getenv("APPDATA")
	if appdata then return appdata .. "/RMN-Player" end
	local xdg = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") and (os.getenv("HOME") .. "/.config"))
	if xdg then return xdg .. "/RMN-Player" end
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

-- Live stream connection & buffering state
local is_loading_stream = false
local loading_stream_url = nil
local loading_display_title = nil
local loading_start_time = 0
local buffer_feedback_timer = nil

-- Ensure temp cache directory exists
local function ensure_cache_dir()
	local info = utils.file_info(cache_dir)
	if not info or not info.is_dir then
		pcall(function()
			local is_win = (mp.get_property_native("platform") == "windows" or package.config:sub(1,1) == "\\")
			if is_win then
				os.execute('mkdir "' .. cache_dir:gsub('/', '\\') .. '" 2>nul')
			else
				os.execute('mkdir -p "' .. cache_dir .. '" 2>/dev/null')
			end
		end)
	end
end
ensure_cache_dir()

-- ============================================================================
-- URL Protocol Verification & Canonical Keys
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
	if not url then return "", "" end
	local base_path = url:match("^(https?://[^?#]+)") or url:match("^([^?#]+)") or url
	base_path = base_path:lower()

	-- Also extract clean filename
	local filename = base_path:match("([^/\\\\]+)$") or base_path
	return base_path, filename
end

-- ============================================================================
-- Title Sanitization, Series & Movie Parser Engine
-- ============================================================================
local function is_promo_title(str)
	if not str or str == "" then return true end
	local s = str:lower():match("^%s*(.-)%s*$")
	if s:match("^https?://") or s:match("^www%.") or s:match("^@") then return true end
	if s:match("%.mkv$") or s:match("%.mp4$") or s:match("%.avi$") or s:match("%.webm$") or s:match("%.mov$") or s:match("%.ts$") then
		return false
	end
	local ext = s:match("%.([a-z]+)$")
	if ext then
		local tlds = {
			com=true, ir=true, net=true, org=true, info=true, biz=true, top=true,
			xyz=true, me=true, tv=true, cc=true, co=true, io=true, ru=true, li=true,
			site=true, vip=true, club=true, online=true, pro=true, app=true, dev=true
		}
		if tlds[ext] then return true end
	end
	return false
end

local function parse_series_info(text)
	if not text or text == "" then return nil, nil, nil end
	local filename = text:match("([^/\\\\]+)$") or text
	filename = filename:gsub("%?.*$", "")
	filename = filename:gsub("%.%w%w%w?%w?$", "")

	local norm = filename:gsub("[%._]+", " ")

	-- Pattern 1: S01E02, S1E2, s01e02, S01.E02, S01_E02
	local s, e = norm:match("[%s%[%(]+[sS](%d+)[%s%.%-_]*[eE](%d+)")
	if not s then s, e = norm:match("^[sS](%d+)[%s%.%-_]*[eE](%d+)") end
	if s and e then
		local prefix = norm:match("^(.-)[%s%[%(]+[sS]" .. s) or ""
		local skey = prefix:gsub("[^%w]+", " "):match("^%s*(.-)%s*$"):lower()
		if #skey < 2 then skey = "series" end
		return skey, tonumber(s), tonumber(e)
	end

	-- Pattern 2: Season 2 ... Episode 4
	local s2, e2 = norm:match("[%s%[%(]+[sS]eason[%s%.%-_]*(%d+)[%s%.%-_]+[eE]p?i?s?o?d?e?[%s%.%-_]*(%d+)")
	if not s2 then s2, e2 = norm:match("^[sS]eason[%s%.%-_]*(%d+)[%s%.%-_]+[eE]p?i?s?o?d?e?[%s%.%-_]*(%d+)") end
	if s2 and e2 then
		local p2 = norm:match("^(.-)[%s%[%(]+[sS]eason") or ""
		local skey = p2:gsub("[^%w]+", " "):match("^%s*(.-)%s*$"):lower()
		if #skey < 2 then skey = "series" end
		return skey, tonumber(s2), tonumber(e2)
	end

	-- Pattern 3: 4x09 or 04x09
	local s3, e3 = norm:match("[%s%[%(]+(%d+)[xX](%d+)")
	if not s3 then s3, e3 = norm:match("^(%d+)[xX](%d+)") end
	if s3 and e3 then
		local p3 = norm:match("^(.-)[%s%[%(]+" .. s3 .. "[xX]") or ""
		local skey = p3:gsub("[^%w]+", " "):match("^%s*(.-)%s*$"):lower()
		if #skey < 2 then skey = "series" end
		return skey, tonumber(s3), tonumber(e3)
	end

	-- Pattern 4: EP05 or Episode 05 or E05
	local e4 = norm:match("[%s%[%(]+[eE][pP]?[iI]?[sS]?[oO]?[dD]?[eE]?[%s%.%-_]*(%d+)")
	if not e4 then e4 = norm:match("^[eE][pP]?[iI]?[sS]?[oO]?[dD]?[eE]?[%s%.%-_]*(%d+)") end
	if e4 then
		local p4 = norm:match("^(.-)[%s%[%(]+[eE][pP]?") or ""
		local skey = p4:gsub("[^%w]+", " "):match("^%s*(.-)%s*$"):lower()
		if #skey < 2 then skey = "series" end
		return skey, 1, tonumber(e4)
	end

	return nil, nil, nil
end

local function get_clean_movie_key(text, fn)
	local s = text or fn or ""
	s = s:gsub("%?.*$", ""):gsub("%.%w%w%w?%w?$", "")
	s = s:match("([^/\\\\]+)$") or s
	local norm = s:gsub("[%._]+", " ")
	local year = norm:match("[%s%[%(](19%d%d)[%s%]%)]") or norm:match("[%s%[%(](20%d%d)[%s%]%)]")
	             or norm:match("[%s%[%(](19%d%d)$") or norm:match("[%s%[%(](20%d%d)$")
	local base = norm
	if year then
		local prefix = norm:match("^(.-)[%s%[%(]" .. year)
		if prefix and #prefix >= 2 then base = prefix end
	end
	local lower_base = " " .. base:lower() .. " "
	lower_base = lower_base:gsub("%b()", " "):gsub("%b[]", " ")
	local tags = {
		"1080p", "720p", "480p", "2160p", "4k", "bluray", "brrip", "bdrip",
		"webrip", "web dl", "webdl", "hdrip", "x264", "x265", "hevc", "softsub",
		"farsi", "sub", "dual audio", "dubbed", "remux"
	}
	for _, tag in ipairs(tags) do
		local p = lower_base:find(" " .. tag .. " ", 1, true)
		if p then lower_base = lower_base:sub(1, p) end
	end
	local clean = lower_base:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
	if #clean >= 2 then
		local words = {}
		for w in clean:gmatch("%S+") do
			if #words < 6 then table.insert(words, w) end
		end
		return table.concat(words, " ")
	end
	return norm:lower():match("^%s*(.-)%s*$")
end

local function format_clean_title(raw)
	if not raw or raw == "" then return "" end
	local name = raw:match("([^/\\\\]+)$") or raw
	name = name:gsub("%?.*$", "")
	name = name:gsub("%.%w%w%w?%w?$", "")

	local norm = name:gsub("[%._]+", " ")

	local s, e = norm:match("[%s%[%(]+[sS](%d+)[%s%.%-_]*[eE](%d+)")
	if not s then s, e = norm:match("^[sS](%d+)[%s%.%-_]*[eE](%d+)") end
	if s and e then
		local prefix = norm:match("^(.-)[%s%[%(]+[sS]" .. s) or ""
		local clean_show = prefix:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
		if not clean_show or #clean_show < 2 then clean_show = "Episode" end
		local cap = clean_show:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
		return string.format("%s — S%02dE%02d", cap, tonumber(s), tonumber(e))
	end

	local s2, e2 = norm:match("[%s%[%(]+[sS]eason[%s%.%-_]*(%d+)[%s%.%-_]+[eE]p?i?s?o?d?e?[%s%.%-_]*(%d+)")
	if not s2 then s2, e2 = norm:match("^[sS]eason[%s%.%-_]*(%d+)[%s%.%-_]+[eE]p?i?s?o?d?e?[%s%.%-_]*(%d+)") end
	if s2 and e2 then
		local p2 = norm:match("^(.-)[%s%[%(]+[sS]eason") or ""
		local clean_show = p2:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
		if not clean_show or #clean_show < 2 then clean_show = "Episode" end
		local cap = clean_show:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
		return string.format("%s — S%02dE%02d", cap, tonumber(s2), tonumber(e2))
	end

	local s3, e3 = norm:match("[%s%[%(]+(%d+)[xX](%d+)")
	if not s3 then s3, e3 = norm:match("^(%d+)[xX](%d+)") end
	if s3 and e3 then
		local p3 = norm:match("^(.-)[%s%[%(]+" .. s3 .. "[xX]") or ""
		local clean_show = p3:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
		if not clean_show or #clean_show < 2 then clean_show = "Episode" end
		local cap = clean_show:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
		return string.format("%s — S%02dE%02d", cap, tonumber(s3), tonumber(e3))
	end

	local e4 = norm:match("[%s%[%(]+[eE][pP]?[iI]?[sS]?[oO]?[dD]?[eE]?[%s%.%-_]*(%d+)")
	if not e4 then e4 = norm:match("^[eE][pP]?[iI]?[sS]?[oO]?[dD]?[eE]?[%s%.%-_]*(%d+)") end
	if e4 then
		local p4 = norm:match("^(.-)[%s%[%(]+[eE][pP]?") or ""
		local clean_show = p4:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
		if not clean_show or #clean_show < 2 then clean_show = "Episode" end
		local cap = clean_show:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
		return string.format("%s — Episode %d", cap, tonumber(e4))
	end

	local y = norm:match("[%s%[%(](19%d%d)[%s%]%)]") or norm:match("[%s%[%(](20%d%d)[%s%]%)]")
	          or norm:match("[%s%[%(](19%d%d)$") or norm:match("[%s%[%(](20%d%d)$")
	if y then
		local prefix = norm:match("^(.-)[%s%[%(]" .. y)
		if prefix then
			local clean_title = prefix:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
			if #clean_title >= 2 then
				local cap = clean_title:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
				return string.format("%s (%s)", cap, y)
			end
		end
	end

	local clean_plain = norm:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
	if #clean_plain > 0 then
		local cap = clean_plain:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
		local words = {}
		for w in cap:gmatch("%S+") do
			if #words < 5 then table.insert(words, w) end
		end
		return table.concat(words, " ")
	end

	return name
end

-- ============================================================================
-- History Persistence & Deduplication Engine
-- ============================================================================
local function prune_history_duplicates()
	if not stream_history or type(stream_history) ~= "table" then return end

	local groups = {}
	local group_order = {}

	for k, v in pairs(stream_history) do
		local url = (type(v) == "table" and v.url) or k
		-- STRICT RULE 1: Only web URLs are allowed in Stream Online history. Purge all local files!
		if not is_web_url(url) or not is_web_url(k) then
			stream_history[k] = nil
		else
			local _, fn = get_canonical_key(url)
			local raw_title = v.title or fn or k
			if not raw_title or raw_title == "" or is_promo_title(raw_title) then
				raw_title = (fn and fn ~= "") and fn or k
			end

			local skey, season, ep = parse_series_info(raw_title)
			if not skey and fn and fn ~= "" then
				skey, season, ep = parse_series_info(fn)
			end

			local entity_type, entity_id
			if skey then
				entity_type = "series"
				entity_id = "series:" .. skey
			else
				entity_type = "movie"
				local mkey = get_clean_movie_key(raw_title, fn)
				entity_id = "movie:" .. mkey
			end

			if not groups[entity_id] then
				groups[entity_id] = {
					entity_type = entity_type,
					items = {}
				}
				table.insert(group_order, entity_id)
			end

			table.insert(groups[entity_id].items, {
				key = k,
				season = season or 1,
				episode = ep or 1,
				position = tonumber(v.position) or 0,
				duration = tonumber(v.duration) or 0,
				completed = v.completed or false,
				updated_at = tonumber(v.updated_at) or 0,
			})
		end
	end

	-- For each entity group, keep ONLY the representative entry and purge all others:
	for _, gid in ipairs(group_order) do
		local grp = groups[gid]
		local list = grp.items
		if #list > 1 then
			if grp.entity_type == "series" then
				-- STRICT RULE 2: For a TV series, ONLY the last episode remains in history!
				table.sort(list, function(a, b)
					local a_num = (a.season or 1) * 10000 + (a.episode or 1)
					local b_num = (b.season or 1) * 10000 + (b.episode or 1)
					if a_num ~= b_num then
						return a_num > b_num
					end
					return (a.updated_at or 0) > (b.updated_at or 0)
				end)
			else
				-- STRICT RULE 3: For a movie, ONLY the latest watched entry remains in history!
				table.sort(list, function(a, b)
					if (a.updated_at or 0) ~= (b.updated_at or 0) then
						return (a.updated_at or 0) > (b.updated_at or 0)
					end
					return (a.position or 0) > (b.position or 0)
				end)
			end

			-- list[1] is the sole survivor; prune older duplicates from history:
			for i = 2, #list do
				stream_history[list[i].key] = nil
			end
		end
	end
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

local function load_history()
	local f = io.open(history_file, "r")
	if f then
		local content = f:read("*a")
		f:close()
		if content and content ~= "" then
			local ok, data = pcall(utils.parse_json, content)
			if ok and type(data) == "table" then
				local clean = {}
				for k, v in pairs(data) do
					if type(v) == "table" and is_web_url(v.url or k) and is_web_url(k) then
						local pos = tonumber(v.position) or 0
						local dur = tonumber(v.duration) or 0
						if dur > 0 and pos >= (dur * 0.90) then
							v.position = 0
							v.completed = true
						end
						clean[k] = v
					end
				end
				stream_history = clean
				prune_history_duplicates()
				save_history()
				msg.debug("Loaded stream watch history (" .. #stream_history .. " entries)")
				return
			end
		end
	end
	stream_history = {}
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
				if next_num < 1 then return nil, nil end
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

-- Asynchronous probing of previous episode (if available, inserts before current episode in playlist)
local function probe_and_queue_prev(base_url, origin)
	if not autoload_episodes then return end

	local candidate_url, prev_ep_label = get_next_episode_url(base_url, -1)
	if not candidate_url then return end

	-- Check if candidate is already in playlist
	local count = mp.get_property_number("playlist-count", 0)
	for i = 0, count - 1 do
		local pl_path = mp.get_property("playlist/" .. i .. "/filename")
		if pl_path and pl_path == candidate_url then
			return
		end
	end

	local user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	local is_win = (mp.get_property_native("platform") == "windows" or package.config:sub(1,1) == "\\")
	local curl_bin = is_win and "curl.exe" or "curl"
	local args = {
		curl_bin,
		"-I", "-L", "-s", "-k",
		"--connect-timeout", "5",
		"--max-time", "8",
		"-A", user_agent,
		candidate_url,
	}

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
				-- Check again before inserting
				local cur_count = mp.get_property_number("playlist-count", 0)
				for i = 0, cur_count - 1 do
					local pl_path = mp.get_property("playlist/" .. i .. "/filename")
					if pl_path and pl_path == candidate_url then
						return
					end
				end

				local cur_pos = mp.get_property_number("playlist-pos", 0)
				msg.info("Autoloaded previous online episode: " .. candidate_url)
				mp.commandv("loadfile", candidate_url, "append")
				-- Move from the end of playlist to right before the currently playing episode
				mp.commandv("playlist-move", cur_count, cur_pos)
				mp.osd_message("Added previous episode: E" .. tostring(prev_ep_label), 3)
			end
		end
	end)
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
	local is_win = (mp.get_property_native("platform") == "windows" or package.config:sub(1,1) == "\\")
	local curl_bin = is_win and "curl.exe" or "curl"
	local args = {
		curl_bin,
		"-I", "-L", "-s", "-k",
		"--connect-timeout", "5",
		"--max-time", "8",
		"-A", user_agent,
		candidate_url,
	}

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
-- Stream Position Tracker & Watch-Later Persistence
-- ============================================================================
local function record_current_position()
	local path = mp.get_property("path") or ""
	-- ONLY record for online web streams, NEVER for local files
	if not is_web_url(path) then
		return
	end

	local pos = mp.get_property_number("time-pos")
	local dur = mp.get_property_number("duration")
	if not pos or pos < 5 then return end

	local canonical_key, filename = get_canonical_key(path)
	if not canonical_key or canonical_key == "" then return end

	local title = mp.get_property("media-title") or mp.get_property("filename") or filename or canonical_key
	if not title or title == "" or is_promo_title(title) then
		title = (filename and filename ~= "") and filename or canonical_key
	end

	local save_pos = pos
	local is_completed = false
	if dur and dur > 0 and pos >= (dur * 0.90) then
		save_pos = 0
		is_completed = true
	end

	stream_history[canonical_key] = {
		position = save_pos,
		duration = dur or 0,
		title = title,
		url = path,
		completed = is_completed,
		updated_at = os.time(),
	}
	prune_history_duplicates()
	save_history()
end

local save_timer = mp.add_periodic_timer(5, record_current_position)

-- ============================================================================
-- Live Stream Connection & Buffering Monitor
-- ============================================================================
local function stop_loading_monitor()
	if buffer_feedback_timer then
		buffer_feedback_timer:kill()
		buffer_feedback_timer = nil
	end
	is_loading_stream = false
	loading_stream_url = nil
	loading_display_title = nil
end

local function start_loading_monitor(display_title, url)
	if buffer_feedback_timer then
		buffer_feedback_timer:kill()
		buffer_feedback_timer = nil
	end

	is_loading_stream = true
	loading_stream_url = url
	loading_display_title = display_title
	loading_start_time = mp.get_time()

	-- Instant initial OSD indicator
	mp.osd_message("⚡ Connecting to stream...\n" .. display_title, 2.0)

	buffer_feedback_timer = mp.add_periodic_timer(0.35, function()
		if not is_loading_stream then
			stop_loading_monitor()
			return
		end

		local buf_pct = mp.get_property_number("buffering-progress", 0)
		local elapsed = mp.get_time() - loading_start_time

		if buf_pct > 0 and buf_pct < 100 then
			mp.osd_message(string.format("⚡ Buffering stream: %d%%\n%s", buf_pct, loading_display_title or ""), 0.9)
		else
			local dots = string.rep(".", (math.floor(elapsed * 2.5) % 4) + 1)
			mp.osd_message(string.format("⚡ Connecting to stream%s (%.1fs)\n%s", dots, elapsed, loading_display_title or ""), 0.9)
		end
	end)
end

-- ============================================================================
-- Stream Playback Engine (Zero-Bloat Direct URL Loading)
-- ============================================================================
local function play_stream_url(url, target_pos)
	if not url or url == "" then return end
	url = url:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^["\']', ''):gsub('["\']$', '')

	if not is_web_url(url) then
		mp.osd_message("Invalid URL protocol. Must start with http:// or https://", 3)
		return
	end

	-- Dismiss any active uosc menu/palette immediately
	mp.commandv("script-message-to", "uosc", "close-menu")

	-- Set modern clean browser User-Agent
	local user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	mp.set_property("user-agent", user_agent)
	-- Clear custom headers to avoid strict CORS/403 blocks from CDNs
	mp.set_property("http-header-fields", "")
	-- CRITICAL: Always reset start property so it NEVER inherits a stale offset
	mp.set_property("start", "none")

	-- If previously playing an online stream, record its position before switching
	record_current_position()

	local canonical_key, filename = get_canonical_key(url)

	-- Check for saved watch-later position
	local entry = stream_history[canonical_key]
	local resume_pos = target_pos
	if not resume_pos and entry and entry.position and entry.position > 15 and not entry.completed then
		resume_pos = entry.position
	end

	-- Store pending resume position to be safely validated against actual duration in file-loaded
	pending_resume_pos = resume_pos

	local raw_name = (filename ~= "" and filename or url:sub(1, 50))
	local display_title = (entry and entry.title and entry.title ~= "") and entry.title or format_clean_title(raw_name)
	if not display_title or display_title == "" then display_title = raw_name end

	msg.info("Playing stream: " .. url .. " (Canonical: " .. canonical_key .. ", Resume: " .. tostring(pending_resume_pos or 0) .. "s)")

	-- Start live connection and buffering monitor
	start_loading_monitor(display_title, url)

	-- Load new stream cleanly and atomically into player (replaces current file without stop race)
	mp.commandv("loadfile", url, "replace")
end

-- ============================================================================
-- Watch-Later Resumption, Progress Monitor & Events
-- ============================================================================
mp.register_event("playback-restart", function()
	local path = mp.get_property("path") or ""
	if is_loading_stream or is_web_url(path) then
		local title = loading_display_title or mp.get_property("media-title") or mp.get_property("filename") or "Online Stream"
		stop_loading_monitor()
		mp.osd_message("▶ Playing: " .. title, 2.5)
	end
end)

mp.register_event("file-loaded", function()
	local path = mp.get_property("path") or ""
	if not is_web_url(path) then
		pending_resume_pos = nil
		stop_loading_monitor()
		return
	end

	local origin = get_origin(path)
	local canonical_key = get_canonical_key(path)

	-- Check for saved watch-later position
	local resume_pos = pending_resume_pos
	pending_resume_pos = nil

	if not resume_pos or resume_pos <= 15 then
		local entry = stream_history[canonical_key]
		if entry and entry.position and entry.position > 15 and not entry.completed then
			resume_pos = entry.position
		end
	end

	if resume_pos and resume_pos > 15 then
		local dur = mp.get_property_number("duration", 0)
		-- Safety check: only seek if duration is unknown (live stream) or resume_pos is safely within duration
		if dur <= 0 or resume_pos < (dur * 0.90) then
			mp.commandv("seek", resume_pos, "absolute", "exact")
			local mins = math.floor(resume_pos / 60)
			local secs = math.floor(resume_pos % 60)
			mp.osd_message(string.format("▶ Resumed at %02d:%02d (Saved Position)", mins, secs), 3.5)
		end
	end

	-- Trigger background probing for previous & next episodes ONLY AFTER current stream is successfully loaded!
	mp.add_timeout(2.0, function()
		probe_and_queue_prev(path, origin)
		probe_and_queue_next(path, origin, 1, 3)
	end)
end)

mp.register_event("end-file", function(event)
	record_current_position()

	if event.reason == "error" then
		stop_loading_monitor()
		local err = event.file_error or event.error or "Connection error or stream unavailable"
		msg.error("Stream loading failed: " .. tostring(err))
		mp.osd_message("❌ Stream connection failed: " .. tostring(err), 4.5)
		pending_resume_pos = nil
	elseif event.reason == "eof" or event.reason == "stop" then
		stop_loading_monitor()
		pending_resume_pos = nil
	end
end)

mp.register_event("pause", record_current_position)
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

	-- Fallback for Linux environments where mpv clipboard property might not have synced yet
	local is_win = (mp.get_property_native("platform") == "windows" or package.config:sub(1,1) == "\\")
	if not is_win then
		local res = mp.command_native({
			name = "subprocess",
			playback_only = false,
			capture_stdout = true,
			capture_stderr = false,
			args = {"xclip", "-selection", "clipboard", "-o"},
		})
		if res and res.status == 0 and res.stdout and res.stdout ~= "" then
			return res.stdout:gsub("^%s+", ""):gsub("%s+$", "")
		end

		local res2 = mp.command_native({
			name = "subprocess",
			playback_only = false,
			capture_stdout = true,
			capture_stderr = false,
			args = {"wl-paste", "--no-newline"},
		})
		if res2 and res2.status == 0 and res2.stdout and res2.stdout ~= "" then
			return res2.stdout:gsub("^%s+", ""):gsub("%s+$", "")
		end
	end

	return nil
end

-- ============================================================================
-- Interactive uosc Menu
-- ============================================================================
local function get_recent_history_items(max_count)
	prune_history_duplicates()

	local candidate_list = {}
	for k, v in pairs(stream_history) do
		local url = (type(v) == "table" and v.url) or k
		if is_web_url(url) and is_web_url(k) then
			local _, fn = get_canonical_key(url)
			local raw_title = v.title or fn or k
			if not raw_title or raw_title == "" or is_promo_title(raw_title) then
				raw_title = (fn and fn ~= "") and fn or raw_title
			end

			local pos = tonumber(v.position) or 0
			local dur = tonumber(v.duration) or 0
			local completed = v.completed or false
			if dur > 0 and pos >= (dur * 0.90) then
				pos = 0
				completed = true
			end

			table.insert(candidate_list, {
				key = k,
				url = url,
				title = raw_title,
				position = pos,
				duration = dur,
				completed = completed,
				updated_at = tonumber(v.updated_at) or 0,
			})
		end
	end

	table.sort(candidate_list, function(a, b)
		return (a.updated_at or 0) > (b.updated_at or 0)
	end)

	local items = {}
	local count = math.min(max_count or 10, #candidate_list)
	for i = 1, count do
		local cand = candidate_list[i]
		local pos = cand.position
		local dur = cand.duration
		local pct = dur > 0 and math.floor((pos / dur) * 100) or 0
		local mins = math.floor(pos / 60)
		local secs = math.floor(pos % 60)
		local dur_mins = math.floor(dur / 60)
		local dur_secs = math.floor(dur % 60)

		local time_str = ""
		if cand.completed then
			time_str = "Completed (Replay from 00:00)"
		elseif dur > 0 then
			time_str = string.format("%02d:%02d / %02d:%02d (%d%%)", mins, secs, dur_mins, dur_secs, pct)
		elseif pos > 0 then
			time_str = string.format("%02d:%02d", mins, secs)
		else
			time_str = "Watched"
		end

		local raw_title = cand.title or cand.key
		if raw_title:match("^https?://") then
			local _, fn = get_canonical_key(raw_title)
			raw_title = (fn and fn ~= "") and fn or raw_title:sub(1, 40)
		end
		local display_title = format_clean_title(raw_title)
		if not display_title or display_title == "" then
			display_title = raw_title
		end

		table.insert(items, {
			title = display_title,
			hint = time_str,
			icon = "history",
			value = "script-message open-url-load-history " .. cand.key,
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
		on_search = {"script-message", "open-url-load"},
		on_paste = {"script-message", "open-url-load"},
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
		local preview = format_clean_title(clean_name ~= "" and clean_name or clip)
		table.insert(menu_items, {
			title = "▶ Play from Clipboard",
			hint = preview,
			icon = "play_circle",
			value = "script-message open-url-play-clip",
			bold = true,
		})
	end

	table.insert(menu_items, {
		title = "Enter Stream URL...",
		value = "script-message open-url-prompt",
		hint = "Paste or type web link",
		icon = "edit",
		separator = true,
	})

	-- Recently Watched Streams (Direct 1-Click Access with Clean Formatted Titles)
	local recent_items = get_recent_history_items(12)
	if #recent_items > 0 then
		local show_count = math.min(5, #recent_items)
		for i = 1, show_count do
			table.insert(menu_items, recent_items[i])
		end

		if #recent_items > 5 then
			table.insert(menu_items, {
				title = "View All Recent Streams...",
				hint = tostring(#recent_items) .. " total",
				icon = "history",
				items = recent_items,
			})
		end

		table.insert(menu_items, {
			title = "Clear Watch History",
			value = "script-message open-url-clear-history",
			icon = "delete",
			separator = true,
		})
	end

	-- Settings & Storage Section
	local cache_mb = get_cache_size_mb()
	table.insert(menu_items, {
		title = "Autoload Next Episodes",
		hint = autoload_episodes and "Enabled" or "Disabled",
		icon = "playlist_add",
		value = "script-message open-url-toggle-autoload",
		active = autoload_episodes,
	})

	table.insert(menu_items, {
		title = "Clear Stream Disk Cache",
		hint = tostring(cache_mb) .. " MB",
		icon = "storage",
		value = "script-message open-url-purge-cache",
	})

	local menu_data = {
		type = "open-url-master",
		title = "Stream Online",
		footnote = "Press Ctrl+V to paste & play directly • Escape to close",
		items = menu_items,
		on_paste = {"script-message", "open-url-load"},
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

mp.register_script_message("open-url-load", function(...)
	mp.commandv("script-message-to", "uosc", "close-menu")
	local args = {...}
	if #args == 0 then return end

	local url = args[1]
	-- When called from uosc command_or_event, params is {query, menu.id}
	-- If string splitting occurred, reconstruct URL while dropping the trailing menu.id
	if #args > 2 and args[#args] == "open-url-input" then
		table.remove(args, #args)
		url = table.concat(args, " ")
	elseif #args == 2 and args[2] == "open-url-input" then
		url = args[1]
	elseif #args > 1 and not is_web_url(args[1]) then
		url = table.concat(args, " ")
	end

	if url and url ~= "" then
		play_stream_url(url)
	end
end)

mp.register_script_message("open-url-play-clip", function()
	mp.commandv("script-message-to", "uosc", "close-menu")
	local clip = get_clipboard_text()
	if clip and is_web_url(clip) then
		play_stream_url(clip)
	else
		mp.osd_message("Clipboard does not contain a valid web URL", 2.5)
	end
end)

mp.register_script_message("open-url-load-history", function(...)
	mp.commandv("script-message-to", "uosc", "close-menu")
	local args = {...}
	if #args == 0 then return end
	local key = table.concat(args, " ")
	local entry = stream_history[key]
	if not entry and #args > 0 then
		entry = stream_history[args[1]]
	end
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
