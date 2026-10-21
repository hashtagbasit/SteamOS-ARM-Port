#define _GNU_SOURCE
#include <assert.h>
#include <sys/mman.h>

#include "../gbm-nv12/gbm_nv12.c"

struct gbm_bo {
	uint32_t width, height;
};

static struct gbm_bo *allocate(struct gbm_device *dev, uint32_t w, uint32_t h,
			       uint32_t format, uint32_t flags)
{
	(void)dev;
	assert(format == FMT_R8 && (flags & USE_LINEAR));
	struct gbm_bo *bo = malloc(sizeof(*bo));
	assert(bo);
	*bo = (struct gbm_bo){w, h};
	return bo;
}

static uint32_t stride(struct gbm_bo *bo)
{
	return bo->width;
}

static void destroy(struct gbm_bo *bo)
{
	free(bo);
}

static int device_fd(struct gbm_device *dev)
{
	(void)dev;
	return -1;
}

int main(void)
{
	real_gbm_bo_create = allocate;
	real_gbm_bo_get_stride = stride;
	real_gbm_bo_destroy = destroy;
	real_gbm_device_get_fd = device_fd;
	const uint32_t formats[] = {FMT_NV12, FMT_P010};
	for (unsigned i = 0; i < 2; i++) {
		uint32_t format = formats[i], pitch, uv, size;
		assert(!video_layout(format, 641, 361, &pitch, &uv, &size));
		assert(gbm_device_is_format_supported(NULL, format, 0));
		for (unsigned method = 0; method < 3; method++) {
			uint64_t modifier = MOD_LINEAR;
			struct gbm_bo *bo = method == 0 ? gbm_bo_create(NULL, 641, 361, format, 0) :
				method == 1 ? gbm_bo_create_with_modifiers(NULL, 641, 361, format, &modifier, 1) :
				gbm_bo_create_with_modifiers2(NULL, 641, 361, format, &modifier, 1, 0);
			assert(bo && gbm_bo_get_format(bo) == format);
			assert(gbm_bo_get_width(bo) == 641 && gbm_bo_get_height(bo) == 361);
			assert(gbm_bo_get_plane_count(bo) == 2 && gbm_bo_get_modifier(bo) == MOD_LINEAR);
			assert(gbm_bo_get_stride_for_plane(bo, 0) == pitch);
			assert(gbm_bo_get_stride_for_plane(bo, 1) == pitch);
			assert(gbm_bo_get_offset(bo, 1) == uv);
			assert((uint64_t)find(bo)->real->width * find(bo)->real->height >= size);
			gbm_bo_destroy(bo);
		}
		uint64_t modifier = 7;
		assert(!gbm_bo_create_with_modifiers(NULL, 641, 361, format, &modifier, 1));
		int fd = memfd_create("p010-gbm-test", MFD_CLOEXEC);
		assert(fd >= 0);
		struct gbm_import_fd_modifier_data desc = {
			.width = 641, .height = 361, .format = format, .num_fds = 1,
			.fds = {fd}, .strides = {(int)pitch, (int)pitch},
			.offsets = {0, (int)uv}, .modifier = MOD_LINEAR,
		};
		struct gbm_bo *bo = gbm_bo_import(NULL, IMPORT_FD_MODIFIER, &desc, 0);
		assert(bo && gbm_bo_get_format(bo) == format && gbm_bo_get_offset(bo, 1) == uv);
		int exported = gbm_bo_get_fd(bo);
		assert(exported >= 0 && exported != fd);
		close(exported);
		gbm_bo_destroy(bo);
		desc.strides[0] = desc.strides[1] = 1;
		assert(!gbm_bo_import(NULL, IMPORT_FD_MODIFIER, &desc, 0));
		desc.strides[0] = desc.strides[1] = pitch;
		desc.fds[0] = -1;
		assert(!gbm_bo_import(NULL, IMPORT_FD_MODIFIER, &desc, 0));
		close(fd);
	}
	assert(!bos);
	puts("NV12/P010 GBM allocation, import and format tests passed");
	return 0;
}
