from pathlib import Path
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[1]
sdl = Path(sys.argv[1])
peak = float(sys.argv[2])
source = (sdl / "src/render/vulkan/SDL_render_vulkan.c").read_text()
selection = source[source.index("    VkFormat desiredFormat ="):
                   source.index("    rendererData->swapchainSize.width =")]
mapping = source[source.index("static const struct\n{\n    SDL_PixelFormat sdl;"):
                 source.index("static int VULKAN_GetFormatImageCount")]
formats = r"""
#include <assert.h>
#include <SDL3/SDL_pixels.h>
#include <SDL3/SDL_endian.h>
#include <vulkan/vulkan.h>
MAPPING
static VkSurfaceFormatKHR choose(SDL_Colorspace colorspace,
                                 VkSurfaceFormatKHR *formats, uint32_t count)
{
    struct { SDL_Colorspace output_colorspace; } r = {colorspace}, *renderer = &r;
    struct {
        uint32_t surfaceFormatsCount;
        VkSurfaceFormatKHR *surfaceFormats;
        VkSurfaceFormatKHR surfaceFormat;
    } d = {count, formats, {0}}, *rendererData = &d;
SELECTION
    return rendererData->surfaceFormat;
}
int main(void)
{
    const VkSurfaceFormatKHR sdr = {VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR};
    const VkSurfaceFormatKHR argb = {VK_FORMAT_A2R10G10B10_UNORM_PACK32, VK_COLOR_SPACE_HDR10_ST2084_EXT};
    const VkSurfaceFormatKHR abgr = {VK_FORMAT_A2B10G10R10_UNORM_PACK32, VK_COLOR_SPACE_HDR10_ST2084_EXT};
    const VkSurfaceFormatKHR linear = {VK_FORMAT_R16G16B16A16_SFLOAT, VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT};
    VkSurfaceFormatKHR portal[] = {sdr, argb};
    VkSurfaceFormatKHR result = choose(SDL_COLORSPACE_HDR10, portal, 2);
    assert(result.format == argb.format && result.colorSpace == argb.colorSpace);
    VkSurfaceFormatKHR both[] = {sdr, argb, abgr};
    result = choose(SDL_COLORSPACE_HDR10, both, 3);
    assert(result.format == abgr.format && result.colorSpace == abgr.colorSpace);
    VkSurfaceFormatKHR reversed[] = {sdr, abgr, argb};
    assert(choose(SDL_COLORSPACE_HDR10, reversed, 3).format == abgr.format);
    VkSurfaceFormatKHR wrong[] = {
        {VK_FORMAT_A2B10G10R10_UNORM_PACK32, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR}, argb
    };
    result = choose(SDL_COLORSPACE_HDR10, wrong, 2);
    assert(result.format == argb.format && result.colorSpace == argb.colorSpace);
    result = choose(SDL_COLORSPACE_SRGB, portal, 2);
    assert(result.format == sdr.format && result.colorSpace == sdr.colorSpace);
    VkSurfaceFormatKHR floating[] = {sdr, argb, linear};
    result = choose(SDL_COLORSPACE_SRGB_LINEAR, floating, 3);
    assert(result.format == linear.format && result.colorSpace == linear.colorSpace);
    assert(VULKAN_VkFormatToSDLPixelFormat(argb.format) == SDL_PIXELFORMAT_ARGB2101010);
    assert(VULKAN_VkFormatToSDLPixelFormat(abgr.format) == SDL_PIXELFORMAT_ABGR2101010);
}
"""
metadata = r"""
#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
typedef int Display;
typedef struct { float SDR_white_level, HDR_headroom; } SDL_HDROutputProperties;
#define SCRGB_NITS 80.0f
#define SDL_memcmp memcmp
#define SDL_free free
#define SDL_Log(...) ((void)0)
#define SDL_LogWarn(...) ((void)0)
static const char board[] = "qcom,sm8550\0ayn,odin2portal";
static const char *identity = board;
static size_t identity_size = sizeof(board);
static bool connected = true, external = false, supported = true, active = true;
static const char *missing;
static float white = 202.64f;
static int opened, closed;
static void *SDL_LoadFile(const char *path, size_t *size)
{
    assert(!strcmp(path, "/proc/device-tree/compatible"));
    *size = identity_size;
    if (!identity) return NULL;
    void *data = malloc(*size);
    memcpy(data, identity, *size);
    return data;
}
static Display *X11_XOpenDisplay(const char *name)
{
    assert(!strcmp(name, ":0"));
    if (!connected) return NULL;
    opened++;
    return &opened;
}
static void X11_XCloseDisplay(Display *display) { assert(display); closed++; }
static bool GetRootWindowBoolProperty(Display *display, int screen, const char *name, bool *out)
{
    assert(display && screen == 0);
    if (missing && !strcmp(missing, name)) return false;
    if (!strcmp(name, "GAMESCOPE_DISPLAY_IS_EXTERNAL")) *out = external;
    else if (!strcmp(name, "GAMESCOPE_DISPLAY_SUPPORTS_HDR")) *out = supported;
    else { assert(!strcmp(name, "GAMESCOPE_HDR_OUTPUT_FEEDBACK")); *out = active; }
    return true;
}
static bool GetRootWindowFloatProperty(Display *display, int screen, const char *name, float *out)
{
    assert(display && screen == 0 && !strcmp(name, "GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS"));
    if (missing && !strcmp(missing, name)) return false;
    *out = white;
    return true;
}
#include "portal_hdr.h"
static void unchanged(void)
{
    SDL_HDROutputProperties hdr = {2.0f, 3.0f};
    STEAMOS_GetPortalHDR(&hdr);
    assert(hdr.SDR_white_level == 2.0f && hdr.HDR_headroom == 3.0f);
    assert(opened == closed);
}
int main(void)
{
    SDL_HDROutputProperties hdr = {1.0f, 1.0f};
    STEAMOS_GetPortalHDR(&hdr);
    assert(fabsf(hdr.SDR_white_level - white / SCRGB_NITS) < 0.0001f);
    assert(fabsf(hdr.HDR_headroom - STEAMOS_PORTAL_PEAK_NITS / white) < 0.0001f);
    assert(hdr.HDR_headroom > 1.0f && opened == closed);
    external = true; unchanged(); external = false;
    supported = false; unchanged(); supported = true;
    active = false; unchanged(); active = true;
    connected = false; unchanged(); connected = true;
    const char *properties[] = {"GAMESCOPE_DISPLAY_IS_EXTERNAL", "GAMESCOPE_DISPLAY_SUPPORTS_HDR",
        "GAMESCOPE_HDR_OUTPUT_FEEDBACK", "GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS"};
    for (unsigned i = 0; i < 4; i++) { missing = properties[i]; unchanged(); }
    missing = NULL;
    float invalid[] = {0, -1, NAN, INFINITY, STEAMOS_PORTAL_PEAK_NITS, STEAMOS_PORTAL_PEAK_NITS + 1};
    for (unsigned i = 0; i < 6; i++) { white = invalid[i]; unchanged(); }
    white = 202.64f;
    identity = NULL; unchanged();
    identity = "ayn,odin2"; identity_size = strlen(identity) + 1; unchanged();
    identity = "ayn,odin2portal-extra"; identity_size = strlen(identity) + 1; unchanged();
    identity = "ayn,odin2portal"; identity_size = strlen(identity); unchanged();
}
"""
with tempfile.TemporaryDirectory(prefix="sdl-hdr-") as directory:
    work = Path(directory)
    for name, code in (
        ("formats", formats.replace("MAPPING", mapping).replace("SELECTION", selection)),
        ("metadata", metadata),
    ):
        path = work / (name + ".c")
        path.write_text(code)
        binary = work / name
        subprocess.run([
            "cc", "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-Wno-sign-compare",
            f"-DSTEAMOS_PORTAL_PEAK_NITS={peak}f",
            "-I" + str(sdl / "include"), "-I" + str(sdl / "src/video/khronos"),
            "-I" + str(root / "external-and-mods/streaming-hdr"),
            str(path), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)
print("SDL HDR format selection and Portal display metadata checks passed")
