-- autoload.lua
-- Automatically loads playlist entries before and after the currently played file.
-- Enhanced with Smart TV Show Detection, Fuzzy Matching, and Chronological Episode Sorting.

local MAX_ENTRIES = 5000
local MAX_DIR_STACK = 20

local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    disabled = false,
    images = true,
    videos = true,
    audio = true,
    additional_image_exts = "",
    additional_video_exts = "",
    additional_audio_exts = "",
    ignore_hidden = true,
    same_type = false,
    same_show = true,
    fuzzy_match = true,
    directory_mode = "auto",
    ignore_patterns = ""
}

local function Set(t)
    local set = {}
    for _, v in pairs(t) do set[v] = true end
    return set
end

local EXTENSIONS_VIDEO_DEFAULT = Set {
    '3g2', '3gp', 'avi', 'flv', 'm2ts', 'm4v', 'mj2', 'mkv', 'mov',
    'mp4', 'mpeg', 'mpg', 'ogv', 'rmvb', 'webm', 'wmv', 'y4m'
}

local EXTENSIONS_AUDIO_DEFAULT = Set {
    'aiff', 'ape', 'au', 'flac', 'm4a', 'mka', 'mp3', 'oga', 'ogg',
    'ogm', 'opus', 'wav', 'wma'
}

local EXTENSIONS_IMAGES_DEFAULT = Set {
    'avif', 'bmp', 'gif', 'j2k', 'jp2', 'jpeg', 'jpg', 'jxl', 'png',
    'svg', 'tga', 'tif', 'tiff', 'webp'
}

local EXTENSIONS, EXTENSIONS_VIDEO, EXTENSIONS_AUDIO, EXTENSIONS_IMAGES

local function SetUnion(a, b)
    for k in pairs(b) do a[k] = true end
    return a
end

-- Returns first and last positions in string or past-to-end indices
local function FindOrPastTheEnd(string, pattern, start_at)
    local pos1, pos2 = string:find(pattern, start_at)
    return pos1 or #string + 1,
           pos2 or #string + 1
end

local function Split(list)
    local set = {}
    local item_pos = 1
    local item = ""

    while item_pos <= #list do
        local pos1, pos2 = FindOrPastTheEnd(list, "%%*,", item_pos)
        local pattern_length = pos2 - pos1
        local is_comma_escaped = pattern_length % 2
        local pos_before_escape = pos1 - 1
        local item_escape_count = pattern_length - is_comma_escaped

        item = item .. string.sub(list, item_pos, pos_before_escape + item_escape_count)

        if is_comma_escaped == 1 then
            item = item .. ","
        else
            set[item] = true
            item = ""
        end

        item_pos = pos2 + 1
    end

    set[item] = true
    set[""] = nil
    return set
end

local function split_option_exts(video, audio, image)
    if video then o.additional_video_exts = Split(o.additional_video_exts) end
    if audio then o.additional_audio_exts = Split(o.additional_audio_exts) end
    if image then o.additional_image_exts = Split(o.additional_image_exts) end
end

local function split_patterns()
    o.ignore_patterns = Split(o.ignore_patterns)
end

local function create_extensions()
    EXTENSIONS = {}
    EXTENSIONS_VIDEO = {}
    EXTENSIONS_AUDIO = {}
    EXTENSIONS_IMAGES = {}
    if o.videos then
        SetUnion(SetUnion(EXTENSIONS_VIDEO, EXTENSIONS_VIDEO_DEFAULT), o.additional_video_exts)
        SetUnion(EXTENSIONS, EXTENSIONS_VIDEO)
    end
    if o.audio then
        SetUnion(SetUnion(EXTENSIONS_AUDIO, EXTENSIONS_AUDIO_DEFAULT), o.additional_audio_exts)
        SetUnion(EXTENSIONS, EXTENSIONS_AUDIO)
    end
    if o.images then
        SetUnion(SetUnion(EXTENSIONS_IMAGES, EXTENSIONS_IMAGES_DEFAULT), o.additional_image_exts)
        SetUnion(EXTENSIONS, EXTENSIONS_IMAGES)
    end
end

local function validate_directory_mode()
    if o.directory_mode ~= "recursive" and o.directory_mode ~= "lazy"
       and o.directory_mode ~= "ignore" then
        o.directory_mode = nil
    end
end

options.read_options(o, "autoload", function(list)
    split_option_exts(list.additional_video_exts, list.additional_audio_exts,
                      list.additional_image_exts)
    if list.videos or list.additional_video_exts or
        list.audio or list.additional_audio_exts or
        list.images or list.additional_image_exts then
        create_extensions()
    end
    if list.directory_mode then
        validate_directory_mode()
    end
    if list.ignore_patterns then
        split_patterns()
    end
end)

split_option_exts(true, true, true)
split_patterns()
create_extensions()
validate_directory_mode()

local function get_extension(path)
    return path:match("%.([^%.]+)$") or "nomatch"
end

local function is_ignored(file)
    for pattern in pairs(o.ignore_patterns) do
        if file:match(pattern) then
            return true
        end
    end
    return false
end

-- ==================== SMART MEDIA MATCHING ENGINE ====================

local JUNK_WORDS = {
    "720p", "1080p", "2160p", "4k", "uhd", "hd", "sd", "480p", "576p",
    "web%-dl", "webrip", "web", "bluray", "blu%-ray", "bdrip", "brrip", "dvdrip", "dvd", "hdtv", "pdtv", "dsr",
    "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "10bit", "8bit", "12bit", "hdr", "hdr10", "hdr10plus", "dv", "dolby", "vision",
    "aac", "aac2%.0", "ac3", "eac3", "dts", "dts%-hd", "truehd", "atmos", "ddp5%.1", "dd5%.1", "6ch", "2ch",
    "psa", "yify", "yts", "rarbg", "galaxyrg", "tgx", "ettv", "eztv", "flux", "ntb", "amzn", "nf", "hmax", "dsnp", "atvp",
    "film2media", "valamovie", "4dooble", "farsi", "dubbed", "sub", "persian", "softsub", "multi", "multisub", "dual", "audio",
    "repack", "proper", "rerip", "internal", "remastered", "unrated", "extended", "directors", "cut", "edition"
}

local ORDINALS = {
    ["1st"] = "first",
    ["2nd"] = "second",
    ["3rd"] = "third",
    ["4th"] = "fourth",
    ["5th"] = "fifth",
    ["6th"] = "sixth",
    ["7th"] = "seventh",
    ["8th"] = "eighth",
    ["9th"] = "ninth",
    ["10th"] = "tenth",
}

local function stem_word(w)
    if not w or #w == 0 then return "" end
    w = w:lower()

    if ORDINALS[w] then w = ORDINALS[w] end

    w = w:gsub("ie$", "i")
    w = w:gsub("y$", "i")

    if #w > 3 and w:sub(-1) == "s" and not w:match("ss$") then
        w = w:sub(1, -2)
        w = w:gsub("ie$", "i")
        w = w:gsub("y$", "i")
    end

    local collapsed = {}
    local last_char = ""
    for i = 1, #w do
        local c = w:sub(i, i)
        if c ~= last_char or not c:match("[a-z]") then
            table.insert(collapsed, c)
            last_char = c
        end
    end
    return table.concat(collapsed)
end

local function normalize_title(str)
    if not str then return "", {}, {} end
    str = str:lower()

    str = str:gsub("&", " and ")
    str = str:gsub("@", " at ")

    str = str:gsub("^%b[]", " ")
    str = str:gsub("^%b()", " ")
    str = str:gsub("^%b{}", " ")

    str = str:gsub("[%._%-%+/%|\\]", " ")
    str = str:gsub("['\"`]", "")

    for _, kw in ipairs(JUNK_WORDS) do
        str = str:gsub("%f[%a%d]" .. kw .. "%f[%A%d]", " ")
    end

    str = str:gsub("%f[%d]19%d%d%f[%D]", " ")
    str = str:gsub("%f[%d]20%d%d%f[%D]", " ")

    str = str:gsub("[^%w%s]", " ")
    str = str:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    str = str:gsub("^the%s+", "")
    str = str:gsub("^a%s+", "")
    str = str:gsub("^an%s+", "")

    local tokens = {}
    local stemmed_tokens = {}
    for word in str:gmatch("%S+") do
        if #word > 0 then
            table.insert(tokens, word)
            local stemmed = stem_word(word)
            if #stemmed > 0 then
                table.insert(stemmed_tokens, stemmed)
            end
        end
    end

    return str, tokens, stemmed_tokens
end

local function parse_media(filename)
    if not filename or filename == "" then return nil end
    local name = filename:match("([^/\\]+)$") or filename
    local ext = name:match("%.([^%.]+)$")
    local name_no_ext = (ext and #ext <= 5) and name:sub(1, -(#ext + 2)) or name

    local season, episode, ep_end
    local show_raw = ""
    local is_episode = false
    local is_multipart = false
    local part_num = nil

    -- Pure number filename like "01.mkv", "02.mp4"
    if name_no_ext:match("^%d+$") then
        return {
            filename = name,
            is_episode = true,
            is_multipart = false,
            season = 1,
            episode = tonumber(name_no_ext),
            part = 0,
            raw_show = "",
            clean_title = "",
            tokens = {},
            stemmed_tokens = {},
        }
    end

    -- 1. Standard S01E05 or S01E05-E06 or S01.E05 or S01_E05
    local s_pos, e_pos, s_num, e_num, e_num_end = name_no_ext:lower():find("[%.%s_%-]s(%d+)[%.%s_%-]?e(%d+)[%-%s_%.e]*(%d*)")
    if s_pos then
        show_raw = name_no_ext:sub(1, s_pos - 1)
        season = tonumber(s_num)
        episode = tonumber(e_num)
        ep_end = tonumber(e_num_end)
        is_episode = true
    end

    -- 2. 1x05 or 01x05 format
    if not is_episode then
        s_pos, e_pos, s_num, e_num = name_no_ext:lower():find("[%.%s_%-](%d%d?)x(%d%d+)")
        if s_pos then
            show_raw = name_no_ext:sub(1, s_pos - 1)
            season = tonumber(s_num)
            episode = tonumber(e_num)
            is_episode = true
        end
    end

    -- 3. Season 1 Episode 5 / Season 01
    if not is_episode then
        s_pos, e_pos, s_num, e_num = name_no_ext:lower():find("[%.%s_%-]season[%.%s_%-]*(%d+)[%.%s_%-]*episode[%.%s_%-]*(%d+)")
        if s_pos then
            show_raw = name_no_ext:sub(1, s_pos - 1)
            season = tonumber(s_num)
            episode = tonumber(e_num)
            is_episode = true
        else
            s_pos, e_pos, s_num = name_no_ext:lower():find("[%.%s_%-]season[%.%s_%-]*(%d+)")
            if s_pos then
                show_raw = name_no_ext:sub(1, s_pos - 1)
                season = tonumber(s_num)
                local ep_match = name_no_ext:sub(e_pos + 1):lower():match("^[%.%s_%-]*[ep]*[%.%s_%-]*(%d+)")
                if ep_match then episode = tonumber(ep_match) end
                is_episode = true
            end
        end
    end

    -- 4. EP05 or Ep. 05 or Episode 05 (without explicit Season -> default Season 1)
    if not is_episode then
        s_pos, e_pos, e_num = name_no_ext:lower():find("[%.%s_%-]ep?i?s?o?d?e?[%.%s_%-]*(%d%d+)")
        if s_pos then
            local pre = name_no_ext:sub(1, s_pos - 1)
            if not pre:lower():match("1080$") and not pre:lower():match("720$") and not pre:lower():match("2160$") then
                show_raw = pre
                season = 1
                episode = tonumber(e_num)
                is_episode = true
            end
        end
    end

    -- 5. Anime style: Show Name - 05 or Show Name - 05 (1080p)
    if not is_episode then
        local pre, ep_str = name_no_ext:match("^(.-)%s+%-%s+(%d%d?%d?)%s*")
        if pre and ep_str and not pre:lower():match("part$") and not pre:lower():match("cd$") and not pre:lower():match("disc$") then
            show_raw = pre
            season = 1
            episode = tonumber(ep_str)
            is_episode = true
        end
    end

    -- 6. Multi-part movie: Part 1, CD1, Disc 1
    local p_pos, _, p_num = name_no_ext:lower():find("[%.%s_%-](?:part|cd|disc)[%.%s_%-]*(%d+)")
    if p_pos then
        show_raw = name_no_ext:sub(1, p_pos - 1)
        part_num = tonumber(p_num)
        is_multipart = true
    end

    if not is_episode and not is_multipart then
        local y_pos = name_no_ext:find("[%s%.%-_%(]%d%d%d%d[%s%.%-_%)]")
        if y_pos then
            show_raw = name_no_ext:sub(1, y_pos - 1)
        else
            show_raw = name_no_ext
        end
    end

    local clean_title, tokens, stemmed_tokens = normalize_title(show_raw)

    return {
        filename = name,
        is_episode = is_episode,
        is_multipart = is_multipart,
        season = season or 0,
        episode = episode or 0,
        part = part_num or 0,
        raw_show = show_raw,
        clean_title = clean_title,
        tokens = tokens,
        stemmed_tokens = stemmed_tokens,
    }
end

local function levenshtein(s1, s2)
    local l1, l2 = #s1, #s2
    if l1 == 0 then return l2 end
    if l2 == 0 then return l1 end

    local d = {}
    for i = 0, l1 do d[i] = {[0] = i} end
    for j = 0, l2 do d[0][j] = j end

    for i = 1, l1 do
        for j = 1, l2 do
            local cost = (s1:sub(i, i) == s2:sub(j, j)) and 0 or 1
            d[i][j] = math.min(
                d[i-1][j] + 1,
                d[i][j-1] + 1,
                d[i-1][j-1] + cost
            )
        end
    end
    return d[l1][l2]
end

local function string_similarity(s1, s2)
    if s1 == s2 then return 1.0 end
    local max_len = math.max(#s1, #s2)
    if max_len == 0 then return 1.0 end
    local dist = levenshtein(s1, s2)
    return 1.0 - (dist / max_len)
end

local function is_same_show(m1, m2)
    if not m1 or not m2 then return false end

    -- Both are numbered files without show names (e.g. 01.mkv and 02.mkv in the same folder)
    if m1.is_episode and m2.is_episode and #m1.clean_title == 0 and #m2.clean_title == 0 then
        return true
    end

    -- If one is an episode and one is clearly a standalone movie, do not match
    if m1.is_episode ~= m2.is_episode and not m1.is_multipart and not m2.is_multipart then
        return false
    end

    -- If both are multi-part movies, match on title
    if m1.is_multipart and m2.is_multipart then
        return m1.clean_title == m2.clean_title or string_similarity(m1.clean_title, m2.clean_title) >= 0.85
    end

    -- If both are standalone (neither is episode nor multipart), only match if same clean title
    if not m1.is_episode and not m2.is_episode then
        return m1.clean_title == m2.clean_title and #m1.clean_title > 0
    end

    -- Both are TV Show episodes:
    if m1.clean_title == m2.clean_title and #m1.clean_title > 0 then
        return true
    end

    local st1 = table.concat(m1.stemmed_tokens, " ")
    local st2 = table.concat(m2.stemmed_tokens, " ")
    if st1 == st2 and #st1 > 0 then
        return true
    end

    if not o.fuzzy_match then return false end

    -- Subset / prefix containment (e.g. "Georgie & Mandy" vs "Georgie & Mandy's First Marriage")
    local shorter, longer
    if #m1.stemmed_tokens <= #m2.stemmed_tokens then
        shorter = m1.stemmed_tokens
        longer = m2.stemmed_tokens
    else
        shorter = m2.stemmed_tokens
        longer = m1.stemmed_tokens
    end

    if #shorter >= 2 then
        local match_count = 0
        local last_idx = 0
        for _, s_tok in ipairs(shorter) do
            for j = last_idx + 1, #longer do
                local l_tok = longer[j]
                if s_tok == l_tok or string_similarity(s_tok, l_tok) >= 0.8 then
                    match_count = match_count + 1
                    last_idx = j
                    break
                end
            end
        end
        if match_count == #shorter or (match_count >= 2 and match_count / #shorter >= 0.75) then
            return true
        end
    end

    -- Fuzzy similarity on stemmed strings
    if #st1 >= 4 and #st2 >= 4 then
        local sim = string_similarity(st1, st2)
        if sim >= 0.75 then
            return true
        end
    end

    return false
end

-- ==================== SORTING & SCANNING ====================

local function padnum(n, d)
    return #d > 0 and ("%03d%s%.12f"):format(#n, n, tonumber(d) / (10 ^ #d))
        or ("%03d%s"):format(#n, n)
end

local function media_sort(filenames)
    local tuples = {}
    for i, f in ipairs(filenames) do
        local m = parse_media(f)
        local key
        if m and (m.season > 0 or m.episode > 0 or m.part > 0) then
            key = string.format("s%04de%04dp%04d", m.season, m.episode, m.part)
        else
            key = f:lower():gsub("0*(%d+)%.?(%d*)", padnum)
        end
        tuples[i] = {key = key, filename = f, season = m and m.season or 0, episode = m and m.episode or 0}
    end

    table.sort(tuples, function(a, b)
        if a.season ~= b.season and (a.season > 0 and b.season > 0) then
            return a.season < b.season
        end
        if a.episode ~= b.episode and (a.episode > 0 and b.episode > 0) then
            return a.episode < b.episode
        end
        return a.key < b.key
    end)

    for i, tuple in ipairs(tuples) do
        filenames[i] = tuple.filename
    end
    return filenames
end

local autoloaded
local added_entries = {}
local autoloaded_dir

local function scan_dir(path, current_file, current_media, dir_mode, separator, dir_depth, total_files, extensions)
    if dir_depth == MAX_DIR_STACK then
        return
    end
    msg.trace("scanning: " .. path)
    local files = utils.readdir(path, "files") or {}
    local dirs = dir_mode ~= "ignore" and utils.readdir(path, "dirs") or {}
    local prefix = path == "." and "" or path

    local function filter(t, iter)
        for i = #t, 1, -1 do
            if not iter(t[i]) then
                table.remove(t, i)
            end
        end
    end

    filter(files, function(v)
        local full_path = prefix .. v
        -- Always accept current file
        if full_path == current_file then
            return true
        end
        if o.ignore_hidden and v:match("^%.") then
            return false
        end
        if is_ignored(v) then
            return false
        end

        local ext = get_extension(v)
        if not (ext and extensions[ext:lower()]) then
            return false
        end

        -- Smart TV Show / Collection filtering
        if o.same_show and current_media then
            local cand_media = parse_media(v)
            if not is_same_show(current_media, cand_media) then
                return false
            end
        end

        return true
    end)

    filter(dirs, function(d)
        return not (o.ignore_hidden and d:match("^%."))
    end)

    media_sort(files)
    media_sort(dirs)

    for i, file in ipairs(files) do
        files[i] = prefix .. file
    end

    local function append(t1, t2)
        local t1_size = #t1
        for i = 1, #t2 do
            t1[t1_size + i] = t2[i]
        end
    end

    append(total_files, files)
    if dir_mode == "recursive" then
        for _, dir in ipairs(dirs) do
            scan_dir(prefix .. dir .. separator, current_file, current_media, dir_mode,
                     separator, dir_depth + 1, total_files, extensions)
        end
    else
        for i, dir in ipairs(dirs) do
            dirs[i] = prefix .. dir
        end
        append(total_files, dirs)
    end
end

local function add_files(files)
    local oldcount = mp.get_property_number("playlist-count", 1)
    for i = 1, #files do
        mp.commandv("loadfile", files[i][1], "append")
        mp.commandv("playlist-move", oldcount + i - 1, files[i][2])
    end
end

local function find_and_add_entries()
    local aborted = mp.get_property_native("playback-abort")
    if aborted then
        msg.debug("stopping: playback aborted")
        return
    end

    local path = mp.get_property("path", "")
    local dir, filename = utils.split_path(path)
    msg.trace(("dir: %s, filename: %s"):format(dir, filename))
    if o.disabled then
        msg.debug("stopping: autoload disabled")
        return
    elseif #dir == 0 then
        msg.debug("stopping: not a local path")
        return
    end

    local pl_count = mp.get_property_number("playlist-count", 1)
    local this_ext = get_extension(filename)

    if pl_count > 1 and autoloaded == nil then
        msg.debug("stopping: manually made playlist")
        return
    elseif pl_count == 1 then
        autoloaded = true
        autoloaded_dir = dir
        added_entries = {}
    end

    local extensions
    if o.same_type then
        if EXTENSIONS_VIDEO[this_ext:lower()] then
            extensions = EXTENSIONS_VIDEO
        elseif EXTENSIONS_AUDIO[this_ext:lower()] then
            extensions = EXTENSIONS_AUDIO
        elseif EXTENSIONS_IMAGES[this_ext:lower()] then
            extensions = EXTENSIONS_IMAGES
        end
    else
        extensions = EXTENSIONS
    end
    if not extensions then
        msg.debug("stopping: no matched extensions list")
        return
    end

    local pl = mp.get_property_native("playlist", {})
    local pl_current = mp.get_property_number("playlist-pos-1", 1)

    local current_media = parse_media(filename)

    local files = {}
    scan_dir(autoloaded_dir, path, current_media,
             o.directory_mode or mp.get_property("directory-mode", "lazy"),
             mp.get_property_native("platform") == "windows" and "\\" or "/",
             0, files, extensions)

    if next(files) == nil then
        msg.debug("no other files or directories in directory")
        return
    end

    -- Find the current pl entry in the sorted dir list
    local current
    for i = 1, #files do
        if files[i] == path then
            current = i
            break
        end
    end
    if not current then
        msg.debug("current file not found in directory")
        return
    end

    for _, entry in ipairs(pl) do
        added_entries[entry.filename] = true
    end
    added_entries[path] = true

    local append = {[-1] = {}, [1] = {}}
    for direction = -1, 1, 2 do
        for i = 1, MAX_ENTRIES do
            local pos = current + i * direction
            local file = files[pos]
            if file == nil or file[1] == "." then
                break
            end

            if not added_entries[file] then
                if direction == -1 then
                    msg.verbose("Prepending " .. file)
                    table.insert(append[-1], 1, {file, pl_current + i * direction + 1})
                else
                    msg.verbose("Adding " .. file)
                    if pl_count > 1 then
                        table.insert(append[1], {file, pl_current + i * direction - 1})
                    else
                        mp.commandv("loadfile", file, "append")
                    end
                end
                added_entries[file] = true
            end
        end
        if pl_count == 1 and direction == -1 and #append[-1] > 0 then
            local load = append[-1]
            for i = 1, #load do
                mp.commandv("loadfile", load[i][1], "append")
            end
            mp.commandv("playlist-move", 0, current)
        end
    end

    if pl_count > 1 then
        add_files(append[1])
        add_files(append[-1])
    end
end

mp.register_event("start-file", find_and_add_entries)
