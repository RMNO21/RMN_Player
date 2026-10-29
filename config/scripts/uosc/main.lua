--[[ uosc | https://github.com/tomasklaen/uosc ]]
local uosc_version = '5.12.0'

mp.commandv('script-message', 'uosc-version', uosc_version)

mp.set_property('osc', 'no')

assdraw = require('mp.assdraw')
opt = require('mp.options')
utils = require('mp.utils')
msg = require('mp.msg')
osd = mp.create_osd_overlay('ass-events')
QUARTER_PI_SIN = math.sin(math.pi / 4)

require('lib/std')

--[[ OPTIONS ]]

defaults = {
	timeline_style = 'line',
	timeline_line_width = 2,
	timeline_size = 40,
	progress = 'windowed',
	progress_size = 2,
	progress_line_width = 20,
	timeline_persistency = '',
	timeline_border = 1,
	timeline_step = '5',
	timeline_cache = true,
	timeline_heatmap = 'overlay',

	controls =
	'menu,gap,<video,audio>subtitles,<has_many_audio>audio,<has_many_video>video,<has_many_edition>editions,<stream>stream-quality,gap,space,<video,audio>speed,space,shuffle,loop-playlist,loop-file,gap,prev,items,next,gap,fullscreen',
	controls_size = 32,
	controls_margin = 8,
	controls_spacing = 2,
	controls_persistency = '',

	volume = 'right',
	volume_size = 40,
	volume_persistency = '',
	volume_border = 1,
	volume_step = 1,

	speed_persistency = '',
	speed_step = 0.1,
	speed_step_is_factor = false,

	menu_item_height = 36,
	menu_min_width = 260,
	menu_padding = 4,
	menu_type_to_search = true,

	top_bar = 'no-border',
	top_bar_size = 40,
	top_bar_persistency = '',
	top_bar_controls = 'right',
	top_bar_title = 'yes',
	top_bar_alt_title = '',
	top_bar_alt_title_place = 'below',
	top_bar_flash_on = 'video,audio',

	window_border_size = 1,

	autoload = false,
	shuffle = false,

	scale = 1,
	scale_fullscreen = 1.3,
	font_scale = 1,
	text_border = 1.2,
	border_radius = 4,
	color = '',
	opacity = '',
	animation_duration = 100,
	refine = '',
	flash_duration = 1000,
	proximity_in = 40,
	proximity_out = 120,
	total_time = false, -- deprecated by below
	destination_time = 'playtime-remaining',
	time_precision = 0,
	font_bold = false,
	autohide = false,
	buffered_time_threshold = 60,
	pause_indicator = 'flash',
	stream_quality_options = '4320,2160,1440,1080,720,480,360,240,144',
	video_types =
	'3g2,3gp,asf,avi,f4v,flv,h264,h265,m2ts,m4v,mkv,mov,mp4,mp4v,mpeg,mpg,ogm,ogv,rm,rmvb,ts,vob,webm,wmv,y4m',
	audio_types =
	'aac,ac3,aiff,ape,au,cue,dsf,dts,flac,m4a,mid,midi,mka,mp3,mp4a,oga,ogg,opus,spx,tak,tta,wav,weba,wma,wv',
	image_types = 'apng,avif,bmp,gif,j2k,jp2,jfif,jpeg,jpg,jxl,mj2,png,svg,tga,tif,tiff,webp',
	subtitle_types = 'aqt,ass,gsub,idx,jss,lrc,mks,pgs,pjs,psb,rt,sbv,slt,smi,sub,sup,srt,ssa,ssf,ttxt,txt,usf,vt,vtt',
	playlist_types = 'm3u,m3u8,pls,url,cue',
	load_types = 'video,audio,image',
	default_directory = '~/',
	show_hidden_files = false,
	use_trash = false,
	adjust_osd_margins = true,
	chapter_ranges = 'openings:30abf964,endings:30abf964,ads:c54e4e80',
	chapter_range_patterns = 'openings:オープニング;endings:エンディング',
	languages = 'slang,en',
	subtitles_directory = '~~/subtitles',
	disable_elements = '',
}
options = table_copy(defaults)
function handle_options(changed_options)
	if changed_options.time_precision then
		timestamp_zero_rep_clear_cache()
	end
	update_config()
	update_human_times()
	Manager:disable('user', options.disable_elements)
	Elements:trigger('options')
	Elements:update_proximities()
	request_render()
end
opt.read_options(options, 'uosc', handle_options)
-- Normalize values
options.proximity_out = math.max(options.proximity_out, options.proximity_in + 1)
if options.chapter_ranges:sub(1, 4) == '^op|' then options.chapter_ranges = defaults.chapter_ranges end
if options.total_time and options.destination_time == 'playtime-remaining' then
	msg.warn('`total_time` is deprecated. Use `destination_time` instead.')
	options.destination_time = 'total'
elseif not itable_index_of({'total', 'playtime-remaining', 'time-remaining'}, options.destination_time) then
	options.destination_time = 'playtime-remaining'
end
if not itable_index_of({'left', 'right'}, options.top_bar_controls) then
	options.top_bar_controls = options.top_bar_controls == 'yes' and 'right' or nil
end

--[[ INTERNATIONALIZATION ]]
local intl = require('lib/intl')
t = intl.t
require('lib/char_conv')
fzy = require('lib/fzy')

--[[ CONFIG ]]
local config_defaults = {
	color = {
		foreground = serialize_rgba('ffffff').color,
		foreground_text = serialize_rgba('000000').color,
		background = serialize_rgba('000000').color,
		background_text = serialize_rgba('ffffff').color,
		curtain = serialize_rgba('111111').color,
		success = serialize_rgba('a5e075').color,
		error = serialize_rgba('ff616e').color,
		match = serialize_rgba('69c5ff').color,
		heatmap = serialize_rgba('00adee').color,
	},
	opacity = {
		timeline = 0.9,
		position = 1,
		chapters = 0.8,
		slider = 0.9,
		slider_gauge = 1,
		controls = 0,
		speed = 0.6,
		menu = 1,
		submenu = 0.4,
		border = 1,
		title = 1,
		tooltip = 1,
		thumbnail = 1,
		curtain = 0.8,
		idle_indicator = 0.8,
		audio_indicator = 0.5,
		buffering_indicator = 0.3,
		playlist_position = 0.8,
		heatmap = 0.4,
	},
}
config = {
	version = uosc_version,
	open_subtitles_api_key = 'b0rd16N0bp7DETMpO4pYZwIqmQkZbYQr',
	open_subtitles_agent = 'uosc v' .. uosc_version,
	-- sets max rendering frequency in case the
	-- native rendering frequency could not be detected
	render_delay = 1 / 60,
	font = mp.get_property('options/osd-font'),
	osd_margin_x = mp.get_property('osd-margin-x'),
	osd_margin_y = mp.get_property('osd-margin-y'),
	osd_alignment_x = mp.get_property('osd-align-x'),
	osd_alignment_y = mp.get_property('osd-align-y'),
	refine = create_set(comma_split(options.refine)),
	types = {
		video = comma_split(options.video_types),
		audio = comma_split(options.audio_types),
		image = comma_split(options.image_types),
		subtitle = comma_split(options.subtitle_types),
		playlist = comma_split(options.playlist_types),
		media = comma_split(options.video_types
			.. ',' .. options.audio_types
			.. ',' .. options.image_types
			.. ',' .. options.playlist_types),
		load = {}, -- populated by update_load_types() below
	},
	stream_quality_options = comma_split(options.stream_quality_options),
	top_bar_flash_on = comma_split(options.top_bar_flash_on),
	chapter_ranges = (function()
		---@type table<string, string[]> Alternative patterns.
		local alt_patterns = {}
		if options.chapter_range_patterns and options.chapter_range_patterns ~= '' then
			for _, definition in ipairs(split(options.chapter_range_patterns, ';+ *')) do
				local name_patterns = split(definition, ' *:')
				local name, patterns = name_patterns[1], name_patterns[2]
				if name and patterns then alt_patterns[name] = split(patterns, ',') end
			end
		end

		---@type table<string, {color: string; opacity: number; patterns?: string[]}>
		local ranges = {}
		if options.chapter_ranges and options.chapter_ranges ~= '' then
			for _, definition in ipairs(split(options.chapter_ranges, ' *,+ *')) do
				local name_color = split(definition, ' *:+ *')
				local name, color = name_color[1], name_color[2]
				if name and color
					and name:match('^[a-zA-Z0-9_]+$') and color:match('^[a-fA-F0-9]+$')
					and (#color == 6 or #color == 8) then
					local range = serialize_rgba(name_color[2])
					range.patterns = alt_patterns[name]
					ranges[name_color[1]] = range
				end
			end
		end
		return ranges
	end)(),
	color = table_copy(config_defaults.color),
	opacity = table_copy(config_defaults.opacity),
	cursor_leave_fadeout_elements = {'timeline', 'volume', 'top_bar', 'controls'},
	timeline_step = 5,
	timeline_step_flag = '',
}

function update_load_types()
	local extensions = {}
	local types = create_set(comma_split(options.load_types:lower()))

	if types.same then
		types.same = nil
		if state and state.type then types[state.type] = true end
	end

	for _, name in ipairs(table_keys(types)) do
		local type_extensions = config.types[name]
		if type(type_extensions) == 'table' then
			itable_append(extensions, type_extensions)
		else
			msg.warn('Unknown load type: ' .. name)
		end
	end

	config.types.load = extensions
end

-- Updates config with values dependent on options
function update_config()
	-- Required environment config
	if options.autoload then
		mp.commandv('set', 'keep-open', 'yes')
		mp.commandv('set', 'keep-open-pause', 'no')
	end

	-- Adds `{element}_persistency` config properties with forced visibility states (e.g.: `{paused = true}`)
	for _, name in ipairs({'timeline', 'controls', 'volume', 'top_bar', 'speed'}) do
		local option_name = name .. '_persistency'
		local value, flags = options[option_name], {}
		if type(value) == 'string' then
			for _, state in ipairs(comma_split(value)) do flags[state] = true end
		end
		config[option_name] = flags
	end

	-- Opacity
	config.opacity = table_assign({}, config_defaults.opacity, serialize_key_value_list(options.opacity,
		function(value, key)
			return clamp(0, tonumber(value) or config.opacity[key], 1)
		end
	))

	-- Color
	config.color = table_assign({}, config_defaults.color, serialize_key_value_list(options.color, function(value)
		return serialize_rgba(value).color
	end))

	-- Global color shorthands
	fg, bg = config.color.foreground, config.color.background
	fgt, bgt = config.color.foreground_text, config.color.background_text

	-- Timeline step
	do
		local is_exact = options.timeline_step:sub(-1) == '!'
		config.timeline_step = tonumber(is_exact and options.timeline_step:sub(1, -2) or options.timeline_step)
		config.timeline_step_flag = is_exact and 'exact' or ''
	end

	-- Other
	update_load_types()
end
update_config()

-- ============================================================================
-- Recent Files Tracker & Menu Engine
-- ============================================================================
local function get_rmn_config_dir()
	local ok, dir = pcall(function() return mp.command_native({'expand-path', '~~home/'}) end)
	if ok and dir and dir ~= '' then return dir end
	local ok2, dir2 = pcall(function() return mp.command_native({'expand-path', '~~/'}) end)
	if ok2 and dir2 and dir2 ~= '' then return dir2 end
	local appdata = os.getenv('APPDATA')
	if appdata then return appdata .. '/RMN-Player' end
	return '.'
end

local recent_files_path = get_rmn_config_dir() .. '/recent-files.json'
local recent_files = {}

local function load_recent_files()
	local f = io.open(recent_files_path, 'r')
	if f then
		local c = f:read('*a')
		f:close()
		if c and c ~= '' then
			local ok, data = pcall(utils.parse_json, c)
			if ok and type(data) == 'table' then
				recent_files = data
				return
			end
		end
	end
	recent_files = {}
end

local function save_recent_files()
	if not recent_files then return end
	local ok, json_str = pcall(utils.format_json, recent_files)
	if ok and json_str then
		local f = io.open(recent_files_path, 'w')
		if f then
			f:write(json_str)
			f:close()
		end
	end
end

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
	local filename = text:match("([^/\\]+)$") or text
	filename = filename:gsub("%?.*$", "")
	filename = filename:gsub("%.%w%w%w?%w?$", "")

	local norm = filename:gsub("[%._]+", " ")

	-- Pattern 1: S01E02, S1E2, s01e02
	local s, e = norm:match("[%s%[]+[sS](%d+)[%s%.%-_]*[eE](%d+)")
	if s and e then
		local prefix = norm:match("^(.-)[%s%[]+[sS]" .. s)
		if prefix then
			local skey = prefix:gsub("[^%w]+", " "):match("^%s*(.-)%s*$"):lower()
			if #skey >= 2 then return skey, tonumber(s), tonumber(e) end
		end
	end

	-- Pattern 2: Season 2 ... Episode 4
	local s2, e2 = norm:match("[%s%[]+[sS]eason[%s%.%-_]*(%d+)[%s%.%-_]+[eE]p?i?s?o?d?e?[%s%.%-_]*(%d+)")
	if s2 and e2 then
		local p2 = norm:match("^(.-)[%s%[]+[sS]eason")
		if p2 then
			local skey = p2:gsub("[^%w]+", " "):match("^%s*(.-)%s*$"):lower()
			if #skey >= 2 then return skey, tonumber(s2), tonumber(e2) end
		end
	end

	-- Pattern 3: 4x09 or 04x09
	local s3, e3 = norm:match("[%s%[]+(%d+)[xX](%d+)")
	if s3 and e3 then
		local p3 = norm:match("^(.-)[%s%[]+" .. s3 .. "[xX]")
		if p3 then
			local skey = p3:gsub("[^%w]+", " "):match("^%s*(.-)%s*$"):lower()
			if #skey >= 2 then return skey, tonumber(s3), tonumber(e3) end
		end
	end

	-- Pattern 4: EP05 or Episode 05 or E05 (standalone episode without season)
	local e4 = norm:match("[%s%[]+[eE][pP]?[iI]?[sS]?[oO]?[dD]?[eE]?[%s%.%-_]*(%d+)")
	if e4 then
		local p4 = norm:match("^(.-)[%s%[]+[eE][pP]?")
		if p4 then
			local skey = p4:gsub("[^%w]+", " "):match("^%s*(.-)%s*$"):lower()
			if #skey >= 2 then return skey, 1, tonumber(e4) end
		end
	end

	return nil, nil, nil
end

local function get_clean_file_title(path)
	local fname = mp.get_property('filename') or path:match('([^/\\]+)$') or path
	local mtitle = mp.get_property('media-title')

	if mtitle and mtitle ~= '' and not is_promo_title(mtitle) then
		local fname_skey = parse_series_info(fname)
		local mtitle_skey = parse_series_info(mtitle)
		if fname_skey and not mtitle_skey then
			return fname
		end
		return mtitle
	end
	return fname
end

local function record_recent_file()
	local path = mp.get_property('path')
	if not path or path == '' then return end
	if path:match('^%a[%a%d_]+://') then return end

	local pos = mp.get_property_number('time-pos') or 0
	local dur = mp.get_property_number('duration') or 0
	local title = get_clean_file_title(path)

	local is_completed = false
	local save_pos = pos
	if dur > 0 and pos >= (dur * 0.92) then
		save_pos = 0
		is_completed = true
	end

	for i = #recent_files, 1, -1 do
		if recent_files[i].path == path then
			table.remove(recent_files, i)
		end
	end

	table.insert(recent_files, 1, {
		path = path,
		title = title,
		position = save_pos,
		duration = dur,
		completed = is_completed,
		updated_at = os.time(),
	})

	while #recent_files > 25 do
		table.remove(recent_files)
	end

	save_recent_files()
end

local function format_clean_title(raw)
	if not raw or raw == "" then return "" end
	local name = raw:match("([^/\\]+)$") or raw
	name = name:gsub("%?.*$", "")
	name = name:gsub("%.%w%w%w?%w?$", "")

	local norm = name:gsub("[%._]+", " ")

	local s, e = norm:match("[%s%[]+[sS](%d+)[%s%.%-_]*[eE](%d+)")
	if s and e then
		local prefix = norm:match("^(.-)[%s%[]+[sS]" .. s)
		if prefix then
			local clean_show = prefix:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
			if #clean_show >= 2 then
				local cap = clean_show:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
				return string.format("%s — S%02dE%02d", cap, tonumber(s), tonumber(e))
			end
		end
	end

	local s2, e2 = norm:match("[%s%[]+[sS]eason[%s%.%-_]*(%d+)[%s%.%-_]+[eE]p?i?s?o?d?e?[%s%.%-_]*(%d+)")
	if s2 and e2 then
		local p2 = norm:match("^(.-)[%s%[]+[sS]eason")
		if p2 then
			local clean_show = p2:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
			if #clean_show >= 2 then
				local cap = clean_show:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
				return string.format("%s — S%02dE%02d", cap, tonumber(s2), tonumber(e2))
			end
		end
	end

	local s3, e3 = norm:match("[%s%[]+(%d+)[xX](%d+)")
	if s3 and e3 then
		local p3 = norm:match("^(.-)[%s%[]+" .. s3 .. "[xX]")
		if p3 then
			local clean_show = p3:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
			if #clean_show >= 2 then
				local cap = clean_show:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
				return string.format("%s — S%02dE%02d", cap, tonumber(s3), tonumber(e3))
			end
		end
	end

	local e4 = norm:match("[%s%[]+[eE][pP]?[iI]?[sS]?[oO]?[dD]?[eE]?[%s%.%-_]*(%d+)")
	if e4 then
		local p4 = norm:match("^(.-)[%s%[]+[eE][pP]?")
		if p4 then
			local clean_show = p4:gsub("[^%w]+", " "):match("^%s*(.-)%s*$")
			if #clean_show >= 2 then
				local cap = clean_show:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
				return string.format("%s — Episode %d", cap, tonumber(e4))
			end
		end
	end

	local y = norm:match("[%s%[]+(19%d%d)[%s%]%)]") or norm:match("[%s%[]+(20%d%d)[%s%]%)]")
	if y then
		local prefix = norm:match("^(.-)[%s%[]+" .. y)
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

local function get_recent_files_items()
	load_recent_files()
	if #recent_files == 0 then
		return {
			{title = t('No recent files'), align = 'center', muted = true, italic = true, selectable = false},
		}
	end

	-- Group series by series_key or keep standalone
	local series_groups = {}
	local group_order = {}

	local healed_any = false
	for idx, entry in ipairs(recent_files) do
		local filename = entry.path:match('([^/\\]+)$') or entry.path
		local title = entry.title
		if not title or title == '' or is_promo_title(title) then
			title = filename
			entry.title = filename
			healed_any = true
		end

		local fname_skey, f_season, f_ep = parse_series_info(filename)
		local skey, season, ep = parse_series_info(title)
		if fname_skey and not skey then
			title = filename
			skey, season, ep = fname_skey, f_season, f_ep
			entry.title = filename
			healed_any = true
		end

		local item_data = {
			entry = entry,
			orig_idx = idx,
			title = title,
			season = season or 1,
			episode = ep or 1,
			position = entry.position or 0,
			duration = entry.duration or 0,
			completed = entry.completed or false,
			updated_at = entry.updated_at or 0,
		}

		if skey then
			if not series_groups[skey] then
				series_groups[skey] = {}
				table.insert(group_order, {type = 'series', key = skey})
			end
			table.insert(series_groups[skey], item_data)
		else
			table.insert(group_order, {type = 'standalone', data = item_data})
		end
	end

	-- For each series, select the best / last watched episode:
	-- Discard accidental previews (< 45s and not completed) if any meaningful episodes exist.
	-- Prefer actively in-progress episodes over completed earlier episodes.
	local candidate_list = {}
	for _, grp in ipairs(group_order) do
		if grp.type == 'standalone' then
			table.insert(candidate_list, grp.data)
		elseif grp.type == 'series' and series_groups[grp.key] then
			local ep_list = series_groups[grp.key]
			series_groups[grp.key] = nil

			local meaningful = {}
			for _, e in ipairs(ep_list) do
				local is_mean = e.completed or (e.position >= 45) or (e.duration > 0 and (e.position / e.duration) >= 0.03)
				if is_mean then
					table.insert(meaningful, e)
				end
			end

			local pool = #meaningful > 0 and meaningful or ep_list
			table.sort(pool, function(a, b)
				local a_in_progress = (not a.completed) and (a.position >= 45) and 1 or 0
				local b_in_progress = (not b.completed) and (b.position >= 45) and 1 or 0
				if a_in_progress ~= b_in_progress then
					return a_in_progress > b_in_progress
				end
				if (a.updated_at or 0) ~= (b.updated_at or 0) then
					return (a.updated_at or 0) > (b.updated_at or 0)
				end
				local a_num = a.season * 10000 + a.episode
				local b_num = b.season * 10000 + b.episode
				return a_num > b_num
			end)

			table.insert(candidate_list, pool[1])
		end
	end

	-- Sort candidate list by updated_at descending
	if healed_any then save_recent_files() end

	table.sort(candidate_list, function(a, b)
		return (a.updated_at or 0) > (b.updated_at or 0)
	end)

	local items = {}
	for i = 1, math.min(12, #candidate_list) do
		local cand = candidate_list[i]
		local entry = cand.entry
		local pos = cand.position
		local dur = cand.duration
		local pct = dur > 0 and math.floor((pos / dur) * 100) or 0
		local mins = math.floor(pos / 60)
		local secs = math.floor(pos % 60)
		local dur_mins = math.floor(dur / 60)
		local dur_secs = math.floor(dur % 60)

		local time_str = ""
		if cand.completed then
			time_str = "Completed"
		elseif dur > 0 and pos > 10 then
			time_str = string.format("%02d:%02d / %02d:%02d (%d%%)", mins, secs, dur_mins, dur_secs, pct)
		elseif pos > 10 then
			time_str = string.format("%02d:%02d", mins, secs)
		end

		table.insert(items, {
			title = format_clean_title(cand.title),
			hint = time_str ~= "" and time_str or nil,
			icon = 'play_arrow',
			value = 'script-message play-recent-file ' .. tostring(cand.orig_idx),
		})
	end

	table.insert(items, {
		title = t('Clear Recent Files'),
		value = 'script-message clear-recent-files',
		icon = 'delete',
		separator = true,
	})

	return items
end

load_recent_files()

-- Helper function for subtitle appearance menu
local function get_subtitle_style_items()
	local cur_font = mp.get_property('sub-font') or 'sans-serif'
	local cur_scale = mp.get_property_number('sub-scale', 1.0)
	local cur_scale_pct = math.floor(cur_scale * 100 + 0.5)
	local cur_border_style = mp.get_property('sub-border-style') or 'outline-and-shadow'
	local cur_back_color = (mp.get_property('sub-back-color') or ''):upper()
	local cur_border_size = mp.get_property_number('sub-border-size', 3)
	local cur_shadow = mp.get_property_number('sub-shadow-offset', 0)
	local cur_color = (mp.get_property('sub-color') or ''):upper()
	local cur_override = mp.get_property('sub-ass-override') or 'yes'
	local font_lower = cur_font:lower()

	local is_box_off = cur_border_style == 'outline-and-shadow' or cur_back_color == '' or cur_back_color:sub(1, 3) == '#00'
	local is_box_50 = cur_border_style == 'background-box' and cur_back_color:sub(1, 3) == '#80'
	local is_box_80 = cur_border_style == 'background-box' and cur_back_color:sub(1, 3) == '#CC'
	local is_box_100 = cur_border_style == 'background-box' and cur_back_color:sub(1, 3) == '#FF'
	local is_box_opaque = cur_border_style == 'opaque-box'

	local box_hint = 'Off'
	if is_box_50 then box_hint = '50%'
	elseif is_box_80 then box_hint = '80%'
	elseif is_box_100 then box_hint = '100%'
	elseif is_box_opaque then box_hint = 'Opaque'
	end

	return {
		{
			title = 'Background Box',
			hint = box_hint,
			items = {
				{title = 'Off (Transparent)', value = 'set sub-border-style outline-and-shadow; set sub-back-color "#00000000"; show-text "Subtitle Box: Off"', active = is_box_off},
				{title = 'Semi-Transparent (50%)', value = 'set sub-border-style background-box; set sub-back-color "#80000000"; show-text "Subtitle Box: Semi-Transparent (50%)"', active = is_box_50},
				{title = 'Dark (80%)', value = 'set sub-border-style background-box; set sub-back-color "#CC000000"; show-text "Subtitle Box: Dark (80%)"', active = is_box_80},
				{title = 'Solid Black (100%)', value = 'set sub-border-style background-box; set sub-back-color "#FF000000"; show-text "Subtitle Box: Solid Black (100%)"', active = is_box_100},
				{title = 'Compact Opaque', value = 'set sub-border-style opaque-box; set sub-back-color "#A0000000"; show-text "Subtitle Box: Compact Opaque"', active = is_box_opaque},
			},
		},
		{
			title = 'Font Family',
			hint = cur_font ~= '' and cur_font or 'sans-serif',
			items = {
				{title = 'Vazirmatn', value = 'set sub-font "Vazirmatn"; show-text "Subtitle Font: Vazirmatn"', active = font_lower == 'vazirmatn'},
				{title = 'IRANSans', value = 'set sub-font "IRANSans"; show-text "Subtitle Font: IRANSans"', active = font_lower == 'iransans'},
				{title = 'Shabnam', value = 'set sub-font "Shabnam"; show-text "Subtitle Font: Shabnam"', active = font_lower == 'shabnam'},
				{title = 'Sahel', value = 'set sub-font "Sahel"; show-text "Subtitle Font: Sahel"', active = font_lower == 'sahel'},
				{title = 'Segoe UI', value = 'set sub-font "Segoe UI"; show-text "Subtitle Font: Segoe UI"', active = font_lower == 'segoe ui'},
				{title = 'Tahoma', value = 'set sub-font "Tahoma"; show-text "Subtitle Font: Tahoma"', active = font_lower == 'tahoma'},
				{title = 'Arial', value = 'set sub-font "Arial"; show-text "Subtitle Font: Arial"', active = font_lower == 'arial'},
				{title = 'Trebuchet MS', value = 'set sub-font "Trebuchet MS"; show-text "Subtitle Font: Trebuchet MS"', active = font_lower == 'trebuchet ms'},
				{title = 'Consolas (Monospace)', value = 'set sub-font "Consolas"; show-text "Subtitle Font: Consolas"', active = font_lower == 'consolas', separator = true},
				{title = 'System Default', value = 'set sub-font "sans-serif"; show-text "Subtitle Font: Default"', active = font_lower == 'sans-serif' or cur_font == ''},
			},
		},
		{
			title = 'Shadow & Outline',
			items = {
				{
					title = 'Shadow Depth',
					hint = tostring(cur_shadow) .. 'px',
					items = {
						{title = 'Off (No Shadow)', value = 'set sub-shadow-offset 0; show-text "Subtitle Shadow: Off"', active = cur_shadow == 0},
						{title = 'Soft (2px)', value = 'set sub-shadow-offset 2; set sub-shadow-color "#000000"; show-text "Subtitle Shadow: Soft (2px)"', active = math.abs(cur_shadow - 2) < 0.2},
						{title = 'Medium (3.5px)', value = 'set sub-shadow-offset 3.5; set sub-shadow-color "#000000"; show-text "Subtitle Shadow: Medium (3.5px)"', active = math.abs(cur_shadow - 3.5) < 0.2},
						{title = 'Strong (5px)', value = 'set sub-shadow-offset 5; set sub-shadow-color "#000000"; show-text "Subtitle Shadow: Strong (5px)"', active = math.abs(cur_shadow - 5) < 0.2},
					},
				},
				{
					title = 'Outline Thickness',
					hint = tostring(cur_border_size) .. 'px',
					items = {
						{title = 'None (0px)', value = 'set sub-border-size 0; show-text "Subtitle Outline: None"', active = cur_border_size == 0},
						{title = 'Thin (1.5px)', value = 'set sub-border-size 1.5; set sub-border-color "#000000"; show-text "Subtitle Outline: Thin (1.5px)"', active = math.abs(cur_border_size - 1.5) < 0.2},
						{title = 'Medium (3px - Default)', value = 'set sub-border-size 3; set sub-border-color "#000000"; show-text "Subtitle Outline: Medium (3px)"', active = math.abs(cur_border_size - 3) < 0.2},
						{title = 'Thick (4.5px)', value = 'set sub-border-size 4.5; set sub-border-color "#000000"; show-text "Subtitle Outline: Thick (4.5px)"', active = math.abs(cur_border_size - 4.5) < 0.2},
						{title = 'Extra Thick (6px)', value = 'set sub-border-size 6; set sub-border-color "#000000"; show-text "Subtitle Outline: Extra Thick (6px)"', active = math.abs(cur_border_size - 6) < 0.2},
					},
				},
			},
		},
		{
			title = 'Text Size',
			hint = tostring(cur_scale_pct) .. '%',
			items = {
				{title = 'Small (75%)', value = 'set sub-scale 0.75; show-text "Subtitle Size: 75%"', active = math.abs(cur_scale - 0.75) < 0.05},
				{title = 'Normal (100% - Default)', value = 'set sub-scale 1.0; show-text "Subtitle Size: 100%"', active = math.abs(cur_scale - 1.0) < 0.05},
				{title = 'Large (125%)', value = 'set sub-scale 1.25; show-text "Subtitle Size: 125%"', active = math.abs(cur_scale - 1.25) < 0.05},
				{title = 'Extra Large (150%)', value = 'set sub-scale 1.5; show-text "Subtitle Size: 150%"', active = math.abs(cur_scale - 1.5) < 0.05},
				{title = 'Huge (175%)', value = 'set sub-scale 1.75; show-text "Subtitle Size: 175%"', active = math.abs(cur_scale - 1.75) < 0.05, separator = true},
				{title = 'Increase Size (+10%)', value = 'add sub-scale 0.1; show-text "Subtitle Size: +10%"'},
				{title = 'Decrease Size (-10%)', value = 'add sub-scale -0.1; show-text "Subtitle Size: -10%"'},
				{title = 'Reset Size (100%)', value = 'set sub-scale 1.0; show-text "Subtitle Size: Reset (100%)"'},
			},
		},
		{
			title = 'Text Color',
			separator = true,
			items = {
				{title = 'White (Default)', value = 'set sub-color "#FFFFFF"; show-text "Subtitle Color: White"', active = cur_color:find('FFFFFF') ~= nil or cur_color == ''},
				{title = 'Warm White / Cream', value = 'set sub-color "#FFF8E7"; show-text "Subtitle Color: Warm White"', active = cur_color:find('FFF8E7') ~= nil},
				{title = 'Yellow (Cinema)', value = 'set sub-color "#FFFF00"; show-text "Subtitle Color: Yellow"', active = cur_color:find('FFFF00') ~= nil},
				{title = 'Gold', value = 'set sub-color "#FFD700"; show-text "Subtitle Color: Gold"', active = cur_color:find('FFD700') ~= nil},
				{title = 'Cyan', value = 'set sub-color "#00FFFF"; show-text "Subtitle Color: Cyan"', active = cur_color:find('00FFFF') ~= nil},
				{title = 'Light Green', value = 'set sub-color "#90EE90"; show-text "Subtitle Color: Light Green"', active = cur_color:find('90EE90') ~= nil},
				{title = 'Light Gray', value = 'set sub-color "#D3D3D3"; show-text "Subtitle Color: Light Gray"', active = cur_color:find('D3D3D3') ~= nil},
			},
		},
		{
			title = 'Override Embedded ASS Styles',
			hint = cur_override,
			value = 'cycle-values sub-ass-override "force" "yes" "no"; show-text "Sub Style Override: ${sub-ass-override}"',
		},
		{
			title = 'Reset Subtitle Styles to Defaults',
			value = 'set sub-color "#FFFFFF"; set sub-font "sans-serif"; set sub-scale 1.0; set sub-border-style outline-and-shadow; set sub-border-size 3; set sub-border-color "#000000"; set sub-shadow-offset 0; set sub-back-color "#00000000"; set sub-ass-override yes; show-text "Subtitle Styles Reset to Defaults"',
		},
	}
end


-- Default menu items
function create_default_menu_items()
	return {
		-- 1. File & Streaming
		{title = t('Open file'), value = 'script-binding uosc/open-file', icon = 'folder_open'},
		{title = t('Open URL / Stream Online'), value = 'script-message open-url-menu', icon = 'link'},
		{title = t('Recently Played'), items = get_recent_files_items(), icon = 'history', separator = true},

		-- 2. Playlist & Navigation
		{title = t('Playlist'), value = 'script-binding uosc/items'},
		{title = t('Chapters'), value = 'script-binding uosc/chapters'},
		{
			title = t('Navigation'),
			separator = true,
			items = {
				{title = t('Next'), hint = t('playlist or file'), value = 'script-binding uosc/next'},
				{title = t('Prev'), hint = t('playlist or file'), value = 'script-binding uosc/prev'},
				{title = t('First file'), value = 'script-binding uosc/first'},
				{title = t('Last file'), value = 'script-binding uosc/last', separator = true},
				{
					title = t('Playback speed'),
					items = {
						{title = '0.5x', value = 'set speed 0.5; show-text "Speed: 0.5x"'},
						{title = '0.75x', value = 'set speed 0.75; show-text "Speed: 0.75x"'},
						{title = '1.0x (Normal)', value = 'set speed 1.0; show-text "Speed: 1.0x"'},
						{title = '1.25x', value = 'set speed 1.25; show-text "Speed: 1.25x"'},
						{title = '1.5x', value = 'set speed 1.5; show-text "Speed: 1.5x"'},
						{title = '1.75x', value = 'set speed 1.75; show-text "Speed: 1.75x"'},
						{title = '2.0x', value = 'set speed 2.0; show-text "Speed: 2.0x"', separator = true},
						{title = t('Reset speed (1.0x)'), value = 'set speed 1.0; show-text "Speed: 1.0x"'},
					},
				},
				{title = t('Cycle Loop (Off / Playlist / Episode)'), value = 'script-message cycle-loop'},
				{title = t('Shuffle'), value = 'cycle shuffle', separator = true},
				{title = t('Delete file & Next'), value = 'script-binding uosc/delete-file-next'},
				{title = t('Delete file & Prev'), value = 'script-binding uosc/delete-file-prev'},
				{title = t('Delete file & Quit'), value = 'script-binding uosc/delete-file-quit'},
			},
		},

		-- 3. Core Media Controls: Video, Audio, Subtitles
		{
			title = t('Video'),
			items = {
				{title = t('Video tracks'), value = 'script-binding uosc/video'},
				{title = t('Stream quality'), value = 'script-binding uosc/stream-quality', separator = true},
				{
					title = t('Aspect ratio'),
					items = {
						{title = t('Default'), value = 'set video-aspect-override "-1"'},
						{title = '16:9', value = 'set video-aspect-override "16:9"'},
						{title = '4:3', value = 'set video-aspect-override "4:3"'},
						{title = '2.35:1', value = 'set video-aspect-override "2.35:1"'},
						{title = '21:9', value = 'set video-aspect-override "21:9"'},
					},
				},
				{
					title = t('Video filters & Shaders'),
					separator = true,
					items = {
						{title = t('Cycle Ambient Fill (Blur / Ambient / Off)'), value = 'script-message cycle-ambient-fill'},
						{title = t('Toggle Deband (Banding reduction)'), value = 'cycle deband'},
						{title = t('Toggle CAS Sharpening'), value = 'change-list glsl-shaders toggle "~~/shaders/CAS.glsl"'},
						{title = t('Toggle Deinterlace'), value = 'cycle deinterlace'},
					},
				},
				{title = t('Screenshot'), value = 'async screenshot'},
				{title = t('Screenshot (video only)'), value = 'async screenshot video'},
			},
		},
		{
			title = t('Audio'),
			items = {
				{title = t('Audio tracks'), value = 'script-binding uosc/audio'},
				{title = t('Audio output devices'), value = 'script-binding uosc/audio-device', separator = true},
				{title = t('Toggle Mute'), value = 'cycle mute'},
				{title = t('Audio Delay (-0.1s)'), value = 'add audio-delay -0.1'},
				{title = t('Audio Delay (+0.1s)'), value = 'add audio-delay 0.1'},
				{title = t('Reset Audio Delay'), value = 'set audio-delay 0'},
			},
		},
		{
			title = t('Subtitles'),
			separator = true,
			items = {
				{title = t('Subtitle tracks'), value = 'script-binding uosc/subtitles'},
				{title = t('Subtitle Appearance & Style'), items = get_subtitle_style_items(), separator = true},
				{title = t('Toggle Subtitle Visibility'), value = 'cycle sub-visibility'},
				{title = t('Subtitle Delay (-0.1s)'), value = 'add sub-delay -0.1'},
				{title = t('Subtitle Delay (+0.1s)'), value = 'add sub-delay 0.1'},
				{title = t('Reset Subtitle Delay'), value = 'set sub-delay 0'},
			},
		},

		-- 4. Series & Episode Management
		{
			title = t('Episode Tracker'),
			items = {
				{title = t('Episode Status'), value = 'script-message episode-tracker-ep-status'},
				{title = t('TV Show Status'), value = 'script-message episode-tracker-tv-status'},
				{title = t('Open Last Played'), value = 'script-message episode-tracker-last-played', separator = true},
				{title = t('Mark as Watched'), value = 'script-message mark-watched'},
				{title = t('Mark as Unwatched'), value = 'script-message mark-unwatched'},
			},
		},

		-- 5. Tools & Settings
		{
			title = t('Tools & Settings'),
			separator = true,
			items = {
				{title = t('Pin Window (Always on Top)'), value = 'cycle ontop'},
				{title = t('Key bindings'), value = 'script-binding uosc/keybinds'},
				{title = t('Editions'), value = 'script-binding uosc/editions', separator = true},
				{title = t('Show in directory'), value = 'script-binding uosc/show-in-directory'},
				{title = t('Open config folder'), value = 'script-binding uosc/open-config-directory'},
			},
		},

		-- 6. Application
		{title = t('Check and update latest version'), value = 'script-message check-rmn-update'},
		{title = t('Quit'), value = 'quit'},
	}
end
--[[ STATE ]]

display = {ax = 0, ay = 0, bx = 1280, by = 720, width = 1280, height = 720, initialized = false}
cursor = require('lib/cursor')
state = {
	platform = (function()
		local platform = mp.get_property_native('platform')
		if platform then
			if itable_index_of({'windows', 'darwin'}, platform) then return platform end
		else
			if os.getenv('windir') ~= nil then return 'windows' end
			local homedir = os.getenv('HOME')
			if homedir ~= nil and string.sub(homedir, 1, 6) == '/Users' then return 'darwin' end
		end
		return 'linux'
	end)(),
	cwd = mp.get_property('working-directory'),
	path = nil, -- current file path or URL
	history = {}, -- history of last played files stored as full paths
	time = nil, -- current media playback time
	speed = 1,
	---@type number|nil
	duration = nil, -- current media duration
	max_seconds = nil, -- max seconds the time in timeline is expected to reach, accounted for speed
	time_human = nil, -- current playback time in human format
	destination_time_human = nil, -- depends on options.destination_time
	pause = mp.get_property_native('pause'),
	ime_active = mp.get_property_native('input-ime'),
	chapters = {},
	chapter_ranges = {},
	border = mp.get_property_native('border'),
	title_bar = mp.get_property_native('title-bar'),
	fullscreen = mp.get_property_native('fullscreen'),
	maximized = mp.get_property_native('window-maximized'),
	fullormaxed = mp.get_property_native('fullscreen') or mp.get_property_native('window-maximized'),
	render_timer = nil,
	render_last_time = 0,
	volume = real_to_ui_volume(mp.get_property_native('volume')),
	volume_max = 200,
	mute = nil,
	type = nil, -- video,image,audio
	is_idle = false,
	is_video = false,
	is_audio = false, -- true if file is audio only (mp3, etc)
	is_image = false,
	is_stream = false,
	has_image = false,
	has_audio = false,
	has_sub = false,
	has_chapter = false,
	has_playlist = false,
	shuffle = options.shuffle,
	---@type nil|{pos: number; paths: string[]}
	shuffle_history = nil,
	on_shuffle = function() state.shuffle_history = nil end,
	mouse_bindings_enabled = false,
	uncached_ranges = nil,
	cache = nil,
	cache_buffering = 100,
	cache_underrun = false,
	cache_duration = nil,
	core_idle = false,
	eof_reached = false,
	render_delay = config.render_delay,
	playlist_count = 0,
	playlist_pos = 0,
	margin_top = 0,
	margin_bottom = 0,
	margin_left = 0,
	margin_right = 0,
	hidpi_scale = 1,
	scale = 1,
	radius = 0,
}
buttons = require('lib/buttons')
thumbnail = {width = 0, height = 0, disabled = false}
external = {} -- Properties set by external scripts
key_binding_overwrites = {} -- Table of key_binding:mpv_command
Elements = require('elements/Elements')
Menu = require('elements/Menu')

-- State dependent utilities
require('lib/utils')
require('lib/text')
require('lib/ass')
require('lib/menus')

-- Determine path to ziggy
do
	local bin = 'ziggy-' .. (state.platform == 'windows' and 'windows.exe' or state.platform)
	config.ziggy_path = os.getenv('MPV_UOSC_ZIGGY') or join_path(mp.get_script_directory(), join_path('bin', bin))
end

--[[ STATE UPDATERS ]]

function update_display_dimensions()
	state.scale = (state.hidpi_scale or 1) * (state.fullormaxed and options.scale_fullscreen or options.scale)
	state.radius = round(options.border_radius * state.scale)
	local real_width, real_height = mp.get_osd_size()
	if real_width <= 0 then return end
	display.bx, display.width, display.by, display.height = real_width, real_width, real_height, real_height
	display.initialized = true

	-- Tell elements about this
	Elements:trigger('display')

	-- Some elements probably changed their rectangles as a reaction to `display`
	Elements:update_proximities()
	request_render()
end

function update_fullormaxed()
	state.fullormaxed = state.fullscreen or state.maximized
	update_display_dimensions()
	Elements:trigger('prop_fullormaxed', state.fullormaxed)
	cursor:leave()
end

function update_duration()
	local duration = state._duration and ((state.rebase_start_time == false and state.start_time)
		and (state._duration + state.start_time) or state._duration)
	set_state('duration', duration)
	update_human_times()
end

function update_human_times()
	state.speed = state.speed or 1
	if state.time then
		if state.duration then
			if options.destination_time == 'playtime-remaining' then
				state.destination_time_human = format_time((state.time - state.duration) / state.speed, state.duration)
			elseif options.destination_time == 'total' then
				state.destination_time_human = format_time(state.duration, state.duration)
			else
				state.destination_time_human = format_time(state.time - state.duration, state.duration)
			end
		else
			state.destination_time_human = nil
		end
		state.time_human = format_time(state.time, state.duration or state.time)
	else
		state.time_human, state.destination_time_human = nil, nil
	end
end

-- Notifies other scripts such as console about where the unoccupied parts of the screen are.
function update_margins()
	if display.height == 0 then return end

	local function causes_margin(element)
		return element and element.enabled and (element:is_persistent() or element.min_visibility > 0.5)
	end
	local timeline, top_bar, controls, volume = Elements.timeline, Elements.top_bar, Elements.controls, Elements.volume
	-- margins are normalized to window size
	local left, right, top, bottom = 0, 0, 0, 0

	if causes_margin(controls) then
		bottom = (display.height - controls.ay) / display.height
	elseif causes_margin(timeline) then
		bottom = (display.height - timeline.ay) / display.height
	end

	if causes_margin(top_bar) then top = top_bar.title_by / display.height end

	if causes_margin(volume) then
		if options.volume == 'left' then
			left = volume.bx / display.width
		elseif options.volume == 'right' then
			right = volume.ax / display.width
		end
	end

	if top == state.margin_top and bottom == state.margin_bottom and
		left == state.margin_left and right == state.margin_right then
		return
	end

	state.margin_top = top
	state.margin_bottom = bottom
	state.margin_left = left
	state.margin_right = right

	if utils.shared_script_property_set then
		utils.shared_script_property_set('osc-margins', string.format('%f,%f,%f,%f', 0, 0, top, bottom))
	end
	mp.set_property_native('user-data/osc/margins', {l = left, r = right, t = top, b = bottom})

	if not options.adjust_osd_margins then return end
	local osd_margin_y, osd_margin_x, osd_factor_x = 0, 0, display.width / display.height * 720
	if config.osd_alignment_y == 'bottom' then
		osd_margin_y = round(bottom * 720)
	elseif config.osd_alignment_y == 'top' then
		osd_margin_y = round(top * 720)
	end
	if config.osd_alignment_x == 'left' then
		osd_margin_x = round(left * osd_factor_x)
	elseif config.osd_alignment_x == 'right' then
		osd_margin_x = round(right * osd_factor_x)
	end
	mp.set_property_native('osd-margin-y', osd_margin_y + config.osd_margin_y)
	mp.set_property_native('osd-margin-x', osd_margin_x + config.osd_margin_x)
end
function create_state_setter(name, callback)
	return function(_, value)
		set_state(name, value)
		if callback then callback() end
		request_render()
	end
end

function set_state(name, value)
	state[name] = value
	local state_event = state['on_' .. name]
	if state_event then state_event(value) end
	Elements:trigger('prop_' .. name, value)
end

function handle_file_end()
	local resume = false
	if not state.loop_file then
		if state.has_playlist then
			resume = state.shuffle and navigate_playlist(1)
		else
			resume = options.autoload and navigate_directory(1)
		end
	end
	-- Resume only when navigation happened
	if resume then mp.command('set pause no') end
end
local file_end_timer = mp.add_timeout(1, handle_file_end)
file_end_timer:kill()

function load_file_index_in_current_directory(index)
	if not state.path or is_protocol(state.path) then return end

	local serialized = serialize_path(state.path)
	if serialized and serialized.dirname then
		local files, _dirs, error = read_directory(serialized.dirname, {
			types = config.types.load,
			hidden = options.show_hidden_files,
		})

		if error then
			msg.error(error)
			return
		end

		sort_strings(files)
		if index < 0 then index = #files + index + 1 end

		if files[index] then
			mp.commandv('loadfile', join_path(serialized.dirname, files[index]))
		end
	end
end

function update_render_delay(name, fps)
	if fps then state.render_delay = 1 / fps end
end

function observe_display_fps(name, fps)
	if fps then
		mp.unobserve_property(update_render_delay)
		mp.unobserve_property(observe_display_fps)
		mp.observe_property('display-fps', 'native', update_render_delay)
	end
end

--[[ STATE HOOKS ]]

-- Audio Boost 200+ Architecture (Maximum Perceived Loudness Engine)
local NORMAL_AF = 'lavfi=[highpass=f=45,equalizer=f=450:width_type=q:width=1.2:g=-1.5,equalizer=f=3000:width_type=q:width=1.0:g=2.0,equalizer=f=10000:width_type=q:width=0.8:g=1.5,alimiter=level_in=1:level_out=1:limit=0.99:attack=5:release=50:asc=0]'
local BOOST_AF = 'lavfi=[highpass=f=60,equalizer=f=1400:width_type=q:width=1.0:g=3.5,equalizer=f=3200:width_type=q:width=1.2:g=4.0,dynaudnorm=f=180:g=21:p=0.98:m=28:r=0.92:s=12:b=1,volume=volume=5dB:precision=fixed,asoftclip=type=tanh:threshold=0.85:output=0.98,alimiter=level_in=1:level_out=1:limit=0.99:attack=5:release=80:asc=1]'
local boost_active = false

local function set_boost_mode(enable, show_osd)
	if boost_active == enable then return end
	boost_active = enable
	if enable then
		mp.set_property('af', BOOST_AF)
		if show_osd ~= false then
			mp.osd_message('Volume: 200+ (MAX BOOST)', 1.5)
		end
	else
		mp.set_property('af', NORMAL_AF)
	end
end

mp.register_event('file-loaded', function()
	local path = normalize_path(mp.get_property_native('path'))
	itable_delete_value(state.history, path)
	state.history[#state.history + 1] = path
	set_state('path', path)
	record_recent_file()
	mp.set_property('start', 'none')

	-- Flash top bar on requested file types
	for _, type in ipairs(config.top_bar_flash_on) do
		if state['is_' .. type] then
			Elements:flash({'top_bar'})
			break
		end
	end

	local cur_vol = mp.get_property_number('volume', 100)
	if cur_vol > 300 then
		boost_active = false
		set_boost_mode(true, false)
	end
end)
mp.register_event('end-file', function(event)
	record_recent_file()
	set_state('path', nil)
	if event.reason == 'eof' then
		file_end_timer:kill()
		handle_file_end()
	end
end)
mp.observe_property('playback-time', 'number', create_state_setter('time', function()
	-- Create a file-end event that triggers right before file ends
	file_end_timer:kill()
	if state.duration and state.time and not state.pause then
		local remaining = (state.duration - state.time) / state.speed
		if remaining < 5 then
			local timeout = remaining - 0.02
			if timeout > 0 then
				file_end_timer.timeout = timeout
				file_end_timer:resume()
			else
				handle_file_end()
			end
		end
	end

	update_human_times()
end))
mp.observe_property('rebase-start-time', 'bool', create_state_setter('rebase_start_time', update_duration))
mp.observe_property('demuxer-start-time', 'number', create_state_setter('start_time', update_duration))
mp.observe_property('duration', 'number', create_state_setter('_duration', update_duration))
mp.observe_property('speed', 'number', create_state_setter('speed', update_human_times))
mp.observe_property('track-list', 'native', function(name, value)
	-- checks the file dispositions
	local types = {sub = 0, image = 0, audio = 0, video = 0}
	for _, track in ipairs(value) do
		if track.type == 'video' then
			if track.image or track.albumart then
				types.image = types.image + 1
			else
				types.video = types.video + 1
			end
		elseif types[track.type] then
			types[track.type] = types[track.type] + 1
		end
	end
	set_state('is_audio', types.video == 0 and types.audio > 0)
	set_state('is_image', types.image > 0 and types.video == 0 and types.audio == 0)
	set_state('has_image', types.image > 0)
	set_state('has_audio', types.audio > 0)
	set_state('has_many_audio', types.audio > 1)
	set_state('has_sub', types.sub > 0)
	set_state('has_many_sub', types.sub > 1)
	set_state('is_video', types.video > 0)
	set_state('has_many_video', types.video > 1)
	set_state('type', state.is_video and 'video' or state.is_audio and 'audio' or state.is_image and 'image' or nil)
	update_load_types()
	Elements:trigger('dispositions')
end)
mp.observe_property('editions', 'number', function(_, editions)
	if editions then set_state('has_many_edition', editions > 1) end
	Elements:trigger('dispositions')
end)
mp.observe_property('chapter-list', 'native', function(_, chapters)
	local chapters, chapter_ranges = serialize_chapters(chapters), {}
	if chapters then chapters, chapter_ranges = serialize_chapter_ranges(chapters) end
	set_state('chapters', chapters)
	set_state('chapter_ranges', chapter_ranges)
	set_state('has_chapter', #chapters > 0)
	Elements:trigger('dispositions')
end)
mp.observe_property('border', 'bool', create_state_setter('border'))
mp.observe_property('title-bar', 'bool', create_state_setter('title_bar'))
mp.observe_property('loop-file', 'native', create_state_setter('loop_file'))
mp.observe_property('ab-loop-a', 'number', create_state_setter('ab_loop_a'))
mp.observe_property('ab-loop-b', 'number', create_state_setter('ab_loop_b'))
mp.observe_property('playlist-pos-1', 'number', create_state_setter('playlist_pos'))
mp.observe_property('playlist-count', 'number', function(_, value)
	set_state('playlist_count', value)
	set_state('has_playlist', value > 1)
	Elements:trigger('dispositions')
end)
mp.observe_property('fullscreen', 'bool', create_state_setter('fullscreen', update_fullormaxed))
mp.observe_property('window-maximized', 'bool', create_state_setter('maximized', update_fullormaxed))
mp.observe_property('idle-active', 'bool', function(_, idle)
	set_state('is_idle', idle)
	Elements:trigger('dispositions')
	mp.commandv('script-message-to', 'thumbfast', 'clear')
end)
mp.observe_property('pause', 'bool', create_state_setter('pause', function() file_end_timer:kill() end))
mp.observe_property('volume', 'number', function(_, val)
	val = val or 100
	set_state('volume', real_to_ui_volume(val))
	set_boost_mode(val > 300)
	request_render()
end)
mp.observe_property('volume-max', 'number', function()
	set_state('volume_max', 200)
	request_render()
end)
mp.observe_property('mute', 'bool', create_state_setter('mute'))
mp.observe_property('osd-dimensions', 'native', function(name, val)
	update_display_dimensions()
	request_render()
end)
mp.observe_property('display-hidpi-scale', 'native', create_state_setter('hidpi_scale', update_display_dimensions))
mp.observe_property('cache', 'string', create_state_setter('cache'))
mp.observe_property('cache-buffering-state', 'number', create_state_setter('cache_buffering'))
mp.observe_property('demuxer-via-network', 'native', create_state_setter('is_stream', function()
	Elements:trigger('dispositions')
end))
mp.observe_property('demuxer-cache-state', 'native', function(prop, cache_state)
	local cached_ranges, bof, eof, uncached_ranges = nil, nil, nil, nil
	if cache_state then
		cached_ranges, bof, eof = cache_state['seekable-ranges'], cache_state['bof-cached'], cache_state['eof-cached']
		set_state('cache_underrun', cache_state['underrun'])
		set_state('cache_duration', not cache_state.eof and cache_state['cache-duration'] or nil)
	else
		cached_ranges = {}
	end

	if not (state.duration and (#cached_ranges > 0 or state.cache == 'yes' or
			(state.cache == 'auto' and state.is_stream))) then
		if state.uncached_ranges then set_state('uncached_ranges', nil) end
		set_state('cache_duration', nil)
		return
	end

	-- Normalize
	local ranges = {}
	for _, range in ipairs(cached_ranges) do
		ranges[#ranges + 1] = {
			math.max(range['start'] or 0, 0),
			math.min(range['end'] or state.duration --[[@as number]], state.duration),
		}
	end
	table.sort(ranges, function(a, b) return a[1] < b[1] end)
	if bof then ranges[1][1] = 0 end
	if eof then ranges[#ranges][2] = state.duration end
	-- Invert cached ranges into uncached ranges, as that's what we're rendering
	local inverted_ranges = {{0, state.duration}}
	for _, cached in pairs(ranges) do
		inverted_ranges[#inverted_ranges][2] = cached[1]
		inverted_ranges[#inverted_ranges + 1] = {cached[2], state.duration}
	end
	uncached_ranges = {}
	local last_range = nil
	for _, range in ipairs(inverted_ranges) do
		if last_range and last_range[2] + 0.5 > range[1] then -- fuse ranges
			last_range[2] = range[2]
		else
			if range[2] - range[1] > 0.5 then -- skip short ranges
				uncached_ranges[#uncached_ranges + 1] = range
				last_range = range
			end
		end
	end

	set_state('uncached_ranges', uncached_ranges)
end)
mp.observe_property('display-fps', 'native', observe_display_fps)
mp.observe_property('estimated-display-fps', 'native', update_render_delay)
mp.observe_property('eof-reached', 'native', create_state_setter('eof_reached'))
mp.observe_property('core-idle', 'native', create_state_setter('core_idle'))

--[[ KEY BINDS ]]

-- Adds a key binding that respects rerouting set by `key_binding_overwrites` table.
---@param name string
---@param callback fun(event: table)
---@param flags nil|string
function bind_command(name, callback, flags)
	mp.add_key_binding(nil, name, function(...)
		if key_binding_overwrites[name] then
			mp.command(key_binding_overwrites[name])
		else
			callback(...)
		end
	end, flags)
end

bind_command('toggle-ui', function() Elements:toggle({'timeline', 'controls', 'volume', 'top_bar'}) end)
bind_command('flash-ui', function() Elements:flash({'timeline', 'controls', 'volume', 'top_bar'}) end)
bind_command('flash-timeline', function() Elements:flash({'timeline'}) end)
bind_command('flash-top-bar', function() Elements:flash({'top_bar'}) end)
bind_command('flash-volume', function() Elements:flash({'volume'}) end)
bind_command('add-volume-up', function() mp.commandv('script-message-to', 'uosc', 'add-volume', 5) end, {repeatable = true})
bind_command('add-volume-down', function() mp.commandv('script-message-to', 'uosc', 'add-volume', -5) end, {repeatable = true})
bind_command('flash-speed', function() Elements:flash({'speed'}) end)
bind_command('flash-pause-indicator', function() Elements:flash({'pause_indicator'}) end)
bind_command('flash-progress', function() Elements:flash({'progress'}) end)
bind_command('toggle-progress', function() Elements:maybe('timeline', 'toggle_progress') end)
bind_command('toggle-title', function() Elements:maybe('top_bar', 'toggle_title') end)
bind_command('decide-pause-indicator', function() Elements:maybe('pause_indicator', 'decide') end)
bind_command('menu', function() toggle_menu_with_items() end)
bind_command('menu-blurred', function() toggle_menu_with_items({mouse_nav = true}) end)
bind_command('keybinds', function()
	if Menu:is_open('keybinds') then
		Menu:close()
	else
		open_command_menu({type = 'keybinds', items = get_keybinds_items(), search_style = 'palette'})
	end
end)
bind_command('download-subtitles', open_subtitle_downloader)
bind_command('load-subtitles', create_track_loader_menu_opener({
	prop = 'sub',
	title = t('Load subtitles'),
	loaded_message = t('Loaded subtitles'),
	allowed_types = itable_join(config.types.video, config.types.subtitle),
}))
bind_command('load-audio', create_track_loader_menu_opener({
	prop = 'audio',
	title = t('Load audio'),
	loaded_message = t('Loaded audio'),
	allowed_types = itable_join(config.types.video, config.types.audio),
}))
bind_command('load-video', create_track_loader_menu_opener({
	prop = 'video',
	title = t('Load video'),
	loaded_message = t('Loaded video'),
	allowed_types = config.types.video,
}))
bind_command('subtitles', create_select_tracklist_type_menu_opener({
	title = t('Subtitles'),
	type = 'sub',
	prop = 'sid',
	enable_prop = 'sub-visibility',
	secondary = {prop = 'secondary-sid', icon = 'vertical_align_top', enable_prop = 'secondary-sub-visibility'},
	load_command = 'script-binding uosc/load-subtitles',
	download_command = 'script-binding uosc/download-subtitles',
}))
bind_command('audio', create_select_tracklist_type_menu_opener({
	title = t('Audio'), type = 'audio', prop = 'aid', load_command = 'script-binding uosc/load-audio',
}))
bind_command('video', create_select_tracklist_type_menu_opener({
	title = t('Video'), type = 'video', prop = 'vid', load_command = 'script-binding uosc/load-video',
}))
bind_command('playlist', create_self_updating_menu_opener({
	title = t('Playlist'),
	type = 'playlist',
	list_prop = 'playlist',
	footnote = t('Paste path or url to add.') .. ' ' .. t('%s to reorder.', 'ctrl+up/down/pgup/pgdn/home/end'),
	serializer = function(playlist)
		local items = {}
		local force_filename = mp.get_property_native('osd-playlist-entry') == 'filename'
		for index, item in ipairs(playlist) do
			local title = type(item.title) == 'string' and #item.title > 0 and item.title or false
			items[index] = {
				title = (not force_filename and title) and title
					or (is_protocol(item.filename) and item.filename or serialize_path(item.filename).basename),
				hint = tostring(index),
				active = item.current,
				value = index,
			}
		end
		return items
	end,
	on_activate = function(event) mp.commandv('set', 'playlist-pos-1', tostring(event.value)) end,
	on_paste = function(event) mp.commandv('loadfile', tostring(event.value), 'append') end,
	on_key = function(event)
		if event.id == 'ctrl+c' and event.selected_item then
			local payload = mp.get_property_native('playlist/' .. (event.selected_item.value - 1) .. '/filename')
			set_clipboard(payload)
		end
	end,
	on_move = function(event)
		local from, to = event.from_index, event.to_index
		mp.commandv('playlist-move', tostring(from - 1), tostring(to - (to > from and 0 or 1)))
	end,
	on_remove = function(event) mp.commandv('playlist-remove', tostring(event.value - 1)) end,
}))
bind_command('chapters', create_self_updating_menu_opener({
	title = t('Chapters'),
	type = 'chapters',
	list_prop = 'chapter-list',
	active_prop = 'chapter',
	serializer = function(chapters, current_chapter)
		local items = {}
		chapters = normalize_chapters(chapters)
		for index, chapter in ipairs(chapters) do
			items[index] = {
				title = chapter.title or '',
				hint = format_time(chapter.time, state.duration),
				value = index,
				active = index - 1 == current_chapter,
			}
		end
		return items
	end,
	on_activate = function(event) mp.commandv('set', 'chapter', tostring(event.value - 1)) end,
}))
bind_command('editions', create_self_updating_menu_opener({
	title = t('Editions'),
	type = 'editions',
	list_prop = 'edition-list',
	active_prop = 'current-edition',
	serializer = function(editions, current_id)
		local items = {}
		for _, edition in ipairs(editions or {}) do
			local edition_id_1 = tostring(edition.id + 1)
			items[#items + 1] = {
				title = edition.title or t('Edition %s', edition_id_1),
				hint = edition_id_1,
				value = edition.id,
				active = edition.id == current_id,
			}
		end
		return items
	end,
	on_activate = function(event) mp.commandv('set', 'edition', event.value) end,
}))
bind_command('show-in-directory', function()
	-- Ignore URLs
	if not state.path or is_protocol(state.path) then return end

	if state.platform == 'windows' then
		utils.subprocess_detached({args = {'explorer', '/select,', state.path .. ' '}, cancellable = false})
	elseif state.platform == 'darwin' then
		utils.subprocess_detached({args = {'open', '-R', state.path}, cancellable = false})
	elseif state.platform == 'linux' then
		local result = utils.subprocess({args = {'nautilus', state.path}, cancellable = false})

		-- Fallback opens the folder with xdg-open instead
		if result.status ~= 0 then
			utils.subprocess({args = {'xdg-open', serialize_path(state.path).dirname}, cancellable = false})
		end
	end
end)
bind_command('stream-quality', open_stream_quality_menu)
bind_command('open-file', open_open_file_menu)
bind_command('shuffle', function() set_state('shuffle', not state.shuffle) end)
bind_command('items', function()
	if state.has_playlist then
		mp.command('script-binding uosc/playlist')
	else
		mp.command('script-binding uosc/open-file')
	end
end)
bind_command('next', function() navigate_item(1) end)
bind_command('prev', function() navigate_item(-1) end)
bind_command('next-file', function() navigate_directory(1) end)
bind_command('prev-file', function() navigate_directory(-1) end)
bind_command('first', function()
	if state.has_playlist then
		mp.commandv('set', 'playlist-pos-1', '1')
	else
		load_file_index_in_current_directory(1)
	end
end)
bind_command('last', function()
	if state.has_playlist then
		mp.commandv('set', 'playlist-pos-1', tostring(state.playlist_count))
	else
		load_file_index_in_current_directory(-1)
	end
end)
bind_command('first-file', function() load_file_index_in_current_directory(1) end)
bind_command('last-file', function() load_file_index_in_current_directory(-1) end)
bind_command('delete-file-prev', function() delete_file_navigate(-1) end)
bind_command('delete-file-next', function() delete_file_navigate(1) end)
bind_command('delete-file-quit', function()
	mp.command('stop')
	if state.path and not is_protocol(state.path) then delete_file(state.path) end
	mp.command('quit')
end)
bind_command('menu-prev', function() Elements:maybe('menu', 'navigate_by_items', -1) end)
bind_command('menu-next', function() Elements:maybe('menu', 'navigate_by_items', 1) end)
bind_command('menu-prev-page', function() Elements:maybe('menu', 'navigate_by_page', -1) end)
bind_command('menu-next-page', function() Elements:maybe('menu', 'navigate_by_page', 1) end)
bind_command('menu-start', function() Elements:maybe('menu', 'navigate_by_items', -math.huge) end)
bind_command('menu-end', function() Elements:maybe('menu', 'navigate_by_items', math.huge) end)
bind_command('menu-activate', function() Elements:maybe('menu', 'activate_selected_item') end)
bind_command('menu-back', function() Elements:maybe('menu', 'back') end)
bind_command('audio-device', create_self_updating_menu_opener({
	title = t('Audio devices'),
	type = 'audio-device-list',
	list_prop = 'audio-device-list',
	active_prop = 'audio-device',
	serializer = function(audio_device_list, current_device)
		current_device = current_device or 'auto'
		local ao = mp.get_property('current-ao') or ''
		local items = {}
		for _, device in ipairs(audio_device_list) do
			if device.name == 'auto' or string.match(device.name, '^' .. ao) then
				local hint = string.match(device.name, ao .. '/(.+)')
				if not hint then hint = device.name end
				items[#items + 1] = {
					title = device.description:sub(1, 7) == 'Default'
						and t('Default %s', device.description:sub(9))
						or device.description,
					hint = hint,
					active = device.name == current_device,
					value = device.name,
				}
			end
		end
		return items
	end,
	on_activate = function(event) mp.commandv('set', 'audio-device', event.value) end,
}))
bind_command('paste', function()
	local has_playlist = mp.get_property_native('playlist-count') > 1
	mp.commandv('script-binding', 'uosc/paste-to-' .. (has_playlist and 'playlist' or 'open'))
end)
bind_command('paste-to-open', function()
	local payload = get_clipboard()
	if payload then mp.commandv('loadfile', payload) end
end)
bind_command('paste-to-playlist', function()
	-- If there's no file loaded, we use `paste-to-open`, which both opens and adds to playlist
	if state.is_idle then
		mp.commandv('script-binding', 'uosc/paste-to-open')
	else
		local payload = get_clipboard()
		if payload then
			mp.commandv('loadfile', payload, 'append')
			mp.commandv('show-text', t('Added to playlist') .. ': ' .. payload, 3000)
		end
	end
end)
bind_command('copy-to-clipboard', function()
	if state.path then
		set_clipboard(state.path)
	else
		mp.commandv('show-text', t('Nothing to copy'), 3000)
	end
end)
bind_command('open-config-directory', function()
	local config_path = mp.command_native({'expand-path', '~~/mpv.conf'})
	local config = serialize_path(normalize_path(config_path))

	if config then
		local args

		if state.platform == 'windows' then
			args = {'explorer', '/select,', config.path}
		elseif state.platform == 'darwin' then
			args = {'open', '-R', config.path}
		elseif state.platform == 'linux' then
			args = {'xdg-open', config.dirname}
		end

		utils.subprocess_detached({args = args, cancellable = false})
	else
		msg.error('Couldn\'t serialize config path "' .. config_path .. '".')
	end
end)
bind_command('update', function()
	if not Elements:has('updater') then require('elements/Updater'):new() end
end)

--[[ MESSAGE HANDLERS ]]

mp.register_script_message('show-submenu', function(id) toggle_menu_with_items({submenu = id}) end)
mp.register_script_message('show-submenu-blurred', function(id)
	toggle_menu_with_items({submenu = id, mouse_nav = true})
end)
mp.register_script_message('open-menu', function(json, submenu_id)
	local data = utils.parse_json(json)
	if type(data) ~= 'table' or type(data.items) ~= 'table' then
		msg.error('open-menu: received json didn\'t produce a table with menu configuration')
	else
		open_command_menu(data, {submenu = submenu_id, on_close = data.on_close})
	end
end)
mp.register_script_message('update-menu', function(json)
	local data = utils.parse_json(json)
	if type(data) ~= 'table' or type(data.items) ~= 'table' then
		msg.error('update-menu: received json didn\'t produce a table with menu configuration')
	else
		local menu = data.type and Menu:is_open(data.type)
		if menu then menu:update(data) end
	end
end)
mp.register_script_message('select-menu-item', function(type, item_index, menu_id)
	local menu = Menu:is_open(type)
	local index = tonumber(item_index)
	if menu and index and not menu.mouse_nav then
		index = round(index)
		if index > 0 and index <= #menu.current.items then
			menu:select_index(index, menu_id)
			menu:scroll_to_index(index, menu_id, true)
		end
	end
end)
mp.register_script_message('close-menu', function(type)
	if Menu:is_open(type) then Menu:close() end
end)
mp.register_script_message('menu-action', function(name, ...)
	local menu = Menu:is_open()
	if menu then
		local method = ({
			['search-cancel'] = 'search_cancel',
			['search-query-update'] = 'search_query_update',
		})[name]
		if method then menu[method](menu, ...) end
	end
end)
mp.register_script_message('thumbfast-info', function(json)
	local data = utils.parse_json(json)
	if type(data) ~= 'table' or not data.width or not data.height then
		thumbnail.disabled = true
		msg.error('thumbfast-info: received json didn\'t produce a table with thumbnail information')
	else
		thumbnail = data
		request_render()
	end
end)
mp.register_script_message('set', function(name, value)
	external[name] = value
	Elements:trigger('external_prop_' .. name, value)
end)
mp.register_script_message('toggle-elements', function(elements) Elements:toggle(comma_split(elements)) end)
mp.register_script_message('set-min-visibility', function(visibility, elements)
	local fraction = tonumber(visibility)
	local ids = comma_split(elements and elements ~= '' and elements or 'timeline,controls,volume,top_bar')
	if fraction then Elements:set_min_visibility(clamp(0, fraction, 1), ids) end
end)
mp.register_script_message('flash-elements', function(elements) Elements:flash(comma_split(elements)) end)
mp.register_script_message('overwrite-binding', function(name, command) key_binding_overwrites[name] = command end)
mp.register_script_message('disable-elements', function(id, elements) Manager:disable(id, elements) end)
mp.register_script_message('play-recent-file', function(index_str)
	local idx = tonumber(index_str)
	local item = recent_files[idx]
	if item and item.path then
		local cur_path = mp.get_property('path')
		if cur_path and cur_path ~= '' then
			record_recent_file()
			mp.command('stop')
		end
		if item.position and item.position > 15 and not item.completed then
			mp.set_property('start', tostring(math.floor(item.position)))
		else
			mp.set_property('start', 'none')
		end
		mp.commandv('loadfile', item.path, 'replace')
		local display_title = item.title or item.path:match('([^/\\]+)$') or item.path
		mp.osd_message('Playing: ' .. display_title, 3)
	else
		mp.osd_message('File not found in history', 2)
	end
end)

mp.register_script_message('clear-recent-files', function()
	recent_files = {}
	save_recent_files()
	mp.osd_message('Recently played history cleared', 2.5)
end)

mp.add_periodic_timer(5, record_recent_file)
mp.register_event("shutdown", record_recent_file)

mp.observe_property('pause', 'bool', function(_, paused)
	if paused then record_recent_file() end
end)

mp.register_script_message('add-volume', function(delta)
	delta = tonumber(delta) or 5
	local current_ui = state.volume or real_to_ui_volume(mp.get_property_number('volume', 100))
	local new_ui
	if delta > 0 then
		if current_ui >= 200 then
			new_ui = 205
		else
			new_ui = math.min(200, round(current_ui + delta))
		end
	else
		if current_ui > 200 then
			new_ui = 200
		else
			new_ui = math.max(0, round(current_ui + delta))
		end
	end
	state.volume = new_ui
	local new_real = ui_to_real_volume(new_ui)
	mp.commandv('set', 'volume', new_real)
	Elements:flash({'volume'})
end)


--[[ ELEMENTS ]]

-- Dynamic elements
local constructors = {
	window_border = require('elements/WindowBorder'),
	buffering_indicator = require('elements/BufferingIndicator'),
	pause_indicator = require('elements/PauseIndicator'),
	top_bar = require('elements/TopBar'),
	timeline = require('elements/Timeline'),
	controls = options.controls and options.controls ~= 'never' and require('elements/Controls'),
	volume = itable_index_of({'left', 'right'}, options.volume) and require('elements/Volume'),
}

-- Required elements
require('elements/Curtain'):new()

-- Element manager
-- Handles creating and destroying elements based on disabled_elements user+script config.
Manager = {
	-- Managed disable-able element IDs
	_ids = itable_join(table_keys(constructors), {'idle_indicator', 'audio_indicator'}),
	---@type table<string, string[]> A map of clients and a list of element ids they disable
	_disabled_by = {},
	---@type table<string, boolean>
	disabled = {},
}

-- Set client and which elements it wishes disabled. To undo just pass an empty `element_ids` for the same `client`.
---@param client string
---@param element_ids string|string[]|nil `foo,bar` or `{'foo', 'bar'}`.
function Manager:disable(client, element_ids)
	self._disabled_by[client] = comma_split(element_ids)
	---@diagnostic disable-next-line: deprecated
	self.disabled = create_set(itable_join(unpack(table_values(self._disabled_by))))
	self:_commit()
end

function Manager:_commit()
	-- Create and destroy elements as needed
	for _, id in ipairs(self._ids) do
		local constructor = constructors[id]
		if not self.disabled[id] then
			if not Elements:has(id) and constructor then constructor:new() end
		else
			Elements:maybe(id, 'destroy')
		end
	end

	-- We use `on_display` event to tell elements to update their dimensions
	Elements:trigger('display')
end

-- Initial commit
Manager:disable('user', options.disable_elements)
