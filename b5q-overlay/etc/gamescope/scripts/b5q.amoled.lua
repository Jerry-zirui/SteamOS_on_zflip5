-- SPDX-License-Identifier: GPL-3.0-only
-- Copyright (C) 2026 Jerry-zirui (https://github.com/Jerry-zirui/SteamOS_on_zflip5)
--
-- Samsung Galaxy Z Flip 5 (SM-F7310 / b5q) internal AMOLED (1080x2640 portrait, 60/120 Hz HS).
-- Matches EDID-less DSI panel via DT model string and uses exact stock S6E3FAC 951 Mbps timings
-- (fixed pixel clock 393,890 kHz with stretched VFP for 60 Hz, matching panel-samsung-s6e3fac-b5q.c).

local b5q_refresh_rates = { 60, 120 }
local FIXED_CLOCK = 393891

local function is_b5q()
    local ok, f = pcall(io.open, "/sys/firmware/devicetree/base/model", "r")
    if not ok or not f then return false end
    local model = f:read("*a") or ""
    f:close()
    return model:find("Samsung Galaxy Z Flip5", 1, true) ~= nil
end

gamescope.config.known_displays.b5q_amoled = {
    pretty_name = "Samsung Galaxy Z Flip5 AMOLED",
    dynamic_refresh_rates = b5q_refresh_rates,
    hdr = {
        supported = false,
        force_enabled = false,
        eotf = gamescope.eotf.gamma22,
        max_content_light_level = 500,
        max_frame_average_luminance = 500,
        min_content_light_level = 0.0
    },
    dynamic_modegen = function(base_mode, refresh)
        local mode = base_mode
        local vfp = (refresh <= 75) and 2748 or 24
        mode.clock = FIXED_CLOCK
        gamescope.modegen.adjust_front_porch(mode, vfp)
        mode.vrefresh = gamescope.modegen.calc_vrefresh(mode)
        debug("[b5q_amoled] " .. refresh .. "Hz: clock=" .. mode.clock .. " vtotal=" .. mode.vtotal .. " vref=" .. mode.vrefresh)
        return mode
    end,
    matches = function(display)
        if (display.vendor or "") == "" and (display.model or "") == "" and is_b5q() then
            debug("[b5q_amoled] Matched EDID-less Z Flip 5 S6E3FAC panel")
            return 5000
        end
        return -1
    end
}
debug("Registered Samsung Galaxy Z Flip5 AMOLED as a known display")
