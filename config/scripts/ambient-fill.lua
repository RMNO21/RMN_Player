-- ambient-fill.lua: Dynamic Fullscreen Background Fill & Ambient Glow
-- Modes: Normal (Off) -> Blurred Background -> Ambient Glow
-- Automatically detects screen resolution via Win32 API and activates ONLY in Fullscreen mode.
-- High-Performance vstack/hstack Architecture: 100% crash-proof seeking even when holding down arrow keys.

local mp = require("mp")
local msg = require("mp.msg")
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

local function apply_filter()
    local is_fs = mp.get_property_bool("fullscreen", false)

    -- Only apply in fullscreen mode and when mode > 1
    if not is_fs or current_mode == 1 then
        mp.set_property("vf", "")
        mp.set_property("video-aspect-override", "-2")
        return
    end

    local vw = mp.get_property_number("video-params/w", 0)
    local vh = mp.get_property_number("video-params/h", 0)
    if vw <= 0 or vh <= 0 then return end

    local v_aspect = vw / vh
    local target_aspect = get_screen_aspect()
    local diff = math.abs(v_aspect - target_aspect)

    -- If video already matches screen aspect ratio within 0.8%, skip
    if diff < 0.008 then
        mp.set_property("vf", "")
        mp.set_property("video-aspect-override", "-2")
        return
    end

    local is_letterbox = (v_aspect > target_aspect)
    local target_w, target_h, overlay_coords
    local bar_size = 0

    if is_letterbox then
        -- Letterbox (bars on top/bottom, e.g. 16:9 on 16:10):
        target_w = vw
        target_h = math.floor((vw / target_aspect) / 2) * 2
        bar_size = math.floor((target_h - vh) / 2)
        overlay_coords = "0:(H-h)/2"
    else
        -- Pillarbox (bars on left/right, e.g. 9:16 or 4:3 on 16:9):
        target_w = math.floor((vh * target_aspect) / 2) * 2
        target_h = vh
        bar_size = math.floor((target_w - vw) / 2)
        overlay_coords = "(W-w)/2:0"
    end

    local vf_str = ""
    local mode_id = MODES[current_mode].id

    if mode_id == "blur" then
        -- Blurred Background Mode: Full background softly blurred with single-axis aspect stretch
        local scale_w = math.floor(vw / 4 / 2) * 2
        local scale_h = math.floor(vh / 4 / 2) * 2
        vf_str = string.format(
            "lavfi=[split [fg][bg]; [bg]format=yuv420p,scale=%d:%d:flags=fast_bilinear,avgblur=sizeX=6:sizeY=6,scale=%d:%d:flags=bilinear,eq=brightness=-0.1:contrast=0.92[bg_blur]; [bg_blur][fg]overlay=%s:eof_action=pass:repeatlast=0,setsar=1]",
            scale_w, scale_h, target_w, target_h, overlay_coords
        )
    elseif mode_id == "ambient" then
        -- Ultra-Lean vstack/hstack High-Contrast Ambilight:
        -- Single-pass deterministic stacking eliminates all buffer queuing and seek crashes.
        local crop_d = 20
        if is_letterbox then
            vf_str = string.format(
                "lavfi=[split=3[fg][s_top][s_bot]; [s_top]crop=%d:%d:0:0,scale=100:10:flags=fast_bilinear,eq=contrast=1.75:brightness=-0.08:saturation=1.85:gamma=0.68,avgblur=sizeX=20:sizeY=6,scale=%d:%d:flags=bilinear[top_glow]; [s_bot]crop=%d:%d:0:%d,scale=100:10:flags=fast_bilinear,eq=contrast=1.75:brightness=-0.08:saturation=1.85:gamma=0.68,avgblur=sizeX=20:sizeY=6,scale=%d:%d:flags=bilinear[bot_glow]; [top_glow][fg][bot_glow]vstack=3,setsar=1]",
                vw, crop_d, vw, bar_size,
                vw, crop_d, vh - crop_d, vw, bar_size
            )
        else
            vf_str = string.format(
                "lavfi=[split=3[fg][s_lft][s_rgt]; [s_lft]crop=%d:%d:0:0,scale=10:100:flags=fast_bilinear,eq=contrast=1.75:brightness=-0.08:saturation=1.85:gamma=0.68,avgblur=sizeX=6:sizeY=20,scale=%d:%d:flags=bilinear[lft_glow]; [s_rgt]crop=%d:%d:%d:0,scale=10:100:flags=fast_bilinear,eq=contrast=1.75:brightness=-0.08:saturation=1.85:gamma=0.68,avgblur=sizeX=6:sizeY=20,scale=%d:%d:flags=bilinear[rgt_glow]; [lft_glow][fg][rgt_glow]hstack=3,setsar=1]",
                crop_d, vh, bar_size, vh,
                crop_d, vh, vw - crop_d, bar_size, vh
            )
        end
    end

    if vf_str ~= "" then
        mp.set_property("vf", vf_str)
        mp.set_property("video-aspect-override", "-1")
        msg.info(string.format("Applied %s mode in fullscreen (%dx%d -> %dx%d, screen aspect: %.3f)", mode_id, vw, vh, target_w, target_h, target_aspect))
    else
        mp.set_property("vf", "")
        mp.set_property("video-aspect-override", "-2")
    end
end

local function cycle_ambient_fill()
    current_mode = current_mode + 1
    if current_mode > #MODES then
        current_mode = 1
    end

    local is_fs = mp.get_property_bool("fullscreen", false)
    local mode_info = MODES[current_mode]

    apply_filter()

    if not is_fs and current_mode > 1 then
        mp.osd_message(string.format("Background: %s (Active in Fullscreen)", mode_info.label), 2.5)
    else
        mp.osd_message(string.format("Background: %s", mode_info.label), 2.5)
    end
end

local function on_fullscreen_change(name, is_fs)
    if current_mode > 1 then
        apply_filter()
    end
end

local function on_playback_change()
    if current_mode > 1 then
        apply_filter()
    end
end

mp.register_script_message("cycle-ambient-fill", cycle_ambient_fill)
mp.register_script_message("toggle-ambient-fill", cycle_ambient_fill)
mp.register_event("playback-restart", on_playback_change)
mp.observe_property("fullscreen", "bool", on_fullscreen_change)

msg.info("ambient-fill.lua initialized (ultra-lean vstack/hstack engine).")
