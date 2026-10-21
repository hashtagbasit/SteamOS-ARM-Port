/* Included after SDL's X11 root-window property helpers. */
static void STEAMOS_GetPortalHDR(SDL_HDROutputProperties *hdr)
{
    size_t size = 0;
    char *compatible = SDL_LoadFile("/proc/device-tree/compatible", &size);
    if (!compatible) {
        return;
    }
    bool portal = false;
    const char name[] = "ayn,odin2portal";
    for (size_t offset = 0; offset < size;) {
        size_t length = 0;
        while (length < size - offset && compatible[offset + length] != '\0') {
            ++length;
        }
        if (length == size - offset) {
            break;
        }
        if (length == sizeof(name) - 1 && SDL_memcmp(compatible + offset, name, length) == 0) {
            portal = true;
            break;
        }
        offset += length + 1;
    }
    SDL_free(compatible);
    if (!portal) {
        return;
    }

    /* Gamescope exposes these properties on :0, including for clients on :1. */
    Display *display = X11_XOpenDisplay(":0");
    if (!display) {
        SDL_LogWarn(SDL_LOG_CATEGORY_VIDEO, "SteamOS HDR: cannot query Gamescope");
        return;
    }
    bool external = true, supported = false, active = false;
    float white = 0.0f;
    bool enabled =
        GetRootWindowBoolProperty(display, 0, "GAMESCOPE_DISPLAY_IS_EXTERNAL", &external) &&
        GetRootWindowBoolProperty(display, 0, "GAMESCOPE_DISPLAY_SUPPORTS_HDR", &supported) &&
        GetRootWindowBoolProperty(display, 0, "GAMESCOPE_HDR_OUTPUT_FEEDBACK", &active) &&
        !external && supported && active;
    bool have_white = enabled && GetRootWindowFloatProperty(
        display, 0, "GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS", &white);
    X11_XCloseDisplay(display);
    if (!enabled) {
        return;
    }
    if (!have_white || !(white > 0.0f && white < STEAMOS_PORTAL_PEAK_NITS)) {
        SDL_LogWarn(SDL_LOG_CATEGORY_VIDEO, "SteamOS HDR: invalid Gamescope SDR white level");
        return;
    }
    hdr->SDR_white_level = white / SCRGB_NITS;
    hdr->HDR_headroom = STEAMOS_PORTAL_PEAK_NITS / white;
    SDL_Log("SteamOS HDR: Portal white=%.3f nits, peak=%.3f nits, headroom=%.3f",
            white, (double)STEAMOS_PORTAL_PEAK_NITS, hdr->HDR_headroom);
}
