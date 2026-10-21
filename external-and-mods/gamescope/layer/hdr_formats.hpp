#pragma once

#include <algorithm>
#include <array>
#include <span>
#include <vector>
#include <vulkan/vulkan.h>

namespace GamescopeWSILayer {

  inline std::vector<VkSurfaceFormatKHR> supportedHDRFormats(
    std::span<const VkSurfaceFormatKHR> nativeFormats) {
    static constexpr std::array<VkSurfaceFormatKHR, 3> hdrFormats = {{
      { VK_FORMAT_A2B10G10R10_UNORM_PACK32, VK_COLOR_SPACE_HDR10_ST2084_EXT },
      { VK_FORMAT_A2R10G10B10_UNORM_PACK32, VK_COLOR_SPACE_HDR10_ST2084_EXT },
      { VK_FORMAT_R16G16B16A16_SFLOAT, VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT },
    }};
    std::vector<VkSurfaceFormatKHR> result;
    for (const auto &hdr : hdrFormats) {
      // The layer forwards sRGB to the driver and sends HDR metadata separately.
      if (std::ranges::any_of(nativeFormats, [&](const auto &native) {
            return native.format == hdr.format;
          }))
        result.push_back(hdr);
    }
    return result;
  }

  inline VkResult queryHDRFormats(
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR query,
    VkPhysicalDevice device, VkSurfaceKHR surface,
    std::vector<VkSurfaceFormatKHR> &formats) {
    std::vector<VkSurfaceFormatKHR> nativeFormats;
    VkResult result;
    do {
      uint32_t count = 0;
      result = query(device, surface, &count, nullptr);
      if (result != VK_SUCCESS)
        return result;
      nativeFormats.resize(count);
      if (!count)
        break;
      result = query(device, surface, &count, nativeFormats.data());
      if (result != VK_SUCCESS && result != VK_INCOMPLETE)
        return result;
      nativeFormats.resize(count);
    } while (result == VK_INCOMPLETE);
    formats = supportedHDRFormats(nativeFormats);
    return VK_SUCCESS;
  }

}
