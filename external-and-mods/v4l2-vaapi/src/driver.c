/* VA-API entry points: objects, surfaces, pictures. See common.h. */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/dma-buf.h>
#include <linux/ioctl.h>

#include "common.h"

#ifndef DRM_FORMAT_MOD_LINEAR
#define DRM_FORMAT_MOD_LINEAR 0ULL
#endif
#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define DRM_FORMAT_NV12 FOURCC('N', 'V', '1', '2')
#define DRM_FORMAT_R8 FOURCC('R', '8', ' ', ' ')
#define DRM_FORMAT_GR88 FOURCC('G', 'R', '8', '8')
#define DRM_FORMAT_R16 FOURCC('R', '1', '6', ' ')
#define DRM_FORMAT_GR1616 FOURCC('G', 'R', '3', '2')

/* The few DRM ioctls we need, without pulling libdrm in. */
struct k_drm_version {
	int version_major, version_minor, version_patchlevel;
	size_t name_len;
	char *name;
	size_t date_len;
	char *date;
	size_t desc_len;
	char *desc;
};
struct k_drm_gem_close { uint32_t handle, pad; };
struct k_drm_prime_handle { uint32_t handle, flags; int32_t fd; };
struct k_drm_msm_gem_new { uint64_t size; uint32_t flags, handle; };
#define K_DRM_IOCTL_VERSION _IOWR('d', 0x00, struct k_drm_version)
#define K_DRM_IOCTL_GEM_CLOSE _IOW('d', 0x09, struct k_drm_gem_close)
#define K_DRM_IOCTL_PRIME_HANDLE_TO_FD _IOWR('d', 0x2d, struct k_drm_prime_handle)
#define K_DRM_IOCTL_PRIME_FD_TO_HANDLE _IOWR('d', 0x2e, struct k_drm_prime_handle)
#define K_DRM_IOCTL_MSM_GEM_NEW _IOWR('d', 0x40 + 0x02, struct k_drm_msm_gem_new)
#define K_MSM_BO_WC 0x00020000
#define K_DRM_RDWR 02

#define VENDOR "SteamOS ARM V4L2 stateful decoder"

static const VAProfile profiles[] = {
	VAProfileH264ConstrainedBaseline, VAProfileH264Main, VAProfileH264High,
};

void dbg(struct drv *d, const char *fmt, ...)
{
	if (!d->debug)
		return;
	va_list ap;
	FILE *f = d->log ? d->log : stderr;
	va_start(ap, fmt);
	fprintf(f, "msm_drv_video: ");
	vfprintf(f, fmt, ap);
	fputc('\n', f);
	fflush(f);
	va_end(ap);
}

/* ---------------- object tables ---------------- */

static uint32_t obj_add(struct drv *d, enum obj_type t, void *p)
{
	struct obj_table *tb = &d->tab[t];
	for (unsigned i = 0; i < tb->cap; i++)
		if (!tb->items[i]) {
			tb->items[i] = p;
			return ((uint32_t)t << 24) | (i + 1);
		}
	unsigned ncap = tb->cap ? tb->cap * 2 : 64;
	void **n = realloc(tb->items, ncap * sizeof(void *));
	if (!n)
		return VA_INVALID_ID;
	memset(n + tb->cap, 0, (ncap - tb->cap) * sizeof(void *));
	tb->items = n;
	unsigned i = tb->cap;
	tb->cap = ncap;
	tb->items[i] = p;
	return ((uint32_t)t << 24) | (i + 1);
}

void *obj_get(struct drv *d, enum obj_type t, uint32_t id)
{
	if (id == VA_INVALID_ID || (id >> 24) != (uint32_t)t)
		return NULL;
	uint32_t i = (id & 0xffffff) - 1;
	return i < d->tab[t].cap ? d->tab[t].items[i] : NULL;
}

static void obj_del(struct drv *d, enum obj_type t, uint32_t id)
{
	uint32_t i = (id & 0xffffff) - 1;
	if ((id >> 24) == (uint32_t)t && i < d->tab[t].cap)
		d->tab[t].items[i] = NULL;
}

#define DRV(ctx) ((struct drv *)(ctx)->pDriverData)
#define LOCK(d) pthread_mutex_lock(&(d)->lock)
#define UNLOCK(d) pthread_mutex_unlock(&(d)->lock)

/* ---------------- configs ---------------- */

static int profile_ok(struct drv *d, VAProfile p)
{
	if (p == VAProfileAV1Profile0)
		return d->av1;
	for (unsigned i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++)
		if (profiles[i] == p)
			return 1;
	return 0;
}

static VAStatus QueryConfigProfiles(VADriverContextP ctx, VAProfile *list, int *num)
{
	int n = 0;
	for (unsigned i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++)
		list[n++] = profiles[i];
	if (DRV(ctx)->av1)
		list[n++] = VAProfileAV1Profile0;
	*num = n;
	return VA_STATUS_SUCCESS;
}

static VAStatus QueryConfigEntrypoints(VADriverContextP ctx, VAProfile p,
				       VAEntrypoint *list, int *num)
{
	(void)ctx;
	if (!profile_ok(DRV(ctx), p))
		return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
	list[0] = VAEntrypointVLD;
	*num = 1;
	return VA_STATUS_SUCCESS;
}

static uint32_t rt_formats(struct drv *d, VAProfile p)
{
	return VA_RT_FORMAT_YUV420 |
		(p == VAProfileAV1Profile0 && d->p010 ? VA_RT_FORMAT_YUV420_10 : 0);
}

static uint32_t surface_rt_format(uint32_t fourcc)
{
	return fourcc == VA_FOURCC_NV12 ? VA_RT_FORMAT_YUV420 :
		fourcc == VA_FOURCC_P010 ? VA_RT_FORMAT_YUV420_10 : 0;
}

static void fill_attribs(struct drv *d, VAProfile p, VAConfigAttrib *a, int n)
{
	for (int i = 0; i < n; i++) {
		switch (a[i].type) {
		case VAConfigAttribRTFormat:
			a[i].value = rt_formats(d, p);
			break;
		case VAConfigAttribDecSliceMode:
			a[i].value = VA_DEC_SLICE_MODE_NORMAL;
			break;
		case VAConfigAttribMaxPictureWidth:
		case VAConfigAttribMaxPictureHeight:
			a[i].value = 8192;
			break;
		default:
			a[i].value = VA_ATTRIB_NOT_SUPPORTED;
		}
	}
}

static VAStatus GetConfigAttributes(VADriverContextP ctx, VAProfile p, VAEntrypoint e,
				    VAConfigAttrib *a, int n)
{
	(void)ctx;
	if (!profile_ok(DRV(ctx), p))
		return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
	if (e != VAEntrypointVLD)
		return VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT;
	fill_attribs(DRV(ctx), p, a, n);
	return VA_STATUS_SUCCESS;
}

static VAStatus CreateConfig(VADriverContextP ctx, VAProfile p, VAEntrypoint e,
			     VAConfigAttrib *a, int n, VAConfigID *id)
{
	struct drv *d = DRV(ctx);
	if (!profile_ok(DRV(ctx), p))
		return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
	if (e != VAEntrypointVLD)
		return VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT;
	uint32_t formats = rt_formats(d, p), requested = formats;
	for (int i = 0; i < n; i++)
		if (a[i].type == VAConfigAttribRTFormat) {
			if (!a[i].value || (a[i].value & ~formats))
				return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
			requested = a[i].value;
		}
	struct config *c = calloc(1, sizeof(*c));
	if (!c)
		return VA_STATUS_ERROR_ALLOCATION_FAILED;
	c->profile = p;
	c->entrypoint = e;
	c->rt_format = requested;
	LOCK(d);
	*id = obj_add(d, O_CONFIG, c);
	UNLOCK(d);
	return VA_STATUS_SUCCESS;
}

static VAStatus DestroyConfig(VADriverContextP ctx, VAConfigID id)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	struct config *c = obj_get(d, O_CONFIG, id);
	if (c) {
		obj_del(d, O_CONFIG, id);
		free(c);
	}
	UNLOCK(d);
	return c ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_CONFIG;
}

static VAStatus QueryConfigAttributes(VADriverContextP ctx, VAConfigID id, VAProfile *p,
				      VAEntrypoint *e, VAConfigAttrib *a, int *n)
{
	struct drv *d = DRV(ctx);
	struct config *c = obj_get(d, O_CONFIG, id);
	if (!c)
		return VA_STATUS_ERROR_INVALID_CONFIG;
	*p = c->profile;
	*e = c->entrypoint;
	a[0].type = VAConfigAttribRTFormat;
	a[0].value = c->rt_format;
	*n = 1;
	return VA_STATUS_SUCCESS;
}

/* ---------------- surfaces ---------------- */

static int alloc_dmabuf(struct drv *d, uint32_t size, uint32_t *gem)
{
	struct k_drm_msm_gem_new g = {.size = size, .flags = K_MSM_BO_WC};
	if (ioctl(d->render_fd, K_DRM_IOCTL_MSM_GEM_NEW, &g))
		return -1;
	struct k_drm_prime_handle ph = {.handle = g.handle, .flags = O_CLOEXEC | K_DRM_RDWR};
	if (ioctl(d->render_fd, K_DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph)) {
		struct k_drm_gem_close gc = {.handle = g.handle};
		ioctl(d->render_fd, K_DRM_IOCTL_GEM_CLOSE, &gc);
		return -1;
	}
	*gem = g.handle;            /* kept to wait for the GPU, see gpu_wait() */
	return ph.fd;
}

/* A handle on our render node for a client's dma-buf (0 if it isn't ours to have). */
static uint32_t import_gem(struct drv *d, int fd)
{
	struct k_drm_prime_handle ph = {.fd = fd};
	return ioctl(d->render_fd, K_DRM_IOCTL_PRIME_FD_TO_HANDLE, &ph) ? 0 : ph.handle;
}

struct k_drm_msm_timespec { int64_t tv_sec, tv_nsec; };
struct k_drm_msm_gem_cpu_prep { uint32_t handle, op; struct k_drm_msm_timespec timeout; };
#define K_DRM_IOCTL_MSM_GEM_CPU_PREP _IOW('d', 0x40 + 0x04, struct k_drm_msm_gem_cpu_prep)
#define K_MSM_PREP_READ 0x01
#define K_MSM_PREP_WRITE 0x02
#define K_MSM_PREP_BOOKKEEP 0x10

/*
 * Wait until the GPU has finished with a surface. With VM_BIND (Turnip) the
 * GPU's fences on shared buffers are bookkeeping-only and need the kernel's
 * MSM_PREP_BOOKKEEP (patch 0048). Returns 0 when waited, -1 when this kernel
 * can't, so the caller falls back to a time guard.
 */
int gpu_wait(struct drv *d, struct surface *s, int timeout_ms)
{
	if (d->gpu_wait == 0 || !s->gem)
		return -1;
	if (d->gpu_wait > 0) {
		/* How often the GPU is still on it, for the statistics. */
		struct k_drm_msm_gem_cpu_prep nb = {.handle = s->gem,
			.op = K_MSM_PREP_READ | K_MSM_PREP_WRITE | K_MSM_PREP_BOOKKEEP | 0x04};
		if (ioctl(d->render_fd, K_DRM_IOCTL_MSM_GEM_CPU_PREP, &nb) && errno == EBUSY)
			d->gpu_busy++;
		d->gpu_checks++;
	}
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	uint64_t t0 = (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
	int64_t ns = t.tv_nsec + (int64_t)timeout_ms * 1000000;
	struct k_drm_msm_gem_cpu_prep cp = {.handle = s->gem,
		.op = K_MSM_PREP_READ | K_MSM_PREP_WRITE | K_MSM_PREP_BOOKKEEP,
		.timeout = {.tv_sec = t.tv_sec + ns / 1000000000, .tv_nsec = ns % 1000000000}};
	int r = ioctl(d->render_fd, K_DRM_IOCTL_MSM_GEM_CPU_PREP, &cp);
	if (r && errno == EINVAL && d->gpu_wait < 0) {
		dbg(d, "kernel can't wait for GPU readers (no MSM_PREP_BOOKKEEP), using a time guard");
		d->gpu_wait = 0;
		return -1;
	}
	if (d->gpu_wait < 0) {
		d->gpu_wait = 1;
		dbg(d, "waiting for GPU readers with MSM_PREP_BOOKKEEP");
	}
	if (r && errno == ETIMEDOUT)
		dbg(d, "GPU still reading a surface after %d ms", timeout_ms);
	clock_gettime(CLOCK_MONOTONIC, &t);
	uint64_t w = (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec - t0;
	d->gpu_wait_ns += w;
	if (w > d->gpu_wait_max_ns)
		d->gpu_wait_max_ns = w;
	if (d->gpu_checks >= 600) {
		dbg(d, "GPU still reading at reuse: %llu of %llu, waited %.1f ms total, max %.1f ms",
		    (unsigned long long)d->gpu_busy, (unsigned long long)d->gpu_checks,
		    d->gpu_wait_ns / 1e6, d->gpu_wait_max_ns / 1e6);
		d->gpu_busy = d->gpu_checks = d->gpu_wait_ns = d->gpu_wait_max_ns = 0;
	}
	return 0;
}

static void surface_free(struct drv *d, struct surface *s)
{
	if (s->gem) {
		struct k_drm_gem_close gc = {.handle = s->gem};
		ioctl(d->render_fd, K_DRM_IOCTL_GEM_CLOSE, &gc);
	}
	if (s->map)
		munmap(s->map, s->size);
	if (s->fd >= 0)
		close(s->fd);
	if (s->ctx && s->slot >= 0 && s->slot < MAX_SLOTS && s->ctx->slot_owner[s->slot] == s)
		s->ctx->slot_owner[s->slot] = NULL;
	free(s);
}

static VAStatus CreateSurfaces2(VADriverContextP ctx, unsigned int format, unsigned int width,
				unsigned int height, VASurfaceID *out, unsigned int num,
				VASurfaceAttrib *attr, unsigned int nattr)
{
	struct drv *d = DRV(ctx);
	uint32_t mem = VA_SURFACE_ATTRIB_MEM_TYPE_VA;
	VADRMPRIMESurfaceDescriptor *prime2 = NULL;
	VASurfaceAttribExternalBuffers *ext = NULL;

	if (format != VA_RT_FORMAT_YUV420 &&
	    !(format == VA_RT_FORMAT_YUV420_10 && d->av1 && d->p010))
		return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
	uint32_t fourcc = format == VA_RT_FORMAT_YUV420_10 ? VA_FOURCC_P010 : VA_FOURCC_NV12;
	uint32_t pitch, uv, size;
	if (video_layout(fourcc, width, height, &pitch, &uv, &size))
		return VA_STATUS_ERROR_INVALID_PARAMETER;
	for (unsigned i = 0; i < nattr; i++) {
		if (attr[i].type == VASurfaceAttribPixelFormat && attr[i].value.value.i &&
		    (uint32_t)attr[i].value.value.i != fourcc)
			return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
		if (attr[i].type == VASurfaceAttribMemoryType)
			mem = (uint32_t)attr[i].value.value.i;
		if (attr[i].type == VASurfaceAttribExternalBufferDescriptor) {
			prime2 = attr[i].value.value.p;
			ext = attr[i].value.value.p;
		}
	}
	if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2)
		ext = NULL;
	else if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME)
		prime2 = NULL;
	else if (mem == VA_SURFACE_ATTRIB_MEM_TYPE_VA)
		prime2 = NULL, ext = NULL;
	else
		return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
	if ((mem != VA_SURFACE_ATTRIB_MEM_TYPE_VA) && !prime2 && !ext)
		return VA_STATUS_ERROR_INVALID_PARAMETER;

	for (unsigned n = 0; n < num; n++) {
		struct surface *s = calloc(1, sizeof(*s));
		if (!s)
			goto fail;
		s->fd = -1;
		s->slot = -1;
		s->width = width;
		s->height = height;
		s->fourcc = fourcc;
		if (prime2) {
			if (prime2->num_objects < 1 || prime2->fourcc != fourcc ||
			    prime2->objects[0].drm_format_modifier != DRM_FORMAT_MOD_LINEAR) {
				free(s);
				goto bad;
			}
			uint32_t yo = 0, uvo = 0, yp = 0, uvp = 0;
			if (prime2->num_layers == 1 && prime2->layers[0].num_planes == 2) {
				yo = prime2->layers[0].offset[0];
				uvo = prime2->layers[0].offset[1];
				yp = prime2->layers[0].pitch[0];
				uvp = prime2->layers[0].pitch[1];
			} else if (prime2->num_layers == 2) {
				yo = prime2->layers[0].offset[0];
				uvo = prime2->layers[1].offset[0];
				yp = prime2->layers[0].pitch[0];
				uvp = prime2->layers[1].pitch[0];
			}
			if (prime2->num_objects != 1 || yo || yp != uvp || !yp) {
				dbg(d, "import: unsupported layout (%u objects, y %u/%u uv %u/%u)",
				    prime2->num_objects, yo, yp, uvo, uvp);
				free(s);
				goto bad;
			}
			s->fd = dup(prime2->objects[0].fd);
			s->size = prime2->objects[0].size;
			s->pitch = yp;
			s->uv_offset = uvo;
			s->imported = 1;
			if (!s->size)
				s->size = (uint32_t)lseek(s->fd, 0, SEEK_END);
			s->gem = import_gem(d, s->fd);
		} else if (ext) {
			if (ext->pixel_format != fourcc || n >= ext->num_buffers || ext->num_planes != 2 ||
			    ext->pitches[0] != ext->pitches[1] || ext->offsets[0]) {
				free(s);
				goto bad;
			}
			s->fd = dup((int)ext->buffers[n]);
			s->size = ext->data_size ? ext->data_size : (uint32_t)lseek(s->fd, 0, SEEK_END);
			s->pitch = ext->pitches[0];
			s->uv_offset = ext->offsets[1];
			s->imported = 1;
			s->gem = import_gem(d, s->fd);
		} else {
			s->pitch = pitch;
			s->uv_offset = uv;
			s->size = size;
			s->fd = alloc_dmabuf(d, s->size, &s->gem);
		}
		if (s->fd < 0) {
			free(s);
			goto fail;
		}
		unsigned bytes = video_sample_bytes(fourcc);
		if (s->pitch < ALIGN(width, 2) * bytes ||
		    s->uv_offset < (uint64_t)s->pitch * height ||
		    (uint64_t)s->uv_offset + (uint64_t)s->pitch * ((height + 1) / 2) > s->size) {
			dbg(d, "import: buffer layout cannot hold %ux%u format %#x", width, height, fourcc);
			surface_free(d, s);
			goto bad;
		}
		LOCK(d);
		out[n] = obj_add(d, O_SURFACE, s);
		UNLOCK(d);
		if (n == 0)
			dbg(d, "surfaces %ux%u x%u %s pitch %u uv %u size %u", width, height, num,
			    s->imported ? "imported" : "allocated", s->pitch, s->uv_offset, s->size);
		continue;
bad:
		for (unsigned k = 0; k < n; k++) {
			LOCK(d);
			struct surface *o = obj_get(d, O_SURFACE, out[k]);
			obj_del(d, O_SURFACE, out[k]);
			UNLOCK(d);
			if (o)
				surface_free(d, o);
		}
		return VA_STATUS_ERROR_INVALID_PARAMETER;
fail:
		for (unsigned k = 0; k < n; k++) {
			LOCK(d);
			struct surface *o = obj_get(d, O_SURFACE, out[k]);
			obj_del(d, O_SURFACE, out[k]);
			UNLOCK(d);
			if (o)
				surface_free(d, o);
		}
		return VA_STATUS_ERROR_ALLOCATION_FAILED;
	}
	return VA_STATUS_SUCCESS;
}

static VAStatus CreateSurfaces(VADriverContextP ctx, int width, int height, int format,
			       int num, VASurfaceID *out)
{
	return CreateSurfaces2(ctx, (unsigned)format, (unsigned)width, (unsigned)height, out,
			       (unsigned)num, NULL, 0);
}

static VAStatus DestroySurfaces(VADriverContextP ctx, VASurfaceID *list, int num)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	for (int i = 0; i < num; i++) {
		struct surface *s = obj_get(d, O_SURFACE, list[i]);
		if (!s)
			continue;
		obj_del(d, O_SURFACE, list[i]);
		if (s->ctx)
			for (unsigned k = 0; k < MAX_INFLIGHT; k++)
				if (s->ctx->inflight[k] == s)
					s->ctx->inflight[k] = NULL;
		if (s->ctx && s->ctx->target == s)
			s->ctx->target = NULL;
		surface_free(d, s);
	}
	UNLOCK(d);
	return VA_STATUS_SUCCESS;
}

static VAStatus QuerySurfaceAttributes(VADriverContextP ctx, VAConfigID cfg,
				       VASurfaceAttrib *a, unsigned int *num)
{
	struct config *c = obj_get(DRV(ctx), O_CONFIG, cfg);
	if (!c)
		return VA_STATUS_ERROR_INVALID_CONFIG;
	const unsigned n = 6 + !!(c->rt_format & VA_RT_FORMAT_YUV420) +
			       !!(c->rt_format & VA_RT_FORMAT_YUV420_10);
	if (!a) {
		*num = n;
		return VA_STATUS_SUCCESS;
	}
	if (*num < n) {
		*num = n;
		return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
	}
	memset(a, 0, n * sizeof(*a));
	int i = 0;
	const uint32_t formats[] = {VA_FOURCC_NV12, VA_FOURCC_P010};
	for (unsigned f = 0; f < 2; f++) {
		if (!(c->rt_format & surface_rt_format(formats[f])))
			continue;
		a[i].type = VASurfaceAttribPixelFormat;
		a[i].flags = VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE;
		a[i].value.type = VAGenericValueTypeInteger;
		a[i++].value.value.i = formats[f];
	}
	a[i].type = VASurfaceAttribMinWidth;
	a[i].flags = VA_SURFACE_ATTRIB_GETTABLE;
	a[i].value.type = VAGenericValueTypeInteger;
	a[i++].value.value.i = 96;
	a[i].type = VASurfaceAttribMinHeight;
	a[i].flags = VA_SURFACE_ATTRIB_GETTABLE;
	a[i].value.type = VAGenericValueTypeInteger;
	a[i++].value.value.i = 96;
	a[i].type = VASurfaceAttribMaxWidth;
	a[i].flags = VA_SURFACE_ATTRIB_GETTABLE;
	a[i].value.type = VAGenericValueTypeInteger;
	a[i++].value.value.i = 8192;
	a[i].type = VASurfaceAttribMaxHeight;
	a[i].flags = VA_SURFACE_ATTRIB_GETTABLE;
	a[i].value.type = VAGenericValueTypeInteger;
	a[i++].value.value.i = 8192;
	a[i].type = VASurfaceAttribMemoryType;
	a[i].flags = VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE;
	a[i].value.type = VAGenericValueTypeInteger;
	a[i++].value.value.i = VA_SURFACE_ATTRIB_MEM_TYPE_VA | VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME |
			       VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2;
	a[i].type = VASurfaceAttribExternalBufferDescriptor;
	a[i].flags = VA_SURFACE_ATTRIB_SETTABLE;
	a[i].value.type = VAGenericValueTypePointer;
	i++;
	*num = (unsigned)i;
	return VA_STATUS_SUCCESS;
}

static VAStatus ExportSurfaceHandle(VADriverContextP ctx, VASurfaceID id, uint32_t mem,
				    uint32_t flags, void *desc)
{
	struct drv *d = DRV(ctx);
	if (mem != VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2)
		return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
	LOCK(d);
	struct surface *s = obj_get(d, O_SURFACE, id);
	if (!s) {
		UNLOCK(d);
		return VA_STATUS_ERROR_INVALID_SURFACE;
	}
	VADRMPRIMESurfaceDescriptor *o = desc;
	memset(o, 0, sizeof(*o));
	o->fourcc = s->fourcc;
	o->width = s->width;
	o->height = s->height;
	o->num_objects = 1;
	o->objects[0].fd = fcntl(s->fd, F_DUPFD_CLOEXEC, 0);
	o->objects[0].size = s->size;
	o->objects[0].drm_format_modifier = DRM_FORMAT_MOD_LINEAR;
	if (flags & VA_EXPORT_SURFACE_SEPARATE_LAYERS) {
		o->num_layers = 2;
		o->layers[0].drm_format = s->fourcc == VA_FOURCC_P010 ? DRM_FORMAT_R16 : DRM_FORMAT_R8;
		o->layers[0].num_planes = 1;
		o->layers[0].pitch[0] = s->pitch;
		o->layers[1].drm_format = s->fourcc == VA_FOURCC_P010 ? DRM_FORMAT_GR1616 : DRM_FORMAT_GR88;
		o->layers[1].num_planes = 1;
		o->layers[1].offset[0] = s->uv_offset;
		o->layers[1].pitch[0] = s->pitch;
	} else {
		o->num_layers = 1;
		o->layers[0].drm_format = s->fourcc;
		o->layers[0].num_planes = 2;
		o->layers[0].pitch[0] = s->pitch;
		o->layers[0].offset[1] = s->uv_offset;
		o->layers[0].pitch[1] = s->pitch;
	}
	UNLOCK(d);
	return o->objects[0].fd < 0 ? VA_STATUS_ERROR_OPERATION_FAILED : VA_STATUS_SUCCESS;
}

/* ---------------- contexts ---------------- */

static VAStatus CreateContext(VADriverContextP ctx, VAConfigID cfg, int w, int h, int flag,
			      VASurfaceID *targets, int ntargets, VAContextID *id)
{
	struct drv *d = DRV(ctx);
	(void)flag;
	struct config *cf = obj_get(d, O_CONFIG, cfg);
	if (!cf)
		return VA_STATUS_ERROR_INVALID_CONFIG;
	struct context *c = calloc(1, sizeof(*c));
	if (!c)
		return VA_STATUS_ERROR_ALLOCATION_FAILED;
	c->drv = d;
	c->cfg = *cf;
	c->width = (uint32_t)w;
	c->height = (uint32_t)h;
	c->fd = -1;
	if (dec_open(c)) {
		dbg(d, "can't open decoder %s", d->dec_path);
		free(c);
		return VA_STATUS_ERROR_HW_BUSY;
	}
	LOCK(d);
	for (int i = 0; i < ntargets; i++) {
		struct surface *s = obj_get(d, O_SURFACE, targets[i]);
		if (s)
			s->ctx = c;
	}
	*id = obj_add(d, O_CONTEXT, c);
	UNLOCK(d);
	dbg(d, "context %dx%d profile %d", w, h, cf->profile);
	return VA_STATUS_SUCCESS;
}

static VAStatus DestroyContext(VADriverContextP ctx, VAContextID id)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	struct context *c = obj_get(d, O_CONTEXT, id);
	if (!c) {
		UNLOCK(d);
		return VA_STATUS_ERROR_INVALID_CONTEXT;
	}
	obj_del(d, O_CONTEXT, id);
	struct obj_table *st = &d->tab[O_SURFACE];
	for (unsigned i = 0; i < st->cap; i++) {
		struct surface *s = st->items[i];
		if (s && s->ctx == c) {
			s->ctx = NULL;
			s->slot = -1;
			s->pending = 0;
		}
	}
	dec_close(c);
	free(c->slices);
	free(c->av1_slices);
	free(c->av1_deferred.data);
	free(c->tiles);
	free(c->nal);
	free(c);
	UNLOCK(d);
	return VA_STATUS_SUCCESS;
}

/* ---------------- buffers ---------------- */

static VAStatus CreateBuffer(VADriverContextP ctx, VAContextID cid, VABufferType type,
			     unsigned int size, unsigned int num, void *data, VABufferID *id)
{
	struct drv *d = DRV(ctx);
	(void)cid;
	struct buffer *b = calloc(1, sizeof(*b));
	if (!b)
		return VA_STATUS_ERROR_ALLOCATION_FAILED;
	b->type = type;
	b->size = size;
	b->num = num;
	b->image = VA_INVALID_ID;
	b->data = malloc((size_t)size * num + 64);
	if (!b->data) {
		free(b);
		return VA_STATUS_ERROR_ALLOCATION_FAILED;
	}
	if (data)
		memcpy(b->data, data, (size_t)size * num);
	LOCK(d);
	*id = obj_add(d, O_BUFFER, b);
	UNLOCK(d);
	return VA_STATUS_SUCCESS;
}

static VAStatus BufferSetNumElements(VADriverContextP ctx, VABufferID id, unsigned int num)
{
	struct buffer *b = obj_get(DRV(ctx), O_BUFFER, id);
	if (!b)
		return VA_STATUS_ERROR_INVALID_BUFFER;
	if (num > b->num) {
		uint8_t *n = realloc(b->data, (size_t)b->size * num + 64);
		if (!n)
			return VA_STATUS_ERROR_ALLOCATION_FAILED;
		b->data = n;
	}
	b->num = num;
	return VA_STATUS_SUCCESS;
}

static VAStatus MapBuffer(VADriverContextP ctx, VABufferID id, void **p)
{
	struct buffer *b = obj_get(DRV(ctx), O_BUFFER, id);
	if (!b)
		return VA_STATUS_ERROR_INVALID_BUFFER;
	if (b->derived) {
		if (surf_map(b->derived))
			return VA_STATUS_ERROR_OPERATION_FAILED;
		struct dma_buf_sync sy = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW};
		ioctl(b->derived->fd, DMA_BUF_IOCTL_SYNC, &sy);
		*p = b->derived->map;
	} else {
		*p = b->data;
	}
	return VA_STATUS_SUCCESS;
}

static VAStatus UnmapBuffer(VADriverContextP ctx, VABufferID id)
{
	struct buffer *b = obj_get(DRV(ctx), O_BUFFER, id);
	if (!b)
		return VA_STATUS_ERROR_INVALID_BUFFER;
	if (b->derived && b->derived->map) {
		struct dma_buf_sync sy = {.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW};
		ioctl(b->derived->fd, DMA_BUF_IOCTL_SYNC, &sy);
	}
	return VA_STATUS_SUCCESS;
}

static VAStatus DestroyBuffer(VADriverContextP ctx, VABufferID id)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	struct buffer *b = obj_get(d, O_BUFFER, id);
	if (b) {
		obj_del(d, O_BUFFER, id);
		free(b->data);
		free(b);
	}
	UNLOCK(d);
	return b ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_BUFFER;
}

static VAStatus BufferInfo(VADriverContextP ctx, VABufferID id, VABufferType *type,
			   unsigned int *size, unsigned int *num)
{
	struct buffer *b = obj_get(DRV(ctx), O_BUFFER, id);
	if (!b)
		return VA_STATUS_ERROR_INVALID_BUFFER;
	*type = b->type;
	*size = b->size;
	*num = b->num;
	return VA_STATUS_SUCCESS;
}

/* ---------------- pictures ---------------- */

static VAStatus BeginPicture(VADriverContextP ctx, VAContextID cid, VASurfaceID sid)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	struct context *c = obj_get(d, O_CONTEXT, cid);
	struct surface *s = obj_get(d, O_SURFACE, sid);
	if (!c || !s) {
		UNLOCK(d);
		return c ? VA_STATUS_ERROR_INVALID_SURFACE : VA_STATUS_ERROR_INVALID_CONTEXT;
	}
	if (!(c->cfg.rt_format & surface_rt_format(s->fourcc))) {
		UNLOCK(d);
		return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
	}
	if (s->pending && s->ctx == c)
		dec_wait(c, s, 1000);
	s->ctx = c;
	c->target = s;
	c->have_iq = 0;
	c->nslices = 0;
	c->nal_len = 0;
	c->idr = 0;
	c->av1_nslices = 0;
	c->av1_ntiles = 0;
	c->tiles_len = 0;
	memset(c->pps_used, 0, sizeof(c->pps_used));
	UNLOCK(d);
	return VA_STATUS_SUCCESS;
}

static int nal_append(struct context *c, const uint8_t *p, size_t n)
{
	if (c->nal_len + n + 4 > c->nal_cap) {
		size_t cap = (c->nal_len + n + 4) * 2;
		uint8_t *nn = realloc(c->nal, cap);
		if (!nn)
			return -1;
		c->nal = nn;
		c->nal_cap = cap;
	}
	c->nal[c->nal_len++] = 0;
	c->nal[c->nal_len++] = 0;
	c->nal[c->nal_len++] = 1;
	memcpy(c->nal + c->nal_len, p, n);
	c->nal_len += n;
	return 0;
}

static VAStatus add_slices(struct context *c, const struct buffer *data)
{
	for (unsigned i = 0; i < c->nslices; i++) {
		const VASliceParameterBufferH264 *sp = &c->slices[i];
		size_t total = (size_t)data->size * data->num;
		if ((size_t)sp->slice_data_offset + sp->slice_data_size > total)
			return VA_STATUS_ERROR_INVALID_PARAMETER;
		const uint8_t *p = data->data + sp->slice_data_offset;
		size_t n = sp->slice_data_size;
		/* Some clients leave the start code on. */
		if (n > 3 && !p[0] && !p[1] && p[2] == 1)
			p += 3, n -= 3;
		else if (n > 4 && !p[0] && !p[1] && !p[2] && p[3] == 1)
			p += 4, n -= 4;
		int pps_id = 0, nal_type = 0;
		if (h264_parse_slice(c, sp, p, n, &pps_id, &nal_type)) {
			dbg(c->drv, "can't parse slice header");
			return VA_STATUS_ERROR_INVALID_PARAMETER;
		}
		if (nal_type == 5)
			c->idr = 1;
		c->pps_used[pps_id / 8] |= 1 << (pps_id % 8);
		if (nal_append(c, p, n))
			return VA_STATUS_ERROR_ALLOCATION_FAILED;
	}
	c->nslices = 0;
	return VA_STATUS_SUCCESS;
}

static VAStatus render_av1(struct context *c, struct buffer *b)
{
	switch (b->type) {
	case VAPictureParameterBufferType:
		memset(&c->av1, 0, sizeof(c->av1));
		memcpy(&c->av1, b->data, b->size < sizeof(c->av1) ? b->size : sizeof(c->av1));
		if (c->av1.bit_depth_idx > 1 ||
		    c->target->fourcc != (c->av1.bit_depth_idx ? VA_FOURCC_P010 : VA_FOURCC_NV12)) {
			dbg(c->drv, "av1: picture bit depth does not match its surface");
			return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
		}
		c->have_pic = 1;
		break;
	case VASliceParameterBufferType: {
		VASliceParameterBufferAV1 *ns = realloc(c->av1_slices, b->num * sizeof(*ns));
		if (!ns)
			return VA_STATUS_ERROR_ALLOCATION_FAILED;
		c->av1_slices = ns;
		memcpy(ns, b->data, b->num * sizeof(*ns));
		c->av1_nslices = b->num;
		break;
	}
	case VASliceDataBufferType:
		if (!c->have_pic || av1_add_tiles(c, b))
			return VA_STATUS_ERROR_INVALID_PARAMETER;
		break;
	default:
		break;
	}
	return VA_STATUS_SUCCESS;
}

static VAStatus end_av1(struct drv *d, struct context *c)
{
	uint8_t *frame = NULL;
	VAStatus st = VA_STATUS_ERROR_DECODING_ERROR;
	if (c->have_pic && !c->failed && !av1_finish_refs(c)) {
		size_t n = av1_build(c, &frame);
		if (n && !dec_submit(c, frame, n, c->target) &&
		    !dec_wait(c, c->target, 1000))
			st = VA_STATUS_SUCCESS;
	}
	free(frame);
	if (st != VA_STATUS_SUCCESS) {
		c->target->error = 1;
		c->failed = 1;
	}
	return st;
}

static VAStatus RenderPicture(VADriverContextP ctx, VAContextID cid, VABufferID *bufs, int n)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	struct context *c = obj_get(d, O_CONTEXT, cid);
	VAStatus st = c ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_CONTEXT;
	for (int i = 0; c && i < n && st == VA_STATUS_SUCCESS; i++) {
		struct buffer *b = obj_get(d, O_BUFFER, bufs[i]);
		if (!b) {
			st = VA_STATUS_ERROR_INVALID_BUFFER;
			break;
		}
		if (c->cfg.profile == VAProfileAV1Profile0) {
			st = render_av1(c, b);
			continue;
		}
		switch (b->type) {
		case VAPictureParameterBufferType:
			memcpy(&c->pic, b->data, sizeof(c->pic));
			c->have_pic = 1;
			break;
		case VAIQMatrixBufferType:
			memcpy(&c->iq, b->data, sizeof(c->iq));
			c->have_iq = 1;
			break;
		case VASliceParameterBufferType: {
			VASliceParameterBufferH264 *ns = realloc(c->slices, b->num * sizeof(*ns));
			if (!ns) {
				st = VA_STATUS_ERROR_ALLOCATION_FAILED;
				break;
			}
			c->slices = ns;
			memcpy(ns, b->data, b->num * sizeof(*ns));
			c->nslices = b->num;
			break;
		}
		case VASliceDataBufferType:
			if (!c->have_pic)
				st = VA_STATUS_ERROR_INVALID_PARAMETER;
			else
				st = add_slices(c, b);
			break;
		default:
			break;                         /* e.g. probability tables we don't need */
		}
	}
	UNLOCK(d);
	return st;
}

static VAStatus EndPicture(VADriverContextP ctx, VAContextID cid)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	struct context *c = obj_get(d, O_CONTEXT, cid);
	if (!c || !c->target) {
		UNLOCK(d);
		return VA_STATUS_ERROR_INVALID_CONTEXT;
	}
	if (c->cfg.profile == VAProfileAV1Profile0) {
		VAStatus st = end_av1(d, c);
		c->target = NULL;
		UNLOCK(d);
		return st;
	}
	if (c->failed || !c->nal_len) {
		c->target->error = 1;
		UNLOCK(d);
		return c->failed ? VA_STATUS_ERROR_DECODING_ERROR : VA_STATUS_SUCCESS;
	}

	uint8_t sps[96];
	size_t sl = h264_write_sps(c, sps, sizeof(sps));
	size_t hdr = 0;
	static uint8_t ps[96 + 256 * 720];
	int sps_changed = sl != (size_t)c->sps_len || memcmp(sps, c->sps, sl);
	if (sps_changed || c->idr) {
		memcpy(ps, sps, sl);
		hdr = sl;
		memcpy(c->sps, sps, sl);
		c->sps_len = (int)sl;
	}
	for (int id = 0; id < 256; id++) {
		if (!(c->pps_used[id / 8] & (1 << (id % 8))))
			continue;
		uint8_t pps[720];
		size_t pl = h264_write_pps(c, id, pps, sizeof(pps));
		if (sps_changed || c->idr || pl != c->pps_len[id] || memcmp(pps, c->pps[id], pl)) {
			memcpy(ps + hdr, pps, pl);
			hdr += pl;
			memcpy(c->pps[id], pps, pl);
			c->pps_len[id] = (uint16_t)pl;
		}
	}
	/*
	 * An access unit delimiter after the slices: with several slices per
	 * picture the firmware otherwise waits for the next picture to start
	 * before it knows this one is complete, and returns it a frame late.
	 */
	static const uint8_t aud[] = {0, 0, 0, 1, 0x09, 0xf0};
	size_t total = hdr + c->nal_len + sizeof(aud);
	uint8_t *frame = malloc(total);
	VAStatus st = VA_STATUS_SUCCESS;
	if (!frame) {
		st = VA_STATUS_ERROR_ALLOCATION_FAILED;
	} else {
		memcpy(frame, ps, hdr);
		memcpy(frame + hdr, c->nal, c->nal_len);
		memcpy(frame + hdr + c->nal_len, aud, sizeof(aud));
		/*
		 * Finish the picture before returning. Clients that rely on the
		 * kernel's implicit sync (Chromium on Linux) hand the surface to
		 * the GPU without vaSyncSurface; the video core's driver attaches
		 * no fence, so the GPU would sample a half-written frame.
		 * Decoding takes ~2 ms and pictures are serialised anyway.
		 */
		if (dec_submit(c, frame, total, c->target)) {
			st = VA_STATUS_ERROR_DECODING_ERROR;
		} else if (c->target->pending && !c->late_output) {
			/*
			 * Without decode-order output (older kernels) a B-frame
			 * stream returns each picture only once the next one is
			 * in: waiting here would stall every frame. After the
			 * first such delay, leave it to vaSyncSurface.
			 */
			if (dec_wait(c, c->target, c->decode_order ? 1000 : 200)) {
				if (!c->decode_order) {
					c->late_output = 1;
					c->target->pending = 1;
					c->target->error = 0;
					dbg(d, "pictures come back late (no decode-order output), not waiting for them");
				} else {
					st = VA_STATUS_ERROR_DECODING_ERROR;
				}
			}
		}
		free(frame);
	}
	c->target = NULL;
	UNLOCK(d);
	return st;
}

static VAStatus SyncSurface(VADriverContextP ctx, VASurfaceID sid)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	struct surface *s = obj_get(d, O_SURFACE, sid);
	VAStatus st = VA_STATUS_SUCCESS;
	if (!s)
		st = VA_STATUS_ERROR_INVALID_SURFACE;
	else if (s->pending && s->ctx && dec_wait(s->ctx, s, 1000))
		st = VA_STATUS_ERROR_DECODING_ERROR;
	UNLOCK(d);
	return st;
}

static VAStatus SyncSurface2(VADriverContextP ctx, VASurfaceID sid, uint64_t timeout_ns)
{
	(void)timeout_ns;
	return SyncSurface(ctx, sid);
}

static VAStatus QuerySurfaceStatus(VADriverContextP ctx, VASurfaceID sid, VASurfaceStatus *st)
{
	struct surface *s = obj_get(DRV(ctx), O_SURFACE, sid);
	if (!s)
		return VA_STATUS_ERROR_INVALID_SURFACE;
	*st = s->pending ? VASurfaceRendering : VASurfaceReady;
	return VA_STATUS_SUCCESS;
}

static VAStatus QuerySurfaceError(VADriverContextP ctx, VASurfaceID sid, VAStatus err, void **info)
{
	(void)ctx;
	(void)sid;
	(void)err;
	*info = NULL;
	return VA_STATUS_ERROR_UNIMPLEMENTED;
}

/* ---------------- images ---------------- */

static void image_fill(VAImage *im, uint32_t fourcc, uint32_t w, uint32_t h, uint32_t pitch, uint32_t uv,
		       uint32_t size)
{
	memset(im, 0, sizeof(*im));
	im->format.fourcc = fourcc;
	im->format.byte_order = VA_LSB_FIRST;
	im->format.bits_per_pixel = 12 * video_sample_bytes(fourcc);
	im->width = (uint16_t)w;
	im->height = (uint16_t)h;
	im->data_size = size;
	im->num_planes = 2;
	im->pitches[0] = pitch;
	im->pitches[1] = pitch;
	im->offsets[1] = uv;
}

static VAStatus QueryImageFormats(VADriverContextP ctx, VAImageFormat *list, int *num)
{
	int count = DRV(ctx)->p010 ? 2 : 1;
	memset(list, 0, count * sizeof(*list));
	list[0].fourcc = VA_FOURCC_NV12;
	list[0].byte_order = VA_LSB_FIRST;
	list[0].bits_per_pixel = 12;
	if (count == 2) {
		list[1].fourcc = VA_FOURCC_P010;
		list[1].byte_order = VA_LSB_FIRST;
		list[1].bits_per_pixel = 24;
	}
	*num = count;
	return VA_STATUS_SUCCESS;
}

static VAStatus new_image(struct drv *d, VAImage *im, struct surface *derived)
{
	struct image *i = calloc(1, sizeof(*i));
	struct buffer *b = calloc(1, sizeof(*b));
	if (!i || !b) {
		free(i);
		free(b);
		return VA_STATUS_ERROR_ALLOCATION_FAILED;
	}
	b->type = VAImageBufferType;
	b->size = im->data_size;
	b->num = 1;
	b->derived = derived;
	if (!derived && !(b->data = malloc(im->data_size))) {
		free(i);
		free(b);
		return VA_STATUS_ERROR_ALLOCATION_FAILED;
	}
	i->derived = derived;
	LOCK(d);
	im->buf = obj_add(d, O_BUFFER, b);
	im->image_id = obj_add(d, O_IMAGE, i);
	b->image = im->image_id;
	i->va = *im;
	UNLOCK(d);
	return VA_STATUS_SUCCESS;
}

static VAStatus CreateImage(VADriverContextP ctx, VAImageFormat *fmt, int w, int h, VAImage *im)
{
	if (fmt->fourcc != VA_FOURCC_NV12 &&
	    !(fmt->fourcc == VA_FOURCC_P010 && DRV(ctx)->p010))
		return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
	if (w <= 0 || h <= 0 || w > 8192 || h > 8192)
		return VA_STATUS_ERROR_INVALID_PARAMETER;
	uint32_t pitch = ALIGN((uint32_t)w * video_sample_bytes(fmt->fourcc), 16);
	uint32_t uv = pitch * ALIGN((uint32_t)h, 2);
	image_fill(im, fmt->fourcc, (uint32_t)w, (uint32_t)h, pitch, uv,
		   uv + pitch * (((uint32_t)h + 1) / 2));
	im->format = *fmt;
	return new_image(DRV(ctx), im, NULL);
}

static VAStatus DeriveImage(VADriverContextP ctx, VASurfaceID sid, VAImage *im)
{
	struct drv *d = DRV(ctx);
	struct surface *s = obj_get(d, O_SURFACE, sid);
	if (!s)
		return VA_STATUS_ERROR_INVALID_SURFACE;
	if (s->pending && s->ctx) {
		LOCK(d);
		dec_wait(s->ctx, s, 1000);
		UNLOCK(d);
	}
	image_fill(im, s->fourcc, s->width, s->height, s->pitch, s->uv_offset, s->size);
	return new_image(d, im, s);
}

static VAStatus DestroyImage(VADriverContextP ctx, VAImageID id)
{
	struct drv *d = DRV(ctx);
	LOCK(d);
	struct image *i = obj_get(d, O_IMAGE, id);
	VABufferID buf = i ? i->va.buf : VA_INVALID_ID;
	if (i) {
		obj_del(d, O_IMAGE, id);
		free(i);
	}
	UNLOCK(d);
	if (buf != VA_INVALID_ID)
		DestroyBuffer(ctx, buf);
	return i ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_IMAGE;
}

static VAStatus GetImage(VADriverContextP ctx, VASurfaceID sid, int x, int y, unsigned int w,
			 unsigned int h, VAImageID iid)
{
	struct drv *d = DRV(ctx);
	struct surface *s = obj_get(d, O_SURFACE, sid);
	struct image *i = obj_get(d, O_IMAGE, iid);
	if (!s)
		return VA_STATUS_ERROR_INVALID_SURFACE;
	if (!i)
		return VA_STATUS_ERROR_INVALID_IMAGE;
	if (s->fourcc != i->va.format.fourcc)
		return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
	struct buffer *b = obj_get(d, O_BUFFER, i->va.buf);
	if (!b || !b->data)
		return VA_STATUS_ERROR_INVALID_BUFFER;
	LOCK(d);
	if (s->pending && s->ctx)
		dec_wait(s->ctx, s, 1000);
	UNLOCK(d);
	if (surf_map(s))
		return VA_STATUS_ERROR_OPERATION_FAILED;
	if (x < 0 || y < 0 || (uint32_t)x > s->width || (uint32_t)y > s->height ||
	    w > s->width - (uint32_t)x || h > s->height - (uint32_t)y ||
	    w > i->va.width || h > i->va.height)
		return VA_STATUS_ERROR_INVALID_PARAMETER;
	x &= ~1;
	y &= ~1;
	struct dma_buf_sync sy = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ};
	ioctl(s->fd, DMA_BUF_IOCTL_SYNC, &sy);
	const uint8_t *src = (const uint8_t *)s->map;
	unsigned bytes = video_sample_bytes(s->fourcc);
	for (unsigned r = 0; r < h; r++)
		memcpy(b->data + i->va.offsets[0] + (size_t)r * i->va.pitches[0],
		       src + (size_t)(y + r) * s->pitch + (size_t)x * bytes, w * bytes);
	for (unsigned r = 0; r < (h + 1) / 2; r++)
		memcpy(b->data + i->va.offsets[1] + (size_t)r * i->va.pitches[1],
		       src + s->uv_offset + (size_t)(y / 2 + r) * s->pitch + (size_t)x * bytes,
		       ALIGN(w, 2) * bytes);
	sy.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
	ioctl(s->fd, DMA_BUF_IOCTL_SYNC, &sy);
	return VA_STATUS_SUCCESS;
}

/* ---------------- everything we don't do ---------------- */

static VAStatus Unimpl(void) { return VA_STATUS_ERROR_UNIMPLEMENTED; }

static VAStatus QuerySubpictureFormats(VADriverContextP ctx, VAImageFormat *l, unsigned int *f,
				       unsigned int *n)
{
	(void)ctx; (void)l; (void)f;
	*n = 0;
	return VA_STATUS_SUCCESS;
}

static VAStatus QueryDisplayAttributes(VADriverContextP ctx, VADisplayAttribute *l, int *n)
{
	(void)ctx; (void)l;
	*n = 0;
	return VA_STATUS_SUCCESS;
}

static VAStatus Terminate(VADriverContextP ctx)
{
	struct drv *d = DRV(ctx);
	for (int t = 0; t < O_MAX; t++)
		free(d->tab[t].items);
	if (d->render_fd >= 0)
		close(d->render_fd);
	pthread_mutex_destroy(&d->lock);
	free(d);
	ctx->pDriverData = NULL;
	return VA_STATUS_SUCCESS;
}

static int open_msm_render(void)
{
	for (int i = 128; i < 192; i++) {
		char p[32], name[16] = {0};
		snprintf(p, sizeof(p), "/dev/dri/renderD%d", i);
		int fd = open(p, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		struct k_drm_version v = {.name = name, .name_len = sizeof(name) - 1};
		if (!ioctl(fd, K_DRM_IOCTL_VERSION, &v) && !strcmp(name, "msm"))
			return fd;
		close(fd);
	}
	return -1;
}

#define SET(f, fn) vt->f = (void *)(fn)

VAStatus __vaDriverInit_1_17(VADriverContextP ctx);
VAStatus __attribute__((visibility("default"))) __vaDriverInit_1_17(VADriverContextP ctx)
{
	struct drv *d = calloc(1, sizeof(*d));
	if (!d)
		return VA_STATUS_ERROR_ALLOCATION_FAILED;
	const char *e = getenv("MSM_VA_DEBUG");
	d->debug = e ? atoi(e) : 0;
	const char *lf = getenv("MSM_VA_LOG");
	if (lf && *lf && (d->log = fopen(lf, "a")) && !d->debug)
		d->debug = 1;
	pthread_mutex_init(&d->lock, NULL);
	d->gpu_wait = -1;
	d->render_fd = open_msm_render();
	if (d->render_fd < 0 || dec_find(d->dec_path, sizeof(d->dec_path))) {
		dbg(d, "no msm render node or V4L2 H.264 decoder");
		if (d->render_fd >= 0)
			close(d->render_fd);
		free(d);
		return VA_STATUS_ERROR_UNKNOWN;
	}
	d->av1 = !getenv("MSM_VA_NO_AV1") && dec_has_av1(d->dec_path);
	d->p010 = d->av1 && dec_has_p010(d->dec_path);
	dbg(d, "decoder %s%s", d->dec_path, d->av1 ? " (AV1 too)" : "");

	ctx->pDriverData = d;
	ctx->version_major = VA_MAJOR_VERSION;
	ctx->version_minor = VA_MINOR_VERSION;
	ctx->max_profiles = MAX_PROFILES;
	ctx->max_entrypoints = 1;
	ctx->max_attributes = 8;
	ctx->max_image_formats = 2;
	ctx->max_subpic_formats = 1;
	ctx->max_display_attributes = 1;
	ctx->str_vendor = VENDOR;

	struct VADriverVTable *vt = ctx->vtable;
	SET(vaTerminate, Terminate);
	SET(vaQueryConfigProfiles, QueryConfigProfiles);
	SET(vaQueryConfigEntrypoints, QueryConfigEntrypoints);
	SET(vaGetConfigAttributes, GetConfigAttributes);
	SET(vaCreateConfig, CreateConfig);
	SET(vaDestroyConfig, DestroyConfig);
	SET(vaQueryConfigAttributes, QueryConfigAttributes);
	SET(vaCreateSurfaces, CreateSurfaces);
	SET(vaCreateSurfaces2, CreateSurfaces2);
	SET(vaDestroySurfaces, DestroySurfaces);
	SET(vaCreateContext, CreateContext);
	SET(vaDestroyContext, DestroyContext);
	SET(vaCreateBuffer, CreateBuffer);
	SET(vaBufferSetNumElements, BufferSetNumElements);
	SET(vaMapBuffer, MapBuffer);
	SET(vaUnmapBuffer, UnmapBuffer);
	SET(vaDestroyBuffer, DestroyBuffer);
	SET(vaBufferInfo, BufferInfo);
	SET(vaBeginPicture, BeginPicture);
	SET(vaRenderPicture, RenderPicture);
	SET(vaEndPicture, EndPicture);
	SET(vaSyncSurface, SyncSurface);
	SET(vaSyncSurface2, SyncSurface2);
	SET(vaQuerySurfaceStatus, QuerySurfaceStatus);
	SET(vaQuerySurfaceError, QuerySurfaceError);
	SET(vaQuerySurfaceAttributes, QuerySurfaceAttributes);
	SET(vaExportSurfaceHandle, ExportSurfaceHandle);
	SET(vaQueryImageFormats, QueryImageFormats);
	SET(vaCreateImage, CreateImage);
	SET(vaDeriveImage, DeriveImage);
	SET(vaDestroyImage, DestroyImage);
	SET(vaGetImage, GetImage);
	SET(vaQuerySubpictureFormats, QuerySubpictureFormats);
	SET(vaQueryDisplayAttributes, QueryDisplayAttributes);
	SET(vaPutSurface, Unimpl);
	SET(vaPutImage, Unimpl);
	SET(vaSetImagePalette, Unimpl);
	SET(vaCreateSubpicture, Unimpl);
	SET(vaDestroySubpicture, Unimpl);
	SET(vaSetSubpictureImage, Unimpl);
	SET(vaSetSubpictureChromakey, Unimpl);
	SET(vaSetSubpictureGlobalAlpha, Unimpl);
	SET(vaAssociateSubpicture, Unimpl);
	SET(vaDeassociateSubpicture, Unimpl);
	SET(vaGetDisplayAttributes, Unimpl);
	SET(vaSetDisplayAttributes, Unimpl);
	SET(vaLockSurface, Unimpl);
	SET(vaUnlockSurface, Unimpl);
	return VA_STATUS_SUCCESS;
}
