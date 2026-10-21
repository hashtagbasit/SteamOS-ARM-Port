/*
 * The V4L2 side: one decoder instance per VA context.
 *
 * Bitstream goes in on the OUTPUT queue (driver-allocated, mmapped). Decoded
 * frames come back on the CAPTURE queue. Normally that queue imports the
 * clients' surfaces as dma-bufs and only the current target is queued, so
 * the firmware writes the picture straight into the surface VA was told to
 * use. When a surface's layout doesn't match what the hardware writes
 * (pitch a multiple of 128, chroma at pitch * height rounded up to 32), the
 * context falls back to driver-owned capture buffers and copies.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/dma-buf.h>
#include <linux/videodev2.h>

#include "common.h"

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;
	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

#ifndef V4L2_PIX_FMT_AV1
#define V4L2_PIX_FMT_AV1 v4l2_fourcc('A', 'V', '0', '1')
#endif

int dec_has_av1(const char *path)
{
	int fd = open(path, O_RDWR | O_CLOEXEC), ok = 0;
	if (fd < 0)
		return 0;
	struct v4l2_fmtdesc f = {.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE};
	for (f.index = 0; !xioctl(fd, VIDIOC_ENUM_FMT, &f); f.index++)
		if (f.pixelformat == V4L2_PIX_FMT_AV1)
			ok = 1;
	close(fd);
	return ok;
}

int dec_find(char *path, size_t len)
{
	for (int i = 0; i < 64; i++) {
		char p[32];
		snprintf(p, sizeof(p), "/dev/video%d", i);
		int fd = open(p, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		struct v4l2_capability cap = {0};
		int ok = 0;
		if (!xioctl(fd, VIDIOC_QUERYCAP, &cap)) {
			uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ?
					cap.device_caps : cap.capabilities;
			if (caps & V4L2_CAP_VIDEO_M2M_MPLANE) {
				struct v4l2_fmtdesc fd_ = {.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE};
				for (fd_.index = 0; !xioctl(fd, VIDIOC_ENUM_FMT, &fd_); fd_.index++)
					if (fd_.pixelformat == V4L2_PIX_FMT_H264)
						ok = 1;
			}
		}
		close(fd);
		if (ok) {
			snprintf(path, len, "%s", p);
			return 0;
		}
	}
	return -1;
}

int surf_map(struct surface *s)
{
	if (s->map)
		return 0;
	void *m = mmap(NULL, s->size, PROT_READ | PROT_WRITE, MAP_SHARED, s->fd, 0);
	if (m == MAP_FAILED)
		return -1;
	s->map = m;
	return 0;
}

int dec_open(struct context *c)
{
	c->fd = open(c->drv->dec_path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (c->fd < 0)
		return -1;

	struct v4l2_event_subscription sub = {.type = V4L2_EVENT_SOURCE_CHANGE};
	xioctl(c->fd, VIDIOC_SUBSCRIBE_EVENT, &sub);

	struct v4l2_format f = {.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE};
	f.fmt.pix_mp.pixelformat = c->cfg.profile == VAProfileAV1Profile0 ? V4L2_PIX_FMT_AV1 :
				   V4L2_PIX_FMT_H264;
	f.fmt.pix_mp.width = c->width;
	f.fmt.pix_mp.height = c->height;
	f.fmt.pix_mp.num_planes = 1;
	if (xioctl(c->fd, VIDIOC_S_FMT, &f)) {
		dbg(c->drv, "S_FMT output: %s", strerror(errno));
		goto fail;
	}

	/*
	 * Decode-order output (iris, kernel patch 0049): every picture comes
	 * back right after it is decoded. Without it the firmware holds frames
	 * for display order and B-frame streams arrive a frame late.
	 */
	struct v4l2_control order = {.id = V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY_ENABLE, .value = 1};
	c->decode_order = !xioctl(c->fd, VIDIOC_S_CTRL, &order);
	if (c->decode_order) {
		struct v4l2_control delay = {.id = V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY, .value = 0};
		xioctl(c->fd, VIDIOC_S_CTRL, &delay);   /* absent on iris: zero is implied */
	}
	dbg(c->drv, "decode-order output %s", c->decode_order ? "on" : "not available");

	struct v4l2_requestbuffers rb = {.count = NUM_OUT_BUFS,
		.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, .memory = V4L2_MEMORY_MMAP};
	if (xioctl(c->fd, VIDIOC_REQBUFS, &rb) || !rb.count)
		goto fail;
	c->out_count = rb.count > NUM_OUT_BUFS ? NUM_OUT_BUFS : (int)rb.count;
	for (int i = 0; i < c->out_count; i++) {
		struct v4l2_plane pl[1] = {0};
		struct v4l2_buffer b = {.index = i, .type = rb.type, .memory = rb.memory,
			.m.planes = pl, .length = 1};
		if (xioctl(c->fd, VIDIOC_QUERYBUF, &b))
			goto fail;
		c->out[i].len = pl[0].length;
		c->out[i].map = mmap(NULL, pl[0].length, PROT_READ | PROT_WRITE, MAP_SHARED,
				     c->fd, pl[0].m.mem_offset);
		if (c->out[i].map == MAP_FAILED) {
			c->out[i].map = NULL;
			goto fail;
		}
	}
	int type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	if (xioctl(c->fd, VIDIOC_STREAMON, &type))
		goto fail;
	return 0;
fail:
	dec_close(c);
	return -1;
}

static void cap_release(struct context *c)
{
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	xioctl(c->fd, VIDIOC_STREAMOFF, &type);
	for (unsigned i = 0; i < MAX_SLOTS; i++) {
		if (c->cap_map[i])
			munmap(c->cap_map[i], c->cap_size);
		c->cap_map[i] = NULL;
		if (c->slot_owner[i]) {
			c->slot_owner[i]->slot = -1;
			c->slot_owner[i] = NULL;
		}
	}
	struct v4l2_requestbuffers rb = {.count = 0, .type = type,
		.memory = c->copy_mode ? V4L2_MEMORY_MMAP : V4L2_MEMORY_DMABUF};
	xioctl(c->fd, VIDIOC_REQBUFS, &rb);
	c->cap_ready = 0;
}

void dec_close(struct context *c)
{
	if (c->fd < 0)
		return;
	if (c->cap_ready)
		cap_release(c);
	int type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	xioctl(c->fd, VIDIOC_STREAMOFF, &type);
	for (int i = 0; i < c->out_count; i++)
		if (c->out[i].map)
			munmap(c->out[i].map, c->out[i].len);
	close(c->fd);
	c->fd = -1;
}

static int layout_fits(const struct surface *s, uint32_t pitch, uint32_t height)
{
	return s->pitch == pitch && s->uv_offset == pitch * height &&
	       s->size >= pitch * height + pitch * ALIGN((height + 1) / 2, 16);
}

/*
 * The video core's driver doesn't take part in dma-buf implicit sync, so a
 * surface the client has returned may still be read by the GPU (the frame
 * on screen). Wait for every fence on the buffer before the decoder writes
 * into it, as the GPU-side VA drivers get for free from their kernels.
 */
uint64_t now_ns(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static void wait_idle(struct context *c, int fd)
{
	struct pollfd p = {.fd = fd, .events = POLLOUT};
	uint64_t t0 = now_ns();
	int r = poll(&p, 1, 0);
	if (r == 0) {
		c->st.blocked++;
		if (poll(&p, 1, 100) == 0)
			dbg(c->drv, "surface still busy after 100 ms");
	}
	c->st.waits++;
	c->st.wait_ns += now_ns() - t0;
}

/* What the GPU did with a surface: its fences, from an exported sync file. */
struct k_sync_fence_info {
	char obj_name[32], driver_name[32];
	int32_t status;
	uint32_t flags;
	uint64_t timestamp_ns;
};
struct k_sync_file_info {
	char name[32];
	int32_t status;
	uint32_t flags, num_fences, pad;
	uint64_t sync_fence_info;
};
#define K_SYNC_IOC_FILE_INFO _IOWR('>', 4, struct k_sync_file_info)

static void fence_stats(struct context *c, struct surface *s)
{
	struct dma_buf_export_sync_file ex = {.flags = DMA_BUF_SYNC_WRITE, .fd = -1};
	if (ioctl(s->fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &ex) || ex.fd < 0)
		return;
	struct k_sync_fence_info fi[16];
	struct k_sync_file_info info = {.num_fences = 16, .sync_fence_info = (uintptr_t)fi};
	if (!ioctl(ex.fd, K_SYNC_IOC_FILE_INFO, &info)) {
		uint64_t latest = 0;
		for (uint32_t i = 0; i < info.num_fences && i < 16; i++)
			if (fi[i].status == 1 && fi[i].timestamp_ns > latest)
				latest = fi[i].timestamp_ns;
		/* A stub fence (no real users) reports one signaled fence at time 0. */
		if (!latest) {
			c->st.nofence++;
		} else {
			c->st.fenced++;
			/* sync_file timestamps are CLOCK_MONOTONIC */
			if (latest > s->done_ns)
				c->st.read_after_decode++;
			uint64_t age = now_ns() - latest;
			if (!c->st.read_age_min_ns || age < c->st.read_age_min_ns)
				c->st.read_age_min_ns = age;
		}
	}
	close(ex.fd);
}

/*
 * Until the GPU's reads can be waited for (see wait_idle), give the
 * compositor time to finish with a frame: don't decode into a surface until
 * MSM_VA_REUSE_GUARD_MS after a newer picture replaced it.
 */
static void reuse_guard(struct context *c, struct surface *s)
{
	static long guard_ms = -1;
	if (guard_ms < 0) {
		const char *e = getenv("MSM_VA_REUSE_GUARD_MS");
		guard_ms = e ? atol(e) : 12;
	}
	if (!guard_ms || !s->replaced_ns)
		return;
	uint64_t until = s->replaced_ns + (uint64_t)guard_ms * 1000000ull, now = now_ns();
	if (now < until) {
		struct timespec ts = {.tv_sec = 0, .tv_nsec = (long)(until - now)};
		nanosleep(&ts, NULL);
		c->st.guarded++;
	}
}

static void reuse_stats(struct context *c, struct surface *s)
{
	fence_stats(c, s);
	if (!s->replaced_ns)
		return;
	uint64_t d = now_ns() - s->replaced_ns;
	if (!c->st.reuses || d < c->st.reuse_min_ns)
		c->st.reuse_min_ns = d;
	c->st.reuse_sum_ns += d;
	c->st.reuses++;
	if (d < 25000000)
		c->st.fast++;
	if (c->st.reuses % 600 == 0) {
		dbg(c->drv, "reuse after replace: min %.1f avg %.1f ms, %llu of 600 under 25 ms; "
		    "fence wait blocked %llu of %llu, total %.1f ms",
		    c->st.reuse_min_ns / 1e6, c->st.reuse_sum_ns / 1e6 / 600,
		    (unsigned long long)c->st.fast, (unsigned long long)c->st.blocked,
		    (unsigned long long)c->st.waits, c->st.wait_ns / 1e6);
		dbg(c->drv, "fences at reuse: none %llu, present %llu (GPU read after our decode %llu, "
		    "latest read finished >= %.1f ms before reuse)",
		    (unsigned long long)c->st.nofence, (unsigned long long)c->st.fenced,
		    (unsigned long long)c->st.read_after_decode, c->st.read_age_min_ns / 1e6);
		dbg(c->drv, "reuse guard held %llu of 600", (unsigned long long)c->st.guarded);
		uint64_t r = c->st.reuses;
		memset(&c->st, 0, sizeof(c->st));
		c->st.reuses = r;
	}
}

static int queue_cap_slot(struct context *c, unsigned slot)
{
	struct v4l2_plane pl[1] = {0};
	struct v4l2_buffer b = {.index = slot, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
		.m.planes = pl, .length = 1};
	if (c->copy_mode) {
		b.memory = V4L2_MEMORY_MMAP;
	} else {
		struct surface *s = c->slot_owner[slot];
		reuse_stats(c, s);
		if (gpu_wait(c->drv, s, 100))
			reuse_guard(c, s);
		wait_idle(c, s->fd);
		b.memory = V4L2_MEMORY_DMABUF;
		pl[0].m.fd = s->fd;
		pl[0].length = s->size;
	}
	if (xioctl(c->fd, VIDIOC_QBUF, &b)) {
		dbg(c->drv, "QBUF capture %u: %s", slot, strerror(errno));
		return -1;
	}
	return 0;
}

/* Called once the firmware has parsed the first parameter sets. */
static int cap_setup(struct context *c, struct surface *target)
{
	struct v4l2_format f = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE};
	if (xioctl(c->fd, VIDIOC_G_FMT, &f))
		return -1;
	uint32_t w = f.fmt.pix_mp.width, h = f.fmt.pix_mp.height;
	dbg(c->drv, "decoder output %ux%u pitch %u size %u", w, h,
	    f.fmt.pix_mp.plane_fmt[0].bytesperline, f.fmt.pix_mp.plane_fmt[0].sizeimage);

	/* Ask for the target's own layout; the hardware rounds it the same way. */
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
	if (target->pitch >= w && target->uv_offset % target->pitch == 0 &&
	    target->uv_offset / target->pitch >= h) {
		f.fmt.pix_mp.width = target->pitch;
		f.fmt.pix_mp.height = target->uv_offset / target->pitch;
	}
	if (xioctl(c->fd, VIDIOC_S_FMT, &f))
		return -1;
	c->cap_pitch = f.fmt.pix_mp.plane_fmt[0].bytesperline;
	c->cap_height = f.fmt.pix_mp.height;
	c->cap_size = f.fmt.pix_mp.plane_fmt[0].sizeimage;
	c->copy_mode = !layout_fits(target, c->cap_pitch, c->cap_height) ||
		       target->size < c->cap_size;
	if (c->copy_mode)
		dbg(c->drv, "surface layout %u/%u/%u != decoder %u/%u/%u, copying",
		    target->pitch, target->uv_offset, target->size,
		    c->cap_pitch, c->cap_pitch * c->cap_height, c->cap_size);

	struct v4l2_control min = {.id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE};
	xioctl(c->fd, VIDIOC_G_CTRL, &min);
	struct v4l2_requestbuffers rb = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
		.memory = c->copy_mode ? V4L2_MEMORY_MMAP : V4L2_MEMORY_DMABUF,
		.count = c->copy_mode ? (unsigned)min.value + 4 : MAX_SLOTS};
	if (rb.count > MAX_SLOTS)
		rb.count = MAX_SLOTS;
	if (xioctl(c->fd, VIDIOC_REQBUFS, &rb) || !rb.count)
		return -1;
	c->cap_count = rb.count;

	if (c->copy_mode) {
		for (unsigned i = 0; i < c->cap_count; i++) {
			struct v4l2_plane pl[1] = {0};
			struct v4l2_buffer b = {.index = i, .type = rb.type, .memory = rb.memory,
				.m.planes = pl, .length = 1};
			if (xioctl(c->fd, VIDIOC_QUERYBUF, &b))
				return -1;
			void *m = mmap(NULL, pl[0].length, PROT_READ, MAP_SHARED, c->fd,
				       pl[0].m.mem_offset);
			if (m == MAP_FAILED)
				return -1;
			c->cap_map[i] = m;
			if (queue_cap_slot(c, i))
				return -1;
		}
	}
	int type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	if (xioctl(c->fd, VIDIOC_STREAMON, &type))
		return -1;
	c->cap_ready = 1;
	return 0;
}

static int bind_target(struct context *c, struct surface *s)
{
	if (s->slot < 0) {
		/* Take a slot nobody is waiting on, oldest first. */
		for (unsigned n = 0; n < c->cap_count; n++) {
			unsigned i = (c->next_slot + n) % c->cap_count;
			struct surface *o = c->slot_owner[i];
			if (o && o->pending)
				continue;
			if (o)
				o->slot = -1;
			c->slot_owner[i] = s;
			s->slot = (int)i;
			c->next_slot = i + 1;
			break;
		}
		if (s->slot < 0)
			return -1;
	}
	trace(c->drv, "q cap slot %d fd %d for %llu", s->slot, s->fd, (unsigned long long)c->seq + 1);
	return queue_cap_slot(c, (unsigned)s->slot);
}

static int wait_event(struct context *c, int timeout_ms)
{
	struct pollfd p = {.fd = c->fd, .events = POLLPRI};
	for (;;) {
		struct v4l2_event ev;
		if (!xioctl(c->fd, VIDIOC_DQEVENT, &ev)) {
			if (ev.type == V4L2_EVENT_SOURCE_CHANGE)
				return 0;
			continue;
		}
		int r = poll(&p, 1, timeout_ms);
		if (r <= 0)
			return -1;
	}
}

static void reclaim_output(struct context *c)
{
	for (;;) {
		struct v4l2_plane pl[1] = {0};
		struct v4l2_buffer b = {.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
			.memory = V4L2_MEMORY_MMAP, .m.planes = pl, .length = 1};
		if (xioctl(c->fd, VIDIOC_DQBUF, &b))
			return;
		if (b.index < (unsigned)c->out_count)
			c->out[b.index].queued = 0;
	}
}

/* Pictures in flight, looked up by timestamp in copy mode. */
static void inflight_add(struct context *c, struct surface *s)
{
	c->inflight[c->seq % MAX_INFLIGHT] = s;
}

static struct surface *find_pending(struct context *c, uint64_t ts)
{
	struct surface *s = c->inflight[ts % MAX_INFLIGHT];
	return (s && s->pending && s->ts == ts) ? s : NULL;
}

int dec_submit(struct context *c, const uint8_t *data, size_t len, struct surface *target)
{
	int idx = -1;
	for (int tries = 0; idx < 0 && tries < 100; tries++) {
		reclaim_output(c);
		for (int i = 0; i < c->out_count; i++)
			if (!c->out[i].queued) {
				idx = i;
				break;
			}
		if (idx < 0) {
			struct pollfd p = {.fd = c->fd, .events = POLLOUT};
			poll(&p, 1, 20);
		}
	}
	if (idx < 0 || len > c->out[idx].len) {
		dbg(c->drv, "no bitstream buffer (len %zu)", len);
		return -1;
	}

	/*
	 * The firmware fills whichever capture buffer it likes, so with more
	 * than one target queued pictures land in the wrong surfaces. Finish
	 * the previous picture first; decoding takes about a millisecond.
	 */
	if (c->cap_ready && !c->copy_mode) {
		for (unsigned i = 0; !c->late_output && i < MAX_INFLIGHT; i++) {
			struct surface *o = c->inflight[i];
			if (o && o->pending && o != target)
				dec_wait(c, o, 1000);
		}
		if (bind_target(c, target))
			return -1;
	}

	memcpy(c->out[idx].map, data, len);
	c->seq++;
	struct v4l2_plane pl[1] = {{.bytesused = (uint32_t)len, .length = c->out[idx].len}};
	struct v4l2_buffer b = {.index = (uint32_t)idx, .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE,
		.memory = V4L2_MEMORY_MMAP, .m.planes = pl, .length = 1};
	b.timestamp.tv_sec = (time_t)(c->seq / 1000000);
	b.timestamp.tv_usec = (suseconds_t)(c->seq % 1000000);
	trace(c->drv, "q out %d frame %llu len %zu", idx, (unsigned long long)c->seq, len);
	if (xioctl(c->fd, VIDIOC_QBUF, &b)) {
		dbg(c->drv, "QBUF output: %s", strerror(errno));
		return -1;
	}
	c->out[idx].queued = 1;
	target->ts = c->seq;
	target->pending = 1;
	target->error = 0;
	inflight_add(c, target);

	if (!c->cap_ready) {
		if (wait_event(c, 2000) || cap_setup(c, target)) {
			dbg(c->drv, "decoder never reported a format");
			c->failed = 1;
			return -1;
		}
		if (!c->copy_mode && bind_target(c, target))
			return -1;
	}
	return 0;
}

static void copy_out(struct context *c, unsigned slot, struct surface *s)
{
	if (surf_map(s))
		return;
	wait_idle(c, s->fd);
	const uint8_t *src = c->cap_map[slot];
	uint8_t *dst = s->map;
	uint32_t rows = s->height, w = s->pitch < c->cap_pitch ? s->pitch : c->cap_pitch;
	struct dma_buf_sync sy = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE};
	ioctl(s->fd, DMA_BUF_IOCTL_SYNC, &sy);
	for (uint32_t y = 0; y < rows; y++)
		memcpy(dst + (size_t)y * s->pitch, src + (size_t)y * c->cap_pitch, w);
	src += (size_t)c->cap_pitch * c->cap_height;
	dst += s->uv_offset;
	for (uint32_t y = 0; y < (rows + 1) / 2; y++)
		memcpy(dst + (size_t)y * s->pitch, src + (size_t)y * c->cap_pitch, w);
	sy.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
	ioctl(s->fd, DMA_BUF_IOCTL_SYNC, &sy);
}

int dec_wait(struct context *c, struct surface *s, int timeout_ms)
{
	while (s->pending) {
		reclaim_output(c);
		struct v4l2_plane pl[1] = {0};
		struct v4l2_buffer b = {.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
			.memory = c->copy_mode ? V4L2_MEMORY_MMAP : V4L2_MEMORY_DMABUF,
			.m.planes = pl, .length = 1};
		if (xioctl(c->fd, VIDIOC_DQBUF, &b)) {
			if (errno != EAGAIN)
				return -1;
			struct v4l2_event ev;
			if (!xioctl(c->fd, VIDIOC_DQEVENT, &ev) &&
			    ev.type == V4L2_EVENT_SOURCE_CHANGE) {
				dbg(c->drv, "resolution change mid-stream");
				cap_release(c);
				if (cap_setup(c, s) || (!c->copy_mode && bind_target(c, s)))
					return -1;
				continue;
			}
			struct pollfd p = {.fd = c->fd, .events = POLLIN | POLLPRI};
			if (poll(&p, 1, timeout_ms) <= 0) {
				dbg(c->drv, "decode timeout (frame %llu)", (unsigned long long)s->ts);
				s->pending = 0;
				s->error = 1;
				return -1;
			}
			continue;
		}
		uint64_t ts = (uint64_t)b.timestamp.tv_sec * 1000000 + (uint64_t)b.timestamp.tv_usec;
		trace(c->drv, "dq cap slot %u ts %llu flags %#x bytes %u", b.index,
		      (unsigned long long)ts, b.flags, pl[0].bytesused);
		if (c->copy_mode) {
			struct surface *o = find_pending(c, ts);
			if (o && !(b.flags & V4L2_BUF_FLAG_ERROR) && pl[0].bytesused)
				copy_out(c, b.index, o);
			if (o) {
				o->pending = 0;
				o->error = (b.flags & V4L2_BUF_FLAG_ERROR) != 0;
			}
			queue_cap_slot(c, b.index);
			continue;
		}
		struct surface *o = b.index < MAX_SLOTS ? c->slot_owner[b.index] : NULL;
		if (!o)
			continue;
		if (o->ts != ts)
			dbg(c->drv, "frame order: slot %u got %llu, expected %llu", b.index,
			    (unsigned long long)ts, (unsigned long long)o->ts);
		o->pending = 0;
		o->error = (b.flags & V4L2_BUF_FLAG_ERROR) || !pl[0].bytesused;
		c->frames++;
		if (c->newest && c->newest != o)
			c->newest->replaced_ns = now_ns();
		c->newest = o;
		o->replaced_ns = 0;
		o->done_ns = now_ns();
	}
	return s->error ? -1 : 0;
}
