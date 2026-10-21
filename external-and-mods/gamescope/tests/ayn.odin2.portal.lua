local profile_path = assert(arg[1], "display profile path required")
local original_open = io.open

local function check(compatible, expected)
    local closed = false
    local warnings = 0
    gamescope = { config = { known_displays = {} }, eotf = { gamma22 = 0 } }
    debug = function() end
    warn = function() warnings = warnings + 1 end
    io.open = function(path, mode)
        assert(path == "/sys/firmware/devicetree/base/compatible" and mode == "rb")
        if compatible == nil then
            return nil, "No such file"
        end
        return {
            read = function()
                if compatible == false then
                    return nil, "Read failed"
                end
                return compatible
            end,
            close = function() closed = true end,
        }
    end
    dofile(profile_path)
    local profile = gamescope.config.known_displays.ayn_odin2_portal
    assert((profile.matches({ connector = "DSI-1" }) >= 0) == expected)
    assert(profile.matches({ connector = "DP-1" }) == -1)
    assert(profile.matches({ connector = "HDMI-A-1" }) == -1)
    assert(profile.matches({}) == -1)
    assert(closed == (compatible ~= nil))
    assert(warnings == (compatible == false and 1 or 0))
    assert(profile.hdr.supported and profile.hdr.eotf == gamescope.eotf.gamma22)
    assert(profile.hdr.max_content_light_level == 736.885681)
    assert(profile.hdr.max_frame_average_luminance == 736.885681)
    assert(profile.hdr.min_content_light_level == 0.002)
end

check("ayn,odin2portal\0qcom,qcs8550\0qcom,sm8550\0", true)
check("ayn,odin2\0qcom,sm8550\0", false)
check("not-ayn,odin2portal\0", false)
check("", false)
check(nil, false)
check(false, false)
io.open = original_open
print("Portal HDR profile matching tests passed")
