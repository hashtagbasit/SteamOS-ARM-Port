/*
 * libgbm-nv12: linear NV12 and P010 buffers for GBM clients on Adreno.
 *
 * Mesa's freedreno GBM can't create NV12 (gbm_device_is_format_supported
 * says no and every create fails), but Chromium's VA-API decoder allocates
 * its video frames as NV12 through GBM and gives up when it can't. This
 * preload library answers NV12 requests itself: one linear R8 buffer from
 * the real GBM, tall enough for both planes, laid out the way the Snapdragon
 * video cores write NV12 (pitch a multiple of 128, chroma at pitch times
 * the height rounded up to 32). The decoder can then write into those
 * frames directly and the GPU samples them as an NV12 dma-buf.
 * P010 uses the same layout with two bytes per sample and a 256-byte stride
 * alignment. Every other format goes to the real libgbm untouched.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "../formats.h"

#define EXPORT __attribute__((visibility("default")))
#define ALIGN(x, a) (((x) + (a) - 1) & ~((a) - 1))
#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define FMT_NV12 FOURCC('N', 'V', '1', '2')
#define FMT_P010 FOURCC('P', '0', '1', '0')
#define FMT_R8 FOURCC('R', '8', ' ', ' ')
#define MOD_LINEAR 0ULL
#define MOD_INVALID 0x00ffffffffffffffULL
#define USE_LINEAR (1 << 4)
#define IMPORT_FD_MODIFIER 0x5504

struct gbm_device;
struct gbm_bo;
union gbm_bo_handle {
	void *ptr;
	int32_t s32;
	uint32_t u32;
	int64_t s64;
	uint64_t u64;
};
struct gbm_import_fd_modifier_data {
	uint32_t width, height, format, num_fds;
	int fds[4];
	int strides[4];
	int offsets[4];
	uint64_t modifier;
};

struct nv12 {
	struct nv12 *next;
	struct gbm_device *dev;
	struct gbm_bo *real;         /* R8 backing buffer, or NULL when imported */
	int fd;                      /* imported dma-buf */
	uint32_t handle;             /* GEM handle of an import */
	uint32_t width, height, pitch, uv_offset, format;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

#include <stdio.h>
#include <stdarg.h>
static void dbg(const char *fmt, ...)
{
	static int on = -1;
	if (on < 0) {
		const char *e = getenv("GBM_NV12_DEBUG");
		on = e && *e && *e != '0';
	}
	if (!on)
		return;
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "gbm-nv12: ");
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}
static struct nv12 *bos;

/*
 * The real libgbm. Installed as libgbm.so.1 ahead of Mesa's, this library
 * depends on Mesa's under the alias libgbm-mesa.so.1 (a symlink next to
 * it), so every symbol not defined here still resolves to Mesa. Used as an
 * LD_PRELOAD instead, the same handle lookup finds Mesa's libgbm.so.1.
 */
static void *real_lib(void)
{
	static void *h;
	if (!h)
		h = dlopen("libgbm-mesa.so.1", RTLD_NOW | RTLD_NOLOAD);
	if (!h)
		h = dlopen("libgbm-mesa.so.1", RTLD_NOW);
	if (!h)
		h = dlopen("libgbm.so.1", RTLD_NOW | RTLD_NOLOAD);
	return h;
}

#define REAL(ret, name, ...)                                                   \
	static ret (*real_##name)(__VA_ARGS__);                                \
	static void load_##name(void)                                          \
	{                                                                      \
		if (!real_##name && real_lib())                                \
			real_##name = (ret(*)(__VA_ARGS__))dlsym(real_lib(), #name); \
	}

REAL(int, gbm_device_is_format_supported, struct gbm_device *, uint32_t, uint32_t)
REAL(struct gbm_bo *, gbm_bo_create, struct gbm_device *, uint32_t, uint32_t, uint32_t, uint32_t)
REAL(struct gbm_bo *, gbm_bo_create_with_modifiers, struct gbm_device *, uint32_t, uint32_t,
     uint32_t, const uint64_t *, const unsigned int)
REAL(struct gbm_bo *, gbm_bo_create_with_modifiers2, struct gbm_device *, uint32_t, uint32_t,
     uint32_t, const uint64_t *, const unsigned int, uint32_t)
REAL(struct gbm_bo *, gbm_bo_import, struct gbm_device *, uint32_t, void *, uint32_t)
REAL(void, gbm_bo_destroy, struct gbm_bo *)
REAL(uint32_t, gbm_bo_get_width, struct gbm_bo *)
REAL(uint32_t, gbm_bo_get_height, struct gbm_bo *)
REAL(uint32_t, gbm_bo_get_stride, struct gbm_bo *)
REAL(uint32_t, gbm_bo_get_stride_for_plane, struct gbm_bo *, int)
REAL(uint32_t, gbm_bo_get_format, struct gbm_bo *)
REAL(uint32_t, gbm_bo_get_offset, struct gbm_bo *, int)
REAL(uint64_t, gbm_bo_get_modifier, struct gbm_bo *)
REAL(int, gbm_bo_get_plane_count, struct gbm_bo *)
REAL(int, gbm_bo_get_fd, struct gbm_bo *)
REAL(int, gbm_bo_get_fd_for_plane, struct gbm_bo *, int)
REAL(union gbm_bo_handle, gbm_bo_get_handle, struct gbm_bo *)
REAL(union gbm_bo_handle, gbm_bo_get_handle_for_plane, struct gbm_bo *, int)
REAL(struct gbm_device *, gbm_bo_get_device, struct gbm_bo *)
REAL(void *, gbm_bo_map, struct gbm_bo *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
     uint32_t *, void **)
REAL(void, gbm_bo_unmap, struct gbm_bo *, void *)
REAL(int, gbm_device_get_fd, struct gbm_device *)

static struct nv12 *find(struct gbm_bo *bo)
{
	pthread_mutex_lock(&lock);
	struct nv12 *n = bos;
	while (n && (struct gbm_bo *)n != bo)
		n = n->next;
	pthread_mutex_unlock(&lock);
	return n;
}

static void add(struct nv12 *n)
{
	pthread_mutex_lock(&lock);
	n->next = bos;
	bos = n;
	pthread_mutex_unlock(&lock);
}

static void del(struct nv12 *n)
{
	pthread_mutex_lock(&lock);
	for (struct nv12 **p = &bos; *p; p = &(*p)->next)
		if (*p == n) {
			*p = n->next;
			break;
		}
	pthread_mutex_unlock(&lock);
}

static int linear_ok(const uint64_t *mods, unsigned count)
{
	if (!count)
		return 1;
	for (unsigned i = 0; i < count; i++)
		if (mods[i] == MOD_LINEAR || mods[i] == MOD_INVALID)
			return 1;
	return 0;
}

static struct gbm_bo *video_create(struct gbm_device *dev, uint32_t w, uint32_t h,
				   uint32_t format, uint32_t flags)
{
	load_gbm_bo_create();
	load_gbm_bo_get_stride();
	if (!real_gbm_bo_create || !w || !h)
		return NULL;
	uint32_t pitch_want, uv, size;
	if (video_layout(format, w, h, &pitch_want, &uv, &size)) {
		errno = EINVAL;
		return NULL;
	}
	uint32_t rows = (size + pitch_want - 1) / pitch_want;

	struct nv12 *n = calloc(1, sizeof(*n));
	if (!n)
		return NULL;
	/* Only the flags Mesa knows (scanout, cursor, rendering, write, linear). */
	n->real = real_gbm_bo_create(dev, pitch_want, rows, FMT_R8, (flags & 0x1f) | USE_LINEAR);
	dbg("format %#x %ux%u flags %#x -> R8 %ux%u %s", format, w, h, flags, pitch_want, rows,
	    n->real ? "ok" : "FAILED");
	if (!n->real) {
		free(n);
		return NULL;
	}
	n->dev = dev;
	n->fd = -1;
	n->width = w;
	n->height = h;
	n->format = format;
	n->pitch = real_gbm_bo_get_stride(n->real);
	n->uv_offset = n->pitch * (uv / pitch_want);
	add(n);
	return (struct gbm_bo *)n;
}

EXPORT int gbm_device_is_format_supported(struct gbm_device *dev, uint32_t format, uint32_t usage)
{
	if (video_sample_bytes(format)) {
		dbg("format %#x supported (usage %#x): yes", format, usage);
		return 1;
	}
	load_gbm_device_is_format_supported();
	return real_gbm_device_is_format_supported ?
		real_gbm_device_is_format_supported(dev, format, usage) : 0;
}

EXPORT struct gbm_bo *gbm_bo_create(struct gbm_device *dev, uint32_t w, uint32_t h,
				    uint32_t format, uint32_t flags)
{
	if (video_sample_bytes(format))
		return video_create(dev, w, h, format, flags);
	load_gbm_bo_create();
	return real_gbm_bo_create(dev, w, h, format, flags);
}

EXPORT struct gbm_bo *gbm_bo_create_with_modifiers(struct gbm_device *dev, uint32_t w, uint32_t h,
						   uint32_t format, const uint64_t *mods,
						   const unsigned int count)
{
	if (video_sample_bytes(format)) {
		dbg("format %#x with %u modifiers (first %#llx)%s", format, count,
		    count ? (unsigned long long)mods[0] : 0ULL, linear_ok(mods, count) ? "" : " - no linear");
		return linear_ok(mods, count) ? video_create(dev, w, h, format, 0) : NULL;
	}
	load_gbm_bo_create_with_modifiers();
	return real_gbm_bo_create_with_modifiers(dev, w, h, format, mods, count);
}

EXPORT struct gbm_bo *gbm_bo_create_with_modifiers2(struct gbm_device *dev, uint32_t w, uint32_t h,
						    uint32_t format, const uint64_t *mods,
						    const unsigned int count, uint32_t flags)
{
	if (video_sample_bytes(format)) {
		dbg("format %#x with %u modifiers2 flags %#x", format, count, flags);
		return linear_ok(mods, count) ? video_create(dev, w, h, format, flags) : NULL;
	}
	load_gbm_bo_create_with_modifiers2();
	return real_gbm_bo_create_with_modifiers2(dev, w, h, format, mods, count, flags);
}

struct prime_handle { uint32_t handle, flags; int32_t fd; };
#define PRIME_FD_TO_HANDLE _IOWR('d', 0x2e, struct prime_handle)

EXPORT struct gbm_bo *gbm_bo_import(struct gbm_device *dev, uint32_t type, void *buffer,
				    uint32_t usage)
{
	if (type == IMPORT_FD_MODIFIER) {
		struct gbm_import_fd_modifier_data *d = buffer;
		if (video_sample_bytes(d->format)) {
			dbg("import format %#x %ux%u fds %u stride %d/%d off %d/%d mod %#llx", d->format, d->width, d->height,
			    d->num_fds, d->strides[0], d->strides[1], d->offsets[0], d->offsets[1],
			    (unsigned long long)d->modifier);
			unsigned bytes = video_sample_bytes(d->format);
			if ((d->modifier != MOD_LINEAR && d->modifier != MOD_INVALID) ||
			    !d->width || !d->height || d->width > 8192 || d->height > 8192 ||
			    d->num_fds < 1 || d->num_fds > 2 ||
			    d->strides[0] < (int)(ALIGN(d->width, 2) * bytes) ||
			    d->strides[0] != d->strides[1] || d->offsets[0] ||
			    d->offsets[1] < 0 ||
			    (uint64_t)d->offsets[1] < (uint64_t)d->strides[0] * d->height ||
			    (d->num_fds > 1 && d->fds[1] != d->fds[0] && d->fds[1] >= 0)) {
				errno = EINVAL;
				return NULL;
			}
			struct nv12 *n = calloc(1, sizeof(*n));
			if (!n)
				return NULL;
			n->dev = dev;
			n->fd = fcntl(d->fds[0], F_DUPFD_CLOEXEC, 0);
			if (n->fd < 0) {
				free(n);
				return NULL;
			}
			n->width = d->width;
			n->height = d->height;
			n->format = d->format;
			n->pitch = (uint32_t)d->strides[0];
			n->uv_offset = (uint32_t)d->offsets[1];
			load_gbm_device_get_fd();
			struct prime_handle ph = {.fd = n->fd};
			if (real_gbm_device_get_fd &&
			    !ioctl(real_gbm_device_get_fd(dev), PRIME_FD_TO_HANDLE, &ph))
				n->handle = ph.handle;
			add(n);
			return (struct gbm_bo *)n;
		}
	}
	load_gbm_bo_import();
	return real_gbm_bo_import(dev, type, buffer, usage);
}

EXPORT void gbm_bo_destroy(struct gbm_bo *bo)
{
	struct nv12 *n = find(bo);
	if (n) {
		del(n);
		if (n->real) {
			load_gbm_bo_destroy();
			real_gbm_bo_destroy(n->real);
		}
		if (n->fd >= 0)
			close(n->fd);
		free(n);
		return;
	}
	load_gbm_bo_destroy();
	real_gbm_bo_destroy(bo);
}

#define PASS(name, ...) do { load_##name(); return real_##name(__VA_ARGS__); } while (0)

EXPORT uint32_t gbm_bo_get_width(struct gbm_bo *bo)
{
	struct nv12 *n = find(bo);
	if (n)
		return n->width;
	PASS(gbm_bo_get_width, bo);
}

EXPORT uint32_t gbm_bo_get_height(struct gbm_bo *bo)
{
	struct nv12 *n = find(bo);
	if (n)
		return n->height;
	PASS(gbm_bo_get_height, bo);
}

EXPORT uint32_t gbm_bo_get_stride(struct gbm_bo *bo)
{
	struct nv12 *n = find(bo);
	if (n)
		return n->pitch;
	PASS(gbm_bo_get_stride, bo);
}

EXPORT uint32_t gbm_bo_get_stride_for_plane(struct gbm_bo *bo, int plane)
{
	struct nv12 *n = find(bo);
	if (n)
		return plane < 2 ? n->pitch : 0;
	PASS(gbm_bo_get_stride_for_plane, bo, plane);
}

EXPORT uint32_t gbm_bo_get_format(struct gbm_bo *bo)
{
	struct nv12 *n = find(bo);
	if (n)
		return n->format;
	PASS(gbm_bo_get_format, bo);
}

EXPORT uint32_t gbm_bo_get_offset(struct gbm_bo *bo, int plane)
{
	struct nv12 *n = find(bo);
	if (n)
		return plane == 1 ? n->uv_offset : 0;
	PASS(gbm_bo_get_offset, bo, plane);
}

EXPORT uint64_t gbm_bo_get_modifier(struct gbm_bo *bo)
{
	if (find(bo))
		return MOD_LINEAR;
	PASS(gbm_bo_get_modifier, bo);
}

EXPORT int gbm_bo_get_plane_count(struct gbm_bo *bo)
{
	if (find(bo))
		return 2;
	PASS(gbm_bo_get_plane_count, bo);
}

EXPORT int gbm_bo_get_fd(struct gbm_bo *bo)
{
	struct nv12 *n = find(bo);
	if (n) {
		if (n->real) {
			load_gbm_bo_get_fd();
			return real_gbm_bo_get_fd(n->real);
		}
		return fcntl(n->fd, F_DUPFD_CLOEXEC, 0);
	}
	PASS(gbm_bo_get_fd, bo);
}

EXPORT int gbm_bo_get_fd_for_plane(struct gbm_bo *bo, int plane)
{
	struct nv12 *n = find(bo);
	if (n)
		return plane < 2 ? gbm_bo_get_fd(bo) : -1;
	PASS(gbm_bo_get_fd_for_plane, bo, plane);
}

EXPORT union gbm_bo_handle gbm_bo_get_handle(struct gbm_bo *bo)
{
	struct nv12 *n = find(bo);
	if (n) {
		if (n->real) {
			load_gbm_bo_get_handle();
			return real_gbm_bo_get_handle(n->real);
		}
		union gbm_bo_handle h = {.u64 = 0};
		h.u32 = n->handle;
		return h;
	}
	PASS(gbm_bo_get_handle, bo);
}

EXPORT union gbm_bo_handle gbm_bo_get_handle_for_plane(struct gbm_bo *bo, int plane)
{
	struct nv12 *n = find(bo);
	if (n)
		return gbm_bo_get_handle(bo);
	PASS(gbm_bo_get_handle_for_plane, bo, plane);
}

EXPORT struct gbm_device *gbm_bo_get_device(struct gbm_bo *bo)
{
	struct nv12 *n = find(bo);
	if (n)
		return n->dev;
	PASS(gbm_bo_get_device, bo);
}

EXPORT void *gbm_bo_map(struct gbm_bo *bo, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
			uint32_t flags, uint32_t *stride, void **map_data)
{
	struct nv12 *n = find(bo);
	if (n) {
		/* The whole buffer, both planes: callers index by plane offset. */
		if (!n->real || x || y)
			return NULL;
		load_gbm_bo_map();
		load_gbm_bo_get_height();
		return real_gbm_bo_map(n->real, 0, 0, n->pitch, real_gbm_bo_get_height(n->real),
				       flags, stride, map_data);
	}
	PASS(gbm_bo_map, bo, x, y, w, h, flags, stride, map_data);
}

EXPORT void gbm_bo_unmap(struct gbm_bo *bo, void *map_data)
{
	struct nv12 *n = find(bo);
	if (n) {
		if (n->real) {
			load_gbm_bo_unmap();
			real_gbm_bo_unmap(n->real, map_data);
		}
		return;
	}
	PASS(gbm_bo_unmap, bo, map_data);
}
