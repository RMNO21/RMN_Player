-- ambient-fill.lua: Dynamic Fullscreen Background Fill & Ambient Glow
-- Modes: Normal (Off) -> Solid Color -> Ambient Glow
-- Automatically detects screen resolution via Win32 API and activates ONLY in Fullscreen mode.
-- Solid Color Mode: Ultra-lightweight adaptive solid color with smooth temporal transitions.
-- Ambient Glow Mode: Universal Symmetric Ambilight with 4% edge scan, multi-pass diffusion, temporal LERP, and power gamma.

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

-- Modes: 1 = "off", 2 = "solid", 3 = "ambient"
local MODES = {
    { id = "off", label = "Normal (Off)" },
    { id = "solid", label = "Solid Color" },
    { id = "ambient", label = "Ambient Glow" },
}
local current_mode = 1 -- default off
local last_applied_vf = ""

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
        if last_applied_vf ~= "" then
            mp.set_property("glsl-shaders", "")
            mp.set_property("vf", "")
            mp.set_property("video-aspect-override", "-2")
            mp.set_property("hwdec", "auto-safe")
            last_applied_vf = ""
        end
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
        if last_applied_vf ~= "" then
            mp.set_property("glsl-shaders", "")
            mp.set_property("vf", "")
            mp.set_property("video-aspect-override", "-2")
            mp.set_property("hwdec", "auto-safe")
            last_applied_vf = ""
        end
        return
    end

    local is_letterbox = (v_aspect > target_aspect)
    local target_w, target_h
    local bar_size = 0

    if is_letterbox then
        -- Letterbox (bars on top/bottom, e.g. 16:9 on 16:10):
        target_w = vw
        target_h = math.floor((vw / target_aspect) / 2) * 2
        bar_size = math.floor((target_h - vh) / 4) * 2
        target_h = vh + bar_size * 2
    else
        -- Pillarbox (bars on left/right, e.g. 9:16 or 4:3 on 16:9):
        target_w = math.floor((vh * target_aspect) / 2) * 2
        target_h = vh
        bar_size = math.floor((target_w - vw) / 4) * 2
        target_w = vw + bar_size * 2
    end

    local vf_str = ""
    local mode_id = MODES[current_mode].id

    if mode_id == "solid" then
        -- Intelligent Peripheral-Aware Solid Ambient:
        -- 1. Peripheral Sampling: Crops border bands (top/bottom or left/right), completely ignoring 
        --    central 70% where actors move. Eliminates walking-induced flicker at the physical source.
        -- 2. IIR Adaptive Temporal Filter (hqdn3d=0:0:28:28): Higher temporal strength for ultra-fluid,
        --    cinematic-smooth transitions. Accumulator still flushes within 2-3 frames on scene cuts.
        -- 3. Weighted Micro-Smoothing (tmix 1:2:3:5:8): 5-frame Fibonacci-weighted blend for
        --    buttery, gradual fade-in with zero hard edges.
        local sample_filter = ""
        if is_letterbox then
            -- Sample top 18% & bottom 18% bands, merge together, exclude center
            sample_filter = "scale=32:18:flags=area,split[t_in][b_in]; [t_in]crop=iw:3:0:0[top]; [b_in]crop=iw:3:0:ih-3[bot]; [top][bot]vstack,scale=1:1:flags=area"
        else
            -- Sample left 18% & right 18% bands, merge together, exclude center
            sample_filter = "scale=18:32:flags=area,split[l_in][r_in]; [l_in]crop=3:ih:0:0[left]; [r_in]crop=3:ih:iw-3:0[right]; [left][right]hstack,scale=1:1:flags=area"
        end

        vf_str = string.format(
            "lavfi=[split[fg][bg]; [bg]%s,format=yuv420p,hqdn3d=0:0:28:28,tmix=frames=5:weights='1 2 3 5 8',eq=contrast=0.95:brightness=-0.06:saturation=1.20:gamma=0.88,scale=%d:%d:flags=neighbor[bg_solid]; [bg_solid][fg]overlay=(W-w)/2:(H-h)/2:eof_action=pass:repeatlast=0,setsar=1]",
            sample_filter, target_w, target_h
        )
    elseif mode_id == "ambient" then
        -- Progressive Edge Contrast Ambilight (Zero Artificial Black Borders, Pure Luminance Preservation):
        -- 1. Zero Artificial Black Borders: No forced black vignette. White scenes stay 100% pure white, black scenes stay pure black.
        -- 2. Variable Edge Contrast: Contrast increases progressively from 1.1 near video to 5.0 at the outer screen edges.
        -- 3. Pure Chromatic Fidelity: Contrast operates on Luminance (YUV), completely locking HUE so skin tones never turn orange.
        -- 4. Planar GBRP Blur: gblur with sigma=4 on GBRP preserves full chromatic fidelity without chroma stripping.
        -- 5. Perfect Spatial Alignment & Deband: area downscale + bicubic upscale for dead-center sub-pixel matching.
        local base_scale = is_letterbox and "32:18" or "18:32"
        local dist_expr = is_letterbox
            and "abs(2*Y - (H-1))/(H-1)"
            or  "abs(2*X - (W-1))/(W-1)"
        local contrast_expr = string.format("(1.1 + 3.9*pow(%s, 2))", dist_expr)
        local geq_expr = string.format(
            "lum='clip(128 + %s*(lum(X,Y)-128), 0, 255)':cb='cb(X,Y)':cr='cr(X,Y)'",
            contrast_expr
        )
        vf_str = string.format(
            "lavfi=[split[fg][bg]; [bg]scale=%s:flags=area,format=gbrp,gblur=sigma=4:steps=2,format=yuv420p,geq=%s,tmix=frames=3:weights='1 2 4',scale=%d:%d:flags=bicubic,gradfun=strength=5.0:radius=16,eq=saturation=1.20[bg_glow]; [bg_glow][fg]overlay=(W-w)/2:(H-h)/2:eof_action=pass:repeatlast=0,setsar=1]",
            base_scale, geq_expr, target_w, target_h
        )
    end

    if vf_str == last_applied_vf then
        return
    end

    if vf_str ~= "" then
        mp.set_property("glsl-shaders", "")
        mp.set_property("hwdec", "no")
        mp.set_property("video-align-x", "0")
        mp.set_property("video-align-y", "0")
        mp.set_property("vf", vf_str)
        mp.set_property("video-aspect-override", "-1")
        last_applied_vf = vf_str
        msg.info(string.format("Applied %s mode in fullscreen (%dx%d -> %dx%d)", mode_id, vw, vh, target_w, target_h))
    else
        mp.set_property("glsl-shaders", "")
        mp.set_property("vf", "")
        mp.set_property("video-aspect-override", "-2")
        mp.set_property("hwdec", "auto-safe")
        last_applied_vf = ""
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

msg.info("ambient-fill.lua initialized (deep dreamy blur & universal symmetric Ambilight).")
