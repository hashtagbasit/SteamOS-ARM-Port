local is_portal = false
local file = io.open("/sys/firmware/devicetree/base/compatible", "rb")
if file then
    local compatible, err = file:read("*a")
    file:close()
    if compatible then
        for name in compatible:gmatch("[^%z]+") do
            if name == "ayn,odin2portal" then
                is_portal = true
            end
        end
    else
        warn("Cannot read device-tree compatibility: " .. tostring(err))
    end
end

-- Factory qdcm_calib_data_icna3512_amoled_panel_with_DSC.json, HDR/PostBlendHdrBlob:
-- P3/D65, gamma 2.2, 736.885681 nits at 100% APL, minimum 0.002 nits.
gamescope.config.known_displays.ayn_odin2_portal = {
    pretty_name = "AYN Odin 2 Portal",
    colorimetry = {
        r = { x = 0.680, y = 0.320 },
        g = { x = 0.265, y = 0.690 },
        b = { x = 0.150, y = 0.060 },
        w = { x = 0.3127, y = 0.3290 },
    },
    hdr = {
        supported = true,
        eotf = gamescope.eotf.gamma22,
        max_content_light_level = 736.885681,
        max_frame_average_luminance = 736.885681,
        min_content_light_level = 0.002,
    },
    matches = function(display)
        if is_portal and display.connector and display.connector:match("^DSI%-%d+$") then
            return 5000
        end
        return -1
    end,
}
debug("Registered AYN Odin 2 Portal as a known display")
