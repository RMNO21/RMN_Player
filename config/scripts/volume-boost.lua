-- ==============================================================================
-- RMN Player - Intelligent Audio Volume Boost (100% - 200%)
-- ==============================================================================
-- Below 100%: 100% pure, untouched, standard linear/log software volume.
-- 100% - 200%: Truly powerful amplification (up to +18 dB) protected by a
--              transparent lookahead peak limiter to eliminate all digital
--              clipping, harshness, and crackle.
-- ==============================================================================

local filter_label = "rmn_volboost"
local filter_tag = "@" .. filter_label
local is_filter_active = false
local last_applied_limit = nil
local pending_timer = nil

local function remove_limiter()
    if is_filter_active then
        mp.commandv("af", "remove", filter_tag)
        is_filter_active = false
        last_applied_limit = nil
    end
end

local function apply_limiter(limit)
    -- Format with 5 decimal places precision
    local filter_spec = string.format("%s:lavfi=[alimiter=limit=%.5f:attack=5:release=50:asc=false:level=false]", filter_tag, limit)
    
    if is_filter_active then
        mp.commandv("af", "remove", filter_tag)
    end
    
    mp.commandv("af", "add", filter_spec)
    is_filter_active = true
    last_applied_limit = limit
end

local function sync_volume_boost(vol)
    if not vol then
        vol = mp.get_property_native("volume")
    end
    if not vol then return end

    if vol <= 100.0 then
        if pending_timer then
            pending_timer:kill()
            pending_timer = nil
        end
        remove_limiter()
        return
    end

    -- Volume > 100%:
    -- In mpv, softvol multiplier at output AO is M = (volume / 100)^3.
    -- To guarantee output peaks never exceed safe headroom (0.98 = -0.17 dBFS):
    -- limit = 0.98 / M.
    local m = (vol / 100.0) ^ 3
    local target_limit = 0.98 / m

    -- Clamp to valid alimiter range [0.0625, 1.0]
    if target_limit < 0.0625 then target_limit = 0.0625 end
    if target_limit > 1.0 then target_limit = 1.0 end

    -- Avoid redundant filter updates if limit hasn't changed significantly
    if last_applied_limit and math.abs(last_applied_limit - target_limit) < 0.002 then
        return
    end

    -- If the filter is not active yet, apply immediately for instant response
    if not is_filter_active then
        apply_limiter(target_limit)
        return
    end

    -- Debounce rapid mouse wheel / key repeat events (25ms)
    if pending_timer then
        pending_timer:kill()
    end
    pending_timer = mp.add_timeout(0.025, function()
        pending_timer = nil
        apply_limiter(target_limit)
    end)
end

mp.observe_property("volume", "number", function(_, vol)
    sync_volume_boost(vol)
end)

mp.register_event("file-loaded", function()
    sync_volume_boost()
end)

mp.register_event("playback-restart", function()
    sync_volume_boost()
end)
