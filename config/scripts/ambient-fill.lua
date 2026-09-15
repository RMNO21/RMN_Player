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
-- Solid Color look-ahead: [fg] is delayed SOLID_LOOKAHEAD frames so the gaussian ambient
-- is centered symmetrically on the current displayed frame (past + future frames blended).
-- audio-delay is compensated automatically when solid mode is active.
local SOLID_LOOKAHEAD = 7        -- video delay frames (~233ms at 30fps, ~156ms at 45fps)
local original_audio_delay = nil -- saved audio-delay before solid mode compensation

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
        -- Restore audio-delay that was set for solid mode look-ahead compensation
        if original_audio_delay ~= nil then
            mp.set_property("audio-delay", original_audio_delay)
            original_audio_delay = nil
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
        if original_audio_delay ~= nil then
            mp.set_property("audio-delay", original_audio_delay)
            original_audio_delay = nil
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
        -- Centered Gaussian Ambient with Look-Ahead (Non-Causal Temporal Filter):
        -- 1. Peripheral Sampling: border bands only, ignoring central 70%.
        -- 2. tpad=start=LOOKAHEAD: delays [fg] video by SOLID_LOOKAHEAD frames so the tmix
        --    window is centered on the currently displayed frame. The ambient "sees" past AND
        --    future frames relative to what's on screen — scene transitions start early.
        -- 3. Symmetric Gaussian tmix (M=2L+1=7, sigma=2): weights '325 607 883 1000 883 607 325'
        --    →  past frames  ←  current  →  future frames  ←
        --    At the exact scene cut frame: 50% old / 50% new ambient (perfect crossfade).
        --    Crossfade spans ±SOLID_LOOKAHEAD frames = ±100ms at 30fps (±67ms at 45fps).
        -- 4. Audio-delay compensated below to keep A/V sync after video delay.
        -- 5. 16-bit processing + YouTube-style tone (dark, desaturated, non-distracting).
        local sample_filter = ""
        if is_letterbox then
            sample_filter = "scale=32:18:flags=area,split[t_in][b_in]; [t_in]crop=iw:3:0:0[top]; [b_in]crop=iw:3:0:ih-3[bot]; [top][bot]vstack,scale=1:1:flags=area"
        else
            sample_filter = "scale=18:32:flags=area,split[l_in][r_in]; [l_in]crop=3:ih:0:0[left]; [r_in]crop=3:ih:iw-3:0[right]; [left][right]hstack,scale=1:1:flags=area"
        end

        -- Compensate audio-delay: tpad shifts video PTS by +SOLID_LOOKAHEAD frames,
        -- so audio must be delayed by the same duration to stay in sync.
        local fps = mp.get_property_native("container-fps")
               or mp.get_property_native("estimated-vf-fps")
               or 30
        if original_audio_delay == nil then
            original_audio_delay = mp.get_property("audio-delay") or "0"
        end
        local base_delay = tonumber(original_audio_delay) or 0
        mp.set_property("audio-delay", tostring(base_delay + SOLID_LOOKAHEAD / fps))

        -- 3. Symmetric Gaussian tmix (M=2L+1=15, sigma=4): weights centered at position 7
        --    '216 325 458 607 755 883 969 1000 969 883 755 607 458 325 216'
        --    Crossfade spans ±2*sigma=±8 frames = ±267ms at 30fps. Ultra-smooth, cinematic.
        -- Anti-micro-jump pipeline (two-pronged):
        --   a) hqdn3d=0:0:4:4 before tmix: suppresses ±4-luma compression noise in source
        --      signal BEFORE it enters the gaussian window. Scene cuts (diff >>4) pass through.
        --   b) format=yuv420p AFTER scale: dithering is applied to the full-size image
        --      (e.g. 400x300 = 120k pixels) instead of 1x1 pixel, giving sub-LSB resolution
        --      through spatial dithering that the eye integrates to a smooth gradient.
        vf_str = string.format(
            "lavfi=[split[fg_raw][bg]; [fg_raw]tpad=start=%d:start_mode=clone[fg]; [bg]%s,hqdn3d=0:0:4:4,format=yuv420p16le,tmix=frames=15:weights='216 325 458 607 755 883 969 1000 969 883 755 607 458 325 216',scale=%d:%d:flags=neighbor,format=yuv420p[bg_solid]; [bg_solid][fg]overlay=(W-w)/2:(H-h)/2:eof_action=pass:repeatlast=0,setsar=1]",
            SOLID_LOOKAHEAD, sample_filter, target_w, target_h
        )
    elseif mode_id == "ambient" then
        -- Restore audio-delay when switching to Ambient Glow (no lookahead needed there)
        if original_audio_delay ~= nil then
            mp.set_property("audio-delay", original_audio_delay)
            original_audio_delay = nil
        end

        -- Progressive Edge Contrast Ambilight (Zero Artificial Black Borders, Pure Luminance Preservation):
        -- 1. Zero Artificial Black Borders: No forced black vignette. White scenes stay 100% pure white, black scenes stay pure black.
        -- 2. Variable Edge Contrast: Contrast increases progressively from 1.1 near video to 5.0 at the outer screen edges.
        -- 3. Pure Chromatic Fidelity: Contrast operates on Luminance (YUV), completely locking HUE so skin tones never turn orange.
        -- 4. Planar GBRP Blur: gblur with sigma=4 on GBRP preserves full chromatic fidelity without chroma stripping.
        -- 5. Perfect Spatial Alignment & Deband: area downscale + bicubic upscale for dead-center sub-pixel matching.
        -- Natural Optical Luminance Falloff (True Cinema Ambilight):
        -- 1. Balanced 1.15 contrast ensures vivid, clear illumination without dark clipping.
        -- 2. Quadratic Luminance Decay: (1.0 - 0.65*d^2) smoothly dissolves outer screen edges towards darkness.
        -- 3. Planar GBRP diffusion + bicubic upscale guarantees velvety gradient transition.
        local base_scale = is_letterbox and "32:18" or "18:32"
        local dist_expr = is_letterbox
            and "abs(2*Y - (H-1))/(H-1)"
            or  "abs(2*X - (W-1))/(W-1)"
        local geq_expr = string.format(
            "lum='clip((128 + 1.15*(lum(X,Y)-128)) * (1.0 - 0.65*pow(%s, 2)), 0, 255)':cb='cb(X,Y)':cr='cr(X,Y)'",
            dist_expr
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
