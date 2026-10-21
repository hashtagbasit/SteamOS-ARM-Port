/*
 * msm_drv_video: a VA-API decode driver for V4L2 stateful (memory-to-memory)
 * decoders, written for the Snapdragon video cores (iris / venus) that the
 * SteamOS ARM handhelds expose as /dev/videoN.
 *
 * VA-API hands a driver pre-parsed pictures: parameter structures plus raw
 * slice NAL units. A stateful decoder wants a plain Annex-B stream. So per
 * picture we rebuild the parameter sets the slices refer to from the VA
 * structures, put the slices back behind start codes and let the firmware
 * do the rest. The synthesized SPS declares no frame reordering, so the
 * firmware returns every picture as soon as it is decoded, in decode order,
 * which is exactly what VA-API promises its clients.
 *
 * The library is named after the DRM driver of the GPU next to the video
 * core (msm), which is the name libva derives from the render node, so
 * clients find it without LIBVA_DRIVER_NAME.
 */
#pragma once

#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_dec_av1.h>
#include <va/va_drmcommon.h>
#include "../formats.h"

#define MAX_PROFILES 5
#define MAX_SLOTS 32
#define NUM_OUT_BUFS 6
#define MAX_INFLIGHT 64
#define ALIGN(x, a) (((x) + (a) - 1) & ~((a) - 1))

enum obj_type { O_CONFIG = 1, O_CONTEXT, O_SURFACE, O_BUFFER, O_IMAGE, O_MAX };

struct obj_table {
	void **items;
	unsigned cap;
};

struct drv {
	pthread_mutex_t lock;
	int render_fd;               /* our own render node, never the client's */
	char dec_path[32];           /* /dev/videoN of the decoder */
	int av1;                     /* the decoder takes AV1 too */
	int p010;                    /* linear 10-bit capture is available */
	struct obj_table tab[O_MAX];
	int debug;
	FILE *log;
	int gpu_wait;                /* 1 kernel can wait for bookkeeping fences, 0 no, -1 unknown */
	uint64_t gpu_busy, gpu_checks, gpu_wait_ns, gpu_wait_max_ns;
};

struct config {
	VAProfile profile;
	VAEntrypoint entrypoint;
	uint32_t rt_format;
};

struct context;

/* What the AV1 header writer remembers about frames the client may still reference. */
struct av1_ref {
	VASurfaceID id;
	uint8_t order_hint;
	int32_t gm[8][6];
};

struct surface {
	uint32_t width, height;      /* as created */
	uint32_t fourcc;
	uint32_t pitch;              /* luma and chroma row pitch */
	uint32_t uv_offset;
	uint32_t size;
	int fd;                      /* dma-buf */
	uint32_t gem;                /* its handle on our render node, 0 if none */
	int imported;
	void *map;
	int slot;                    /* capture slot in ctx, -1 if none */
	struct context *ctx;
	int pending;                 /* submitted, not yet returned by the decoder */
	int error;
	uint64_t ts;
	uint64_t replaced_ns;         /* when a newer picture finished decoding */
	uint64_t done_ns;             /* when this picture finished decoding */
};

struct pps_learned {
	int known;
	uint8_t l0, l1;              /* num_ref_idx_lX_default_active_minus1 */
};

struct context {
	struct drv *drv;
	struct config cfg;
	uint32_t width, height;
	int fd;                      /* V4L2 decoder instance */

	struct {
		void *map;
		uint32_t len;
		int queued;
	} out[NUM_OUT_BUFS];
	int out_count;

	int cap_ready;
	int copy_mode;               /* decode into driver buffers, then copy */
	int decode_order;            /* firmware returns pictures in decode order */
	int late_output;             /* pictures come back a frame late: don't wait for them */
	uint32_t cap_pitch, cap_height, cap_size, cap_count;
	uint32_t cap_fourcc;
	void *cap_map[MAX_SLOTS];
	struct surface *slot_owner[MAX_SLOTS];
	unsigned next_slot;
	int failed;

	/* picture being built */
	struct surface *target;
	VAPictureParameterBufferH264 pic;
	int have_pic;
	VAIQMatrixBufferH264 iq;
	int have_iq;
	VASliceParameterBufferH264 *slices;
	unsigned nslices;
	uint8_t *nal;                /* start-code-delimited slice NALs */
	size_t nal_len, nal_cap;
	int idr;
	uint8_t pps_used[256 / 8];

	/* AV1: the picture being built, and what past pictures taught us */
	VADecPictureParameterBufferAV1 av1;
	VASliceParameterBufferAV1 *av1_slices;
	unsigned av1_nslices;
	uint8_t *tiles;              /* tile data in decode order */
	size_t tiles_len, tiles_cap;
	unsigned av1_ntiles;
	struct av1_ref av1_refs[16];
	uint8_t av1_seq[48];         /* sequence header last sent */
	int av1_seq_len;
	VASurfaceID av1_slot[8];     /* what each reference slot of the decoder holds (0: nothing) */
	struct {
		uint8_t *data;
		size_t len, refresh_bit;
		VASurfaceID surface;
	} av1_deferred;

	/* parameter sets last sent to the firmware */
	uint8_t sps[96];
	int sps_len;
	uint8_t pps[256][720];
	uint16_t pps_len[256];
	struct pps_learned learned[256];

	uint64_t seq;
	uint64_t frames;
	struct surface *inflight[MAX_INFLIGHT];
	struct surface *newest;
	struct {
		uint64_t waits, blocked, wait_ns, reuse_min_ns, reuse_sum_ns, reuses, fast;
		uint64_t nofence, fenced, read_after_decode, read_age_min_ns, guarded;
	} st;
};

struct buffer {
	VABufferType type;
	uint32_t size;               /* element size */
	uint32_t num;
	uint8_t *data;
	struct surface *derived;     /* image buffer backed by a surface */
	VAImageID image;
};

struct image {
	VAImage va;
	struct surface *derived;
};

/* driver.c */
void *obj_get(struct drv *d, enum obj_type t, uint32_t id);
void dbg(struct drv *d, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#define trace(d, ...) do { if ((d)->debug > 1) dbg(d, __VA_ARGS__); } while (0)

/* h264.c */
int h264_parse_slice(struct context *c, const VASliceParameterBufferH264 *sp,
		     const uint8_t *nal, size_t len, int *pps_id, int *nal_type);
size_t h264_write_sps(const struct context *c, uint8_t *out, size_t cap);
size_t h264_write_pps(const struct context *c, int pps_id, uint8_t *out, size_t cap);

/* av1.c */
int av1_add_tiles(struct context *c, const struct buffer *data);
size_t av1_build(struct context *c, uint8_t **out);
int av1_finish_refs(struct context *c);

/* dec.c */
int dec_has_av1(const char *path);
int dec_has_p010(const char *path);
int dec_find(char *path, size_t len);
int dec_open(struct context *c);
void dec_close(struct context *c);
int dec_submit(struct context *c, const uint8_t *data, size_t len, struct surface *target);
int dec_wait(struct context *c, struct surface *s, int timeout_ms);
int surf_map(struct surface *s);
uint64_t now_ns(void);
int gpu_wait(struct drv *d, struct surface *s, int timeout_ms);
