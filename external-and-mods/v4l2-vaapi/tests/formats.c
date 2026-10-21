#define _GNU_SOURCE
#include <assert.h>

#include "../src/driver.c"

static void test_config(VADriverContextP ctx)
{
	struct drv *d = DRV(ctx);
	VAConfigAttrib a = {.type = VAConfigAttribRTFormat};
	assert(GetConfigAttributes(ctx, VAProfileAV1Profile0, VAEntrypointVLD, &a, 1) == VA_STATUS_SUCCESS);
	assert(a.value == (VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10));
	assert(GetConfigAttributes(ctx, VAProfileH264High, VAEntrypointVLD, &a, 1) == VA_STATUS_SUCCESS);
	assert(a.value == VA_RT_FORMAT_YUV420);
	VAConfigID id;
	a.value = VA_RT_FORMAT_YUV420_10;
	assert(CreateConfig(ctx, VAProfileH264High, VAEntrypointVLD, &a, 1, &id) ==
	       VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT);
	d->p010 = 0;
	assert(CreateConfig(ctx, VAProfileAV1Profile0, VAEntrypointVLD, &a, 1, &id) ==
	       VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT);
	d->p010 = 1;
	assert(CreateConfig(ctx, VAProfileAV1Profile0, VAEntrypointVLD, &a, 1, &id) == VA_STATUS_SUCCESS);
	VAProfile profile;
	VAEntrypoint entry;
	int count;
	assert(QueryConfigAttributes(ctx, id, &profile, &entry, &a, &count) == VA_STATUS_SUCCESS);
	assert(count == 1 && a.value == VA_RT_FORMAT_YUV420_10);
	unsigned n = 0;
	assert(QuerySurfaceAttributes(ctx, id, NULL, &n) == VA_STATUS_SUCCESS && n == 7);
	VASurfaceAttrib attrs[8];
	assert(QuerySurfaceAttributes(ctx, id, attrs, &n) == VA_STATUS_SUCCESS);
	assert(attrs[0].value.value.i == VA_FOURCC_P010);
	assert(DestroyConfig(ctx, id) == VA_STATUS_SUCCESS);
	assert(CreateConfig(ctx, VAProfileAV1Profile0, VAEntrypointVLD, NULL, 0, &id) == VA_STATUS_SUCCESS);
	n = 8;
	assert(QuerySurfaceAttributes(ctx, id, attrs, &n) == VA_STATUS_SUCCESS && n == 8);
	assert(attrs[0].value.value.i == VA_FOURCC_NV12 && attrs[1].value.value.i == VA_FOURCC_P010);
	assert(DestroyConfig(ctx, id) == VA_STATUS_SUCCESS);
}

static void test_surface(VADriverContextP ctx, uint32_t format)
{
	struct drv *d = DRV(ctx);
	unsigned bytes = video_sample_bytes(format);
	uint32_t pitch, uv, size;
	assert(!video_layout(format, 641, 361, &pitch, &uv, &size));
	assert(pitch == 768 * bytes && uv == pitch * 384 && !(size & 4095));
	int fd = memfd_create("p010-surface-test", MFD_CLOEXEC);
	assert(fd >= 0 && !ftruncate(fd, size));
	VADRMPRIMESurfaceDescriptor descriptor = {
		.fourcc = format, .width = 641, .height = 361, .num_objects = 1, .num_layers = 1,
		.objects = {{.fd = fd, .size = size, .drm_format_modifier = DRM_FORMAT_MOD_LINEAR}},
		.layers = {{.drm_format = format, .num_planes = 2,
			    .offset = {0, uv}, .pitch = {pitch, pitch}}},
	};
	VASurfaceAttrib attrs[] = {
		{.type = VASurfaceAttribPixelFormat,
		 .value = {.type = VAGenericValueTypeInteger, .value.i = format}},
		{.type = VASurfaceAttribMemoryType,
		 .value = {.type = VAGenericValueTypeInteger, .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2}},
		{.type = VASurfaceAttribExternalBufferDescriptor,
		 .value = {.type = VAGenericValueTypePointer, .value.p = &descriptor}},
	};
	VASurfaceID sid;
	uint32_t rt = surface_rt_format(format);
	assert(CreateSurfaces2(ctx, rt, 641, 361, &sid, 1, attrs, 3) == VA_STATUS_SUCCESS);
	struct surface *s = obj_get(d, O_SURFACE, sid);
	assert(s && s->fourcc == format && s->pitch == pitch);
	assert(!surf_map(s));
	for (unsigned i = 0; i < size; i++)
		((uint8_t *)s->map)[i] = (uint8_t)(i * 37 + i / 256);

	VAImage derived, copy;
	assert(DeriveImage(ctx, sid, &derived) == VA_STATUS_SUCCESS);
	assert(derived.format.fourcc == format && derived.format.bits_per_pixel == 12 * bytes);
	assert(derived.pitches[0] == pitch && derived.offsets[1] == uv);
	assert(DestroyImage(ctx, derived.image_id) == VA_STATUS_SUCCESS);
	VAImageFormat fmt = {.fourcc = format, .byte_order = VA_LSB_FIRST, .bits_per_pixel = 12 * bytes};
	assert(CreateImage(ctx, &fmt, 639, 359, &copy) == VA_STATUS_SUCCESS);
	assert(GetImage(ctx, sid, -1, 0, 639, 359, copy.image_id) == VA_STATUS_ERROR_INVALID_PARAMETER);
	assert(GetImage(ctx, sid, 0, 0, UINT32_MAX, 359, copy.image_id) == VA_STATUS_ERROR_INVALID_PARAMETER);
	assert(GetImage(ctx, sid, 2, 2, 639, 359, copy.image_id) == VA_STATUS_SUCCESS);
	struct buffer *b = obj_get(d, O_BUFFER, copy.buf);
	for (unsigned plane = 0; plane < 2; plane++) {
		unsigned rows = plane ? 180 : 359;
		unsigned width = (plane ? 640 : 639) * bytes;
		unsigned source_y = plane ? 1 : 2;
		unsigned source_offset = plane ? uv : 0;
		for (unsigned y = 0; y < rows; y++)
			assert(!memcmp(b->data + copy.offsets[plane] + y * copy.pitches[plane],
				       (uint8_t *)s->map + source_offset + (source_y + y) * pitch + 2 * bytes,
				       width));
	}
	assert(DestroyImage(ctx, copy.image_id) == VA_STATUS_SUCCESS);
	fmt.fourcc = format == VA_FOURCC_P010 ? VA_FOURCC_NV12 : VA_FOURCC_P010;
	fmt.bits_per_pixel = 12 * video_sample_bytes(fmt.fourcc);
	assert(CreateImage(ctx, &fmt, 641, 361, &copy) == VA_STATUS_SUCCESS);
	assert(GetImage(ctx, sid, 0, 0, 641, 361, copy.image_id) == VA_STATUS_ERROR_INVALID_IMAGE_FORMAT);
	assert(DestroyImage(ctx, copy.image_id) == VA_STATUS_SUCCESS);

	VADRMPRIMESurfaceDescriptor exported;
	assert(ExportSurfaceHandle(ctx, sid, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
				   VA_EXPORT_SURFACE_SEPARATE_LAYERS, &exported) == VA_STATUS_SUCCESS);
	assert(exported.fourcc == format && exported.num_layers == 2);
	assert(exported.layers[0].drm_format == (bytes == 2 ? DRM_FORMAT_R16 : DRM_FORMAT_R8));
	assert(exported.layers[1].drm_format == (bytes == 2 ? DRM_FORMAT_GR1616 : DRM_FORMAT_GR88));
	assert(exported.layers[1].offset[0] == uv && exported.layers[1].pitch[0] == pitch);
	close(exported.objects[0].fd);
	assert(ExportSurfaceHandle(ctx, sid, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
				   VA_EXPORT_SURFACE_COMPOSED_LAYERS, &exported) == VA_STATUS_SUCCESS);
	assert(exported.num_layers == 1 && exported.layers[0].drm_format == format);
	close(exported.objects[0].fd);
	assert(DestroySurfaces(ctx, &sid, 1) == VA_STATUS_SUCCESS);

	descriptor.objects[0].size = uv;
	assert(CreateSurfaces2(ctx, rt, 641, 361, &sid, 1, attrs, 3) == VA_STATUS_ERROR_INVALID_PARAMETER);
	descriptor.objects[0].size = size;
	descriptor.objects[0].drm_format_modifier = 1;
	assert(CreateSurfaces2(ctx, rt, 641, 361, &sid, 1, attrs, 3) == VA_STATUS_ERROR_INVALID_PARAMETER);
	close(fd);
}

int main(void)
{
	struct drv d = {.av1 = 1, .p010 = 1, .render_fd = -1};
	pthread_mutex_init(&d.lock, NULL);
	struct VADriverContext ctx = {.pDriverData = &d};
	uint32_t pitch, uv, size;
	assert(!video_layout(VIDEO_NV12, 1920, 1080, &pitch, &uv, &size));
	assert(pitch == 1920 && uv == 2088960 && size == 3133440);
	assert(!video_layout(VIDEO_P010, 1920, 1080, &pitch, &uv, &size));
	assert(pitch == 3840 && uv == 4177920 && size == 6266880);
	assert(video_layout(0, 1920, 1080, &pitch, &uv, &size) == -1);
	assert(video_layout(VIDEO_P010, UINT32_MAX, 1080, &pitch, &uv, &size) == -1);
	assert(video_layout(VIDEO_P010, 1920, 0, &pitch, &uv, &size) == -1);
	test_config(&ctx);
	test_surface(&ctx, VA_FOURCC_NV12);
	test_surface(&ctx, VA_FOURCC_P010);
	VAImageFormat images[2];
	int count;
	assert(QueryImageFormats(&ctx, images, &count) == VA_STATUS_SUCCESS && count == 2);
	assert(images[1].fourcc == VA_FOURCC_P010 && images[1].bits_per_pixel == 24);
	d.p010 = 0;
	assert(QueryImageFormats(&ctx, images, &count) == VA_STATUS_SUCCESS && count == 1);
	for (int i = 0; i < O_MAX; i++)
		free(d.tab[i].items);
	pthread_mutex_destroy(&d.lock);
	puts("NV12/P010 configuration, surface, image and export tests passed");
	return 0;
}
