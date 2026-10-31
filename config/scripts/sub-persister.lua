-- sub-persister.lua — Persistent Subtitle Appearance & Style Manager
-- Automatically remembers subtitle font, size, color, background box,
-- shadow, outline, and ASS override settings across sessions and files.

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

local is_applying = false
local settings = {}
local save_timer = nil

-- List of subtitle properties to persist
local TRACKED_PROPS = {
    'sub-font',
    'sub-scale',
    'sub-font-size',
    'sub-color',
    'sub-border-style',
    'sub-back-color',
    'sub-border-size',
    'sub-border-color',
    'sub-shadow-offset',
    'sub-shadow-color',
    'sub-ass-override',
    'sub-pos',
    'sub-bold',
    'sub-italic',
}

-- Resolve config directory
local function get_config_dir()
    local ok, dir = pcall(function() return mp.command_native({'expand-path', '~~home/'}) end)
    if ok and dir and dir ~= '' then return dir end
    local ok2, dir2 = pcall(function() return mp.command_native({'expand-path', '~~/'}) end)
    if ok2 and dir2 and dir2 ~= '' then return dir2 end
    local appdata = os.getenv('APPDATA')
    if appdata then return appdata .. '/RMN-Player' end
    local xdg = os.getenv('XDG_CONFIG_HOME') or (os.getenv('HOME') and (os.getenv('HOME') .. '/.config'))
    if xdg then return xdg .. '/RMN-Player' end
    return '.'
end

local config_file = get_config_dir() .. '/subtitle-settings.json'

-- JSON serialization fallback if mp.utils is restricted
local function format_json(val)
    if utils and utils.format_json then
        local ok, res = pcall(utils.format_json, val)
        if ok and res then return res end
    end
    -- Pure Lua simple serializer for flat key-value table
    local parts = {}
    for k, v in pairs(val) do
        local str_v
        if type(v) == 'boolean' then
            str_v = v and 'true' or 'false'
        elseif type(v) == 'number' then
            str_v = tostring(v)
        else
            str_v = '"' .. tostring(v):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
        end
        parts[#parts + 1] = string.format('  "%s": %s', k, str_v)
    end
    return '{\n' .. table.concat(parts, ',\n') .. '\n}\n'
end

local function parse_json(str)
    if not str or str == '' then return nil end
    if utils and utils.parse_json then
        local ok, res = pcall(utils.parse_json, str)
        if ok and type(res) == 'table' then return res end
    end
    -- Simple line parser for flat JSON
    local res = {}
    for line in str:gmatch('[^\r\n]+') do
        local k, v = line:match('"([%w%-_]+)"%s*:%s*"?([^",\r\n]+)"?')
        if k and v then
            if v == 'true' then res[k] = true
            elseif v == 'false' then res[k] = false
            elseif tonumber(v) then res[k] = tonumber(v)
            else res[k] = v:gsub('^"', ''):gsub('"$', '') end
        end
    end
    return res
end

-- Save settings to disk
local function save_to_disk()
    if is_applying then return end
    local json_str = format_json(settings)
    local f, err = io.open(config_file, 'w')
    if f then
        f:write(json_str)
        f:close()
        msg.debug('Subtitle settings saved to ' .. config_file)
    else
        msg.warn('Failed to save subtitle settings: ' .. tostring(err))
    end
end

local function schedule_save()
    if is_applying then return end
    if not save_timer then
        save_timer = mp.add_timeout(0.3, function()
            save_to_disk()
            save_timer = nil
        end)
    else
        save_timer:kill()
        save_timer:resume()
    end
end

-- Apply in-memory settings to MPV
local function apply_settings()
    if not settings or next(settings) == nil then return end
    is_applying = true

    for prop, val in pairs(settings) do
        if val ~= nil then
            if type(val) == 'boolean' then
                mp.set_property_bool(prop, val)
            elseif type(val) == 'number' then
                mp.set_property_number(prop, val)
            else
                mp.set_property(prop, tostring(val))
            end
        end
    end

    -- Delay resetting flag slightly so immediate observer triggers don't save back
    mp.add_timeout(0.1, function()
        is_applying = false
    end)
end

-- Load from disk
local function load_from_disk()
    local f = io.open(config_file, 'r')
    if f then
        local content = f:read('*a')
        f:close()
        local data = parse_json(content)
        if data and type(data) == 'table' and next(data) ~= nil then
            settings = data
            msg.info('Loaded persistent subtitle settings from ' .. config_file)
            apply_settings()
            return true
        end
    end
    return false
end

-- Initialization: Load settings once at script load
local loaded = load_from_disk()

-- If no settings existed yet, record current MPV subtitle state as base
if not loaded then
    for _, prop in ipairs(TRACKED_PROPS) do
        local val = mp.get_property_native(prop)
        if val ~= nil then
            settings[prop] = val
        end
    end
end

-- Ensure saved subtitle settings are strictly re-applied when any file is loaded
mp.register_event('file-loaded', function()
    apply_settings()
end)

-- Observe properties and record user modifications
for _, prop in ipairs(TRACKED_PROPS) do
    mp.observe_property(prop, 'native', function(_, val)
        if is_applying then return end
        if val == nil then return end

        if settings[prop] ~= val then
            settings[prop] = val
            schedule_save()
        end
    end)
end

-- Flush pending save on player exit
mp.register_event('shutdown', function()
    if save_timer then
        save_timer:kill()
        save_timer = nil
    end
    save_to_disk()
end)

-- Script messages
mp.register_script_message('reload-sub-settings', function()
    load_from_disk()
end)

mp.register_script_message('save-sub-settings', function()
    save_to_disk()
end)
