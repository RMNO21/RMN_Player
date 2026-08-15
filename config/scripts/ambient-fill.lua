-- ambient-fill.lua: Dynamic Fullscreen Background Fill & Ambient Glow
-- Modes: Normal (Off) -> Blurred Background -> Ambient Glow
-- Pure GPU GLSL User Shader Architecture: 100% Zero-CPU, Zero-Copy, 100% crash-proof seeking.

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")
local ffi_loaded, ffi = pcall(require, "ffi")

if ffi_loaded then
    pcall(function()
        ffi.cdef[[
            typedef void* HMONITOR;
            typedef void* HWND;
            typedef struct tagRECT {
                long left;
                long top;
                long right;
                long bottom;
            } RECT;
            typedef struct tagMONITORINFO {
                unsigned long cbSize;
                RECT rcMonitor;
                RECT rcWork;
                unsigned long dwFlags;
            } MONITORINFO;

            HWND GetActiveWindow(void);
            HWND GetForegroundWindow(void);
            HMONITOR MonitorFromWindow(HWND hwnd, unsigned long dwFlags);
            int GetMonitorInfoW(HMONITOR hMonitor, MONITORINFO* lpmi);
            int GetSystemMetrics(int nIndex);
        ]]
    end)
end

-- Modes: 1 = "off", 2 = "blur", 3 = "ambient"
local MODES = {
    { id = "off", label = "Normal (Off)" },
    { id = "blur", label = "Blurred Background" },
    { id = "ambient", label = "Ambient Glow" },
}
local current_mode = 1 -- default off

local function get_shaders_dir()
    local config_dir = mp.command_native({"expand-path", "~~/shaders"})
    return config_dir:gsub("\\", "/")
end

local function get_screen_aspect()
    -- 1. Query the physical active monitor where MPV is located via Win32 API
    if ffi_loaded and ffi.C and ffi.C.GetMonitorInfoW and ffi.C.MonitorFromWindow then
        local hwnd = nil
        if ffi.C.GetActiveWindow then
            hwnd = ffi.C.GetActiveWindow()
        end
        if (hwnd == nil or ffi.cast("uintptr_t", hwnd) == 0) and ffi.C.GetForegroundWindow then
            hwnd = ffi.C.GetForegroundWindow()
        end

        if hwnd ~= nil and ffi.cast("uintptr_t", hwnd) ~= 0 then
            local hmon = ffi.C.MonitorFromWindow(hwnd, 2) -- MONITOR_DEFAULTTONEAREST = 2
            if hmon ~= nil and ffi.cast("uintptr_t", hmon) ~= 0 then
                local mi = ffi.new("MONITORINFO")
                mi.cbSize = ffi.sizeof("MONITORINFO")
                if ffi.C.GetMonitorInfoW(hmon, mi) ~= 0 then
                    local mw = mi.rcMonitor.right - mi.rcMonitor.left
                    local mh = mi.rcMonitor.bottom - mi.rcMonitor.top
                    if mw > 0 and mh > 0 then
                        return mw / mh
                    end
                end
            end
        end

        -- 2. Fallback to Primary Monitor Metrics
        if ffi.C.GetSystemMetrics then
            local sw = ffi.C.GetSystemMetrics(0)
            local sh = ffi.C.GetSystemMetrics(1)
            if sw and sh and sw > 0 and sh > 0 then
                return sw / sh
            end
        end
    end

    -- 3. Fallback to MPV OSD / Display dimensions
    local osd_w, osd_h = mp.get_osd_size()
    if osd_w and osd_h and osd_w > 0 and osd_h > 0 then
        return osd_w / osd_h
    end

    local dw = mp.get_property_number("display-width", 0)
    local dh = mp.get_property_number("display-height", 0)
    if dw > 0 and dh > 0 then
        return dw / dh
    end

    return 16 / 10
end

local function apply_effect()
    local is_fs = mp.get_property_bool("fullscreen", false)

    -- Only apply in fullscreen mode and when mode > 1
    if not is_fs or current_mode == 1 then
        mp.set_property("glsl-shaders", "")
        mp.set_property("video-aspect-override", "-2")
        mp.set_property("vf", "")
        return
    end

    local vw = mp.get_property_number("video-params/w", 0)
    local vh = mp.get_property_number("video-params/h", 0)
    if vw <= 0 or vh <= 0 then return end

    local v_aspect = vw / vh
    local target_aspect = get_screen_aspect()
    local diff = math.abs(v_aspect - target_aspect)

    -- If video matches screen aspect ratio within 0.8%, no letterbox/pillarbox needed
    if diff < 0.008 then
        mp.set_property("glsl-shaders", "")
        mp.set_property("video-aspect-override", "-2")
        mp.set_property("vf", "")
        return
    end

    local shaders_dir = get_shaders_dir()
    local mode_id = MODES[current_mode].id
    local shader_file = ""

    if mode_id == "blur" then
        shader_file = shaders_dir .. "/blur-fill.hook"
    elseif mode_id == "ambient" then
        shader_file = shaders_dir .. "/ambilight.hook"
    end

    if shader_file ~= "" then
        mp.set_property("vf", "")
        mp.set_property("video-aspect-override", tostring(target_aspect))
        mp.set_property("glsl-shaders", shader_file)
        msg.info(string.format("Applied GPU Shader %s (screen aspect: %.3f)", mode_id, target_aspect))
    else
        mp.set_property("glsl-shaders", "")
        mp.set_property("video-aspect-override", "-2")
        mp.set_property("vf", "")
    end
end

local function cycle_ambient_fill()
    current_mode = current_mode + 1
    if current_mode > #MODES then
        current_mode = 1
    end

    local is_fs = mp.get_property_bool("fullscreen", false)
    local mode_info = MODES[current_mode]

    apply_effect()

    if not is_fs and current_mode > 1 then
        mp.osd_message(string.format("Background: %s (Active in Fullscreen)", mode_info.label), 2.5)
    else
        mp.osd_message(string.format("Background: %s", mode_info.label), 2.5)
    end
end

local function on_fullscreen_change(name, is_fs)
    apply_effect()
end

local function on_file_loaded()
    apply_effect()
end

mp.register_script_message("cycle-ambient-fill", cycle_ambient_fill)
mp.register_script_message("toggle-ambient-fill", cycle_ambient_fill)
mp.register_event("file-loaded", on_file_loaded)
mp.observe_property("fullscreen", "bool", on_fullscreen_change)
mp.observe_property("video-params", "native", apply_effect)

msg.info("ambient-fill.lua initialized (pure GPU GLSL shader engine).")
