#include <assert.h>
#include <stdarg.h>

#include "../src/av1.c"

static struct surface replay_surface;
static VASurfaceID replay_id;
static const uint8_t *original;
static size_t original_len, refresh_bit;
static unsigned refresh_flags, submissions;
static int submit_error, wait_error;

void dbg(struct drv *d, const char *fmt, ...)
{
	(void)d;
	(void)fmt;
}

void *obj_get(struct drv *d, enum obj_type type, uint32_t id)
{
	(void)d;
	assert(type == O_SURFACE);
	return id == replay_id ? &replay_surface : NULL;
}

int dec_submit(struct context *c, const uint8_t *data, size_t len, struct surface *target)
{
	assert(target == &replay_surface);
	assert(target->ctx == c);
	assert(len == original_len);
	for (size_t bit = 0; bit < len * 8; bit++) {
		unsigned expected = original[bit >> 3] >> (7 - (bit & 7)) & 1;
		if (bit >= refresh_bit && bit < refresh_bit + 8)
			expected = refresh_flags >> (7 - (bit - refresh_bit)) & 1;
		assert((data[bit >> 3] >> (7 - (bit & 7)) & 1) == expected);
	}
	submissions++;
	target->pending = !submit_error;
	return submit_error;
}

int dec_wait(struct context *c, struct surface *s, int timeout_ms)
{
	assert(s->ctx == c);
	assert(timeout_ms > 0);
	s->pending = 0;
	return wait_error;
}

static void setup(struct context *c)
{
	static struct drv d;
	static uint8_t tiles[] = {1, 0, 0, 0, 0};
	memset(c, 0, sizeof(*c));
	c->drv = &d;
	c->width = c->height = 64;
	c->tiles = tiles;
	c->tiles_len = sizeof(tiles);
	c->av1_ntiles = 1;
	VADecPictureParameterBufferAV1 *p = &c->av1;
	p->frame_width_minus1 = p->frame_height_minus1 = 63;
	p->seq_info_fields.fields.subsampling_x = 1;
	p->seq_info_fields.fields.subsampling_y = 1;
	p->seq_info_fields.fields.enable_order_hint = 1;
	p->pic_info_fields.bits.frame_type = 1;
	p->pic_info_fields.bits.uniform_tile_spacing_flag = 1;
	p->tile_cols = p->tile_rows = 1;
	p->current_frame = 9;
	p->order_hint = 9;
	p->order_hint_bits_minus_1 = 7;
	const uint8_t indices[7] = {3, 6, 4, 0, 7, 2, 1};
	memcpy(p->ref_frame_idx, indices, sizeof(indices));
	for (int i = 0; i < 8; i++) {
		c->av1_slot[i] = p->ref_frame_map[i] = i + 1;
		c->av1_refs[i].id = i + 1;
		c->av1_refs[i].order_hint = i;
		for (int j = 0; j < 8; j++)
			memcpy(c->av1_refs[i].gm[j], gm_default, sizeof(gm_default));
	}
	replay_surface = (struct surface){.ctx = c};
	replay_id = 9;
	submissions = 0;
	submit_error = wait_error = 0;
}

static uint8_t *build_deferred(struct context *c)
{
	uint8_t *frame = NULL;
	size_t n = av1_build(c, &frame);
	assert(n && frame);
	assert(c->av1_deferred.data);
	assert(c->av1_deferred.len == n);
	assert(c->av1_deferred.surface == 9);
	assert(!memcmp(frame, c->av1_deferred.data, n));
	for (int i = 0; i < 8; i++)
		assert(c->av1_slot[i] == (VASurfaceID)i + 1);
	original = frame;
	original_len = n;
	refresh_bit = c->av1_deferred.refresh_bit;
	assert(refresh_bit + 8 <= n * 8);
	for (size_t bit = refresh_bit; bit < refresh_bit + 8; bit++)
		assert(!(frame[bit >> 3] >> (7 - (bit & 7)) & 1));

	/* Even the source's hidden inter frame must produce a VA surface. */
	size_t at = 0;
	while (at < n) {
		unsigned type = frame[at++] >> 3 & 15;
		size_t size = 0;
		unsigned shift = 0, byte;
		do {
			assert(at < n && shift < 32);
			byte = frame[at++];
			size |= (size_t)(byte & 127) << shift;
			shift += 7;
		} while (byte & 128);
		assert(size <= n - at);
		if (type == 6) {
			assert(size && (frame[at] & 0x10));
			break;
		}
		at += size;
	}
	assert(at < n);
	return frame;
}

int main(void)
{
	struct context *c = malloc(sizeof(*c));
	assert(c);
	unsigned alignments = 0;
	for (int bits = 0; bits < 8; bits++)
		for (int slot = 0; slot < 8; slot++) {
			setup(c);
			c->av1.order_hint_bits_minus_1 = bits;
			uint8_t *frame = build_deferred(c);
			alignments |= 1u << (refresh_bit & 7);
			c->av1.ref_frame_map[slot] = 9;
			c->av1.current_frame = 10;
			refresh_flags = 1u << slot;
			assert(!av1_finish_refs(c));
			assert(submissions == 1 && !c->av1_deferred.data);
			for (int j = 0; j < 8; j++)
				assert(c->av1_slot[j] == (VASurfaceID)(j == slot ? 9 : j + 1));
			assert(!av1_finish_refs(c) && submissions == 1);
			free(frame);
		}
	assert(alignments == 0xff);

	setup(c);
	uint8_t *frame = build_deferred(c);
	assert(!av1_finish_refs(c));
	assert(!submissions && !c->av1_deferred.data);
	for (int i = 0; i < 8; i++)
		assert(c->av1_slot[i] == (VASurfaceID)i + 1);
	free(frame);

	for (int failure = 0; failure < 3; failure++) {
		setup(c);
		frame = build_deferred(c);
		c->av1.ref_frame_map[5] = 9;
		refresh_flags = 1u << 5;
		if (failure == 0)
			replay_id = VA_INVALID_ID;
		else if (failure == 1)
			submit_error = -1;
		else
			wait_error = -1;
		assert(av1_finish_refs(c) == -1 && !c->av1_deferred.data);
		assert(c->av1_slot[5] == 6);
		free(frame);
	}

	setup(c);
	c->av1.ref_frame_map[5] = VA_INVALID_ID;
	frame = NULL;
	assert(av1_build(c, &frame) && !c->av1_deferred.data);
	assert(c->av1_slot[5] == 9 && c->av1_slot[0] == 1);
	free(frame);

	setup(c);
	c->av1_slot[5] = c->av1_slot[0];
	assert(free_slot(c, c->av1.ref_frame_map) == 5);
	c->av1_slot[5] = 0;
	assert(free_slot(c, c->av1.ref_frame_map) == 5);

	setup(c);
	c->av1.ref_frame_idx[0] = 8;
	frame = NULL;
	assert(!av1_build(c, &frame) && !frame);
	setup(c);
	c->av1.ref_frame_map[0] = 99;
	assert(!av1_build(c, &frame) && !frame);
	setup(c);
	c->av1.pic_info_fields.bits.frame_type = 0;
	assert(!av1_build(c, &frame) && !frame);

	setup(c);
	for (unsigned id = 100; id < 200; id++) {
		c->av1.current_frame = id;
		assert(!ref_save(c, 0));
		assert(ref_find(c, id));
		for (unsigned live = 1; live <= 8; live++) {
			struct av1_ref *r = ref_find(c, live);
			assert(r && r->order_hint == live - 1);
			assert(!memcmp(r->gm[0], gm_default, sizeof(gm_default)));
		}
	}
	free(c);
	puts("AV1 reference tests passed");
	return 0;
}
