#include "hdr_formats.hpp"

#include <cassert>

using namespace GamescopeWSILayer;

static VkResult countResult = VK_SUCCESS;
static VkResult fillResult = VK_SUCCESS;
static bool incomplete = false;
static unsigned queries = 0;

static VkResult VKAPI_CALL query(VkPhysicalDevice, VkSurfaceKHR,
                                uint32_t *count, VkSurfaceFormatKHR *formats) {
  ++queries;
  if (!formats) {
    *count = 1;
    return countResult;
  }
  assert(*count == 1);
  formats[0] = { VK_FORMAT_A2R10G10B10_UNORM_PACK32, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR };
  if (incomplete) {
    incomplete = false;
    return VK_INCOMPLETE;
  }
  return fillResult;
}

int main() {
  assert(supportedHDRFormats({}).empty());

  const std::array<VkSurfaceFormatKHR, 1> sdr = {{
    { VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
  }};
  assert(supportedHDRFormats(sdr).empty());

  const std::array<VkSurfaceFormatKHR, 3> portal = {{
    { VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    { VK_FORMAT_A2R10G10B10_UNORM_PACK32, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    { VK_FORMAT_A2R10G10B10_UNORM_PACK32, VK_COLOR_SPACE_HDR10_ST2084_EXT },
  }};
  const auto hdr = supportedHDRFormats(portal);
  assert(hdr.size() == 1);
  assert(hdr[0].format == VK_FORMAT_A2R10G10B10_UNORM_PACK32);
  assert(hdr[0].colorSpace == VK_COLOR_SPACE_HDR10_ST2084_EXT);

  const std::array<VkSurfaceFormatKHR, 3> all = {{
    { VK_FORMAT_A2B10G10R10_UNORM_PACK32, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    { VK_FORMAT_A2R10G10B10_UNORM_PACK32, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
    { VK_FORMAT_R16G16B16A16_SFLOAT, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
  }};
  const auto allHDR = supportedHDRFormats(all);
  assert(allHDR.size() == 3);
  assert(allHDR[0].format == all[0].format);
  assert(allHDR[1].format == all[1].format);
  assert(allHDR[2].format == all[2].format);
  assert(allHDR[2].colorSpace == VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT);

  std::vector<VkSurfaceFormatKHR> queried;
  incomplete = true;
  assert(queryHDRFormats(query, VK_NULL_HANDLE, VK_NULL_HANDLE, queried) == VK_SUCCESS);
  assert(queries == 4 && queried.size() == 1);
  assert(queried[0].format == VK_FORMAT_A2R10G10B10_UNORM_PACK32);

  countResult = VK_ERROR_SURFACE_LOST_KHR;
  assert(queryHDRFormats(query, VK_NULL_HANDLE, VK_NULL_HANDLE, queried) == countResult);
  countResult = VK_SUCCESS;
  fillResult = VK_ERROR_DEVICE_LOST;
  assert(queryHDRFormats(query, VK_NULL_HANDLE, VK_NULL_HANDLE, queried) == fillResult);
}
