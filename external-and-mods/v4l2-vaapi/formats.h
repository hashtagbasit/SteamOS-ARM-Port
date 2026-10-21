#pragma once

#include <stdint.h>

#define VIDEO_NV12 0x3231564eU
#define VIDEO_P010 0x30313050U

static inline unsigned video_sample_bytes(uint32_t format)
{
	return format == VIDEO_NV12 ? 1 : format == VIDEO_P010 ? 2 : 0;
}

/* Iris linear surfaces: 128 pixels per stride, 32/16 rows per plane. */
static inline int video_layout(uint32_t format, uint32_t w, uint32_t h,
			       uint32_t *pitch, uint32_t *uv, uint32_t *size)
{
	unsigned bytes = video_sample_bytes(format);
	if (!bytes || !w || !h || w > 8192 || h > 8192)
		return -1;
	*pitch = ((w + 127) & ~127U) * bytes;
	*uv = *pitch * ((h + 31) & ~31U);
	*size = (*uv + *pitch * (((h + 1) / 2 + 15) & ~15U) + 4095) & ~4095U;
	return 0;
}
