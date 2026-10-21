/*
 * AV1: put the OBU stream back together from VA-API's parsed picture.
 *
 * VA-API gives a driver the decoded syntax elements of the frame header and
 * only the tile data of the frame. The V4L2 stateful decoder wants OBUs, so
 * the sequence header and the frame header are written again from those
 * fields (spec section 5.5 and 5.9), followed by the tiles.
 *
 * The header also says which reference slots the frame replaces
 * (refresh_frame_flags), which VA-API doesn't pass on. Guessing it from the
 * stream goes wrong for encoders that rotate slots, so the decoder gets its
 * own slot numbering instead: each frame is stored in a slot of our choosing
 * and ref_frame_idx is written to point at the slots holding the surfaces
 * the client says it references. The client's real slot numbers are never
 * needed. If all eight slots are live, decode without refreshing any slot.
 * The next picture's map tells us whether to retain that frame and which old
 * slot is now free; only then replay it with that slot's refresh bit set.
 *
 * The sequence-level switches that don't change how the tiles parse (screen
 * content tools, superres, restoration, ...) are enabled, and the frame
 * header then says what the frame really uses.
 */
#include <stdlib.h>
#include <string.h>

#include "common.h"

struct bw {
	uint8_t *p;
	size_t cap, bits;
	int err;
};

static void put(struct bw *w, uint32_t v, int n)
{
	for (int i = n - 1; i >= 0; i--) {
		if ((w->bits >> 3) >= w->cap) {
			w->err = 1;
			return;
		}
		if (!(w->bits & 7))
			w->p[w->bits >> 3] = 0;
		w->p[w->bits >> 3] |= (uint8_t)(((v >> i) & 1) << (7 - (w->bits & 7)));
		w->bits++;
	}
}

static void put_su(struct bw *w, int v, int n)
{
	put(w, (uint32_t)v & ((1u << n) - 1), n);
}

static void align(struct bw *w)
{
	while (w->bits & 7)
		put(w, 0, 1);
}

static void trailing(struct bw *w)
{
	put(w, 1, 1);
	align(w);
}

/* ns(n): a value 0..n-1 in as few bits as fit. */
static void put_ns(struct bw *w, uint32_t n, uint32_t v)
{
	int b = 0;
	for (uint32_t t = n; t; t >>= 1)
		b++;
	uint32_t m = (1u << b) - n;
	if (v < m) {
		put(w, v, b - 1);
	} else {
		put(w, (v + m) >> 1, b - 1);
		put(w, (v + m) & 1, 1);
	}
}

static int tile_log2(uint32_t blk, uint32_t target)
{
	int k = 0;
	while ((blk << k) < target)
		k++;
	return k;
}

/* ---- global motion parameter coding (5.9.25 and 5.9.26) ---- */

static uint32_t recenter(uint32_t r, uint32_t x)
{
	if (x > 2 * r)
		return x;
	return x >= r ? (x - r) << 1 : ((r - x) << 1) - 1;
}

static void put_subexp(struct bw *w, uint32_t n, uint32_t v)
{
	int i = 0;
	uint32_t mk = 0;
	for (;;) {
		int b2 = i ? 3 + i - 1 : 3;
		uint32_t a = 1u << b2;
		if (n <= mk + 3 * a) {
			put_ns(w, n - mk, v - mk);
			return;
		}
		if (v >= mk + a) {
			put(w, 1, 1);
			i++;
			mk += a;
		} else {
			put(w, 0, 1);
			put(w, v - mk, b2);
			return;
		}
	}
}

static void put_signed_subexp(struct bw *w, int32_t low, int32_t high, int32_t r, int32_t x)
{
	uint32_t n = (uint32_t)(high - low), rr = (uint32_t)(r - low), xx = (uint32_t)(x - low);
	uint32_t v = (rr << 1) <= n ? recenter(rr, xx) : recenter(n - 1 - rr, n - 1 - xx);
	put_subexp(w, n, v);
}

static void put_gm_param(struct bw *w, int type, int hp, int idx, int32_t val, int32_t prev)
{
	int abs_bits = 12, prec_bits = 15;
	if (idx < 2) {
		if (type == 1) {
			abs_bits = 9 - !hp;
			prec_bits = 3 - !hp;
		} else {
			abs_bits = 12;
			prec_bits = 6;
		}
	}
	int diff = 16 - prec_bits;
	int32_t round = (idx % 3) == 2 ? 1 << 16 : 0;
	int32_t sub = (idx % 3) == 2 ? 1 << prec_bits : 0;
	int32_t mx = 1 << abs_bits;
	int32_t r = (prev >> diff) - sub;
	int32_t x = (val - round) >> diff;
	if (x < -mx)
		x = -mx;
	if (x > mx)
		x = mx;
	put_signed_subexp(w, -mx, mx + 1, r, x);
}

/* ---- reference bookkeeping ---- */

static int map_has(const VASurfaceID map[8], VASurfaceID id)
{
	if (!id || id == VA_INVALID_ID)
		return 0;
	for (int i = 0; i < 8; i++)
		if (map[i] == id)
			return 1;
	return 0;
}

static struct av1_ref *ref_find(struct context *c, VASurfaceID id)
{
	if (id == VA_INVALID_ID || !id)
		return NULL;
	for (unsigned i = 0; i < 16; i++)
		if (c->av1_refs[i].id == id)
			return &c->av1_refs[i];
	return NULL;
}

static const int32_t gm_default[6] = {0, 0, 1 << 16, 0, 0, 1 << 16};

static int ref_save(struct context *c, int intra)
{
	const VADecPictureParameterBufferAV1 *p = &c->av1;
	struct av1_ref *r = ref_find(c, p->current_frame);
	if (!r) {
		for (unsigned i = 0; i < 16; i++)
			if (!map_has(c->av1_slot, c->av1_refs[i].id)) {
				r = &c->av1_refs[i];
				break;
			}
		if (!r) {
			dbg(c->drv, "av1: no free reference metadata entry");
			return -1;
		}
		memset(r, 0, sizeof(*r));
	}
	r->id = p->current_frame;
	r->order_hint = p->order_hint;
	for (int i = 0; i < 8; i++)
		memcpy(r->gm[i], gm_default, sizeof(gm_default));
	if (!intra)
		for (int i = 0; i < 7; i++)
			if (p->wm[i].wmtype)
				for (int j = 0; j < 6; j++)
					r->gm[i + 1][j] = p->wm[i].wmmat[j];
	return 0;
}

static int rel_dist(const VADecPictureParameterBufferAV1 *p, int a, int b)
{
	if (!p->seq_info_fields.fields.enable_order_hint)
		return 0;
	int bits = p->order_hint_bits_minus_1 + 1;
	int diff = a - b, m = 1 << (bits - 1);
	return (diff & (m - 1)) - (diff & m);
}

/* ---- sequence header (5.5) ---- */

static size_t write_seq(const struct context *c, uint8_t *out, size_t cap)
{
	const VADecPictureParameterBufferAV1 *p = &c->av1;
	uint32_t w = p->frame_width_minus1 + 1u, h = p->frame_height_minus1 + 1u;
	if (c->width > w)
		w = c->width;
	if (c->height > h)
		h = c->height;
	uint32_t px = w * h;
	int level = px <= 2359296 ? 9 : px <= 8912896 ? 13 : 17;
	struct bw b = {.p = out, .cap = cap};
	const typeof(p->seq_info_fields.fields) *f = &p->seq_info_fields.fields;
	int mono = f->mono_chrome;

	put(&b, p->profile, 3);
	put(&b, f->still_picture, 1);
	put(&b, 0, 1);                       /* reduced_still_picture_header */
	put(&b, 0, 1);                       /* timing_info_present_flag */
	put(&b, 0, 1);                       /* initial_display_delay_present_flag */
	put(&b, 0, 5);                       /* operating_points_cnt_minus_1 */
	put(&b, 0, 12);                      /* operating_point_idc */
	put(&b, level, 5);
	put(&b, 0, 1);                       /* seq_tier */
	put(&b, 15, 4);
	put(&b, 15, 4);
	put(&b, w - 1, 16);
	put(&b, h - 1, 16);
	put(&b, 0, 1);                       /* frame_id_numbers_present_flag */
	put(&b, f->use_128x128_superblock, 1);
	put(&b, f->enable_filter_intra, 1);
	put(&b, f->enable_intra_edge_filter, 1);
	put(&b, f->enable_interintra_compound, 1);
	put(&b, f->enable_masked_compound, 1);
	put(&b, 1, 1);                       /* enable_warped_motion */
	put(&b, f->enable_dual_filter, 1);
	put(&b, f->enable_order_hint, 1);
	if (f->enable_order_hint) {
		put(&b, f->enable_jnt_comp, 1);
		put(&b, 1, 1);               /* enable_ref_frame_mvs */
	}
	put(&b, 1, 1);                       /* seq_choose_screen_content_tools */
	put(&b, 1, 1);                       /* seq_choose_integer_mv */
	if (f->enable_order_hint)
		put(&b, p->order_hint_bits_minus_1, 3);
	put(&b, 1, 1);                       /* enable_superres */
	put(&b, f->enable_cdef, 1);
	put(&b, 1, 1);                       /* enable_restoration */
	/* color_config */
	put(&b, p->bit_depth_idx >= 1, 1);
	if (p->profile != 1)
		put(&b, mono, 1);
	put(&b, 1, 1);                       /* color_description_present_flag */
	put(&b, 2, 8);                       /* primaries: unspecified */
	put(&b, 2, 8);                       /* transfer: unspecified */
	put(&b, p->matrix_coefficients, 8);
	put(&b, f->color_range, 1);
	if (!mono) {
		if (f->subsampling_x && f->subsampling_y)
			put(&b, 0, 2);       /* chroma_sample_position */
		put(&b, 1, 1);               /* separate_uv_delta_q */
	}
	put(&b, f->film_grain_params_present, 1);
	trailing(&b);
	return b.err ? 0 : b.bits >> 3;
}

/* ---- frame header (5.9) ---- */

static size_t write_frame(struct context *c, uint8_t *out, size_t cap, uint32_t flags,
			  const uint8_t *ridx, int *ntiles, size_t *refresh_bit)
{
	const VADecPictureParameterBufferAV1 *p = &c->av1;
	const typeof(p->seq_info_fields.fields) *sq = &p->seq_info_fields.fields;
	const typeof(p->pic_info_fields.bits) *pi = &p->pic_info_fields.bits;
	struct bw b = {.p = out, .cap = cap};
	/* VA clients handle presentation; hidden references also need a surface. */
	int ft = pi->frame_type, show = 1;
	int intra = ft == 0 || ft == 2;
	int oh = sq->enable_order_hint, ohb = oh ? p->order_hint_bits_minus_1 + 1 : 0;
	int mono = sq->mono_chrome, nplanes = mono ? 1 : 3;
	int err_res = (ft == 3 || (ft == 0 && show)) ? 1 : pi->error_resilient_mode;
	int primary = (intra || err_res) ? 7 : p->primary_ref_frame;
	int sct = pi->allow_screen_content_tools;
	uint32_t uw = p->frame_width_minus1 + 1u, fh = p->frame_height_minus1 + 1u;
	int denom = pi->use_superres ? p->superres_scale_denominator : 8;
	uint32_t fw = pi->use_superres ? (uw * 8 + denom / 2) / denom : uw;
	uint32_t max_w = uw > c->width ? uw : c->width, max_h = fh > c->height ? fh : c->height;
	int size_override = ft == 3 || uw != max_w || fh != max_h;
	uint32_t mi_cols = 2 * ((fw + 7) >> 3), mi_rows = 2 * ((fh + 7) >> 3);

	put(&b, 0, 1);                       /* show_existing_frame */
	put(&b, ft, 2);
	put(&b, show, 1);
	if (!show)
		put(&b, pi->showable_frame, 1);
	if (!(ft == 3 || (ft == 0 && show)))
		put(&b, err_res, 1);
	put(&b, pi->disable_cdf_update, 1);
	put(&b, sct, 1);                     /* allow_screen_content_tools (seq says: select) */
	if (sct)
		put(&b, pi->force_integer_mv, 1);
	if (ft != 3)
		put(&b, size_override, 1);
	put(&b, p->order_hint, ohb);
	if (!(intra || err_res))
		put(&b, p->primary_ref_frame, 3);
	*refresh_bit = b.bits;
	put(&b, flags, ft == 3 || (ft == 0 && show) ? 0 : 8);
	if ((!intra || flags != 0xff) && err_res && oh)
		for (int i = 0; i < 8; i++) {
			struct av1_ref *r = ref_find(c, c->av1_slot[i]);
			put(&b, r ? r->order_hint : 0, ohb);
		}

	/* frame_size() and render_size() */
	#define FRAME_SIZE() do { \
		if (size_override) { put(&b, uw - 1, 16); put(&b, fh - 1, 16); } \
		put(&b, pi->use_superres, 1); \
		if (pi->use_superres) put(&b, denom - 9, 3); \
		put(&b, 0, 1); \
	} while (0)

	if (intra) {
		FRAME_SIZE();
		if (sct && uw == fw)
			put(&b, pi->allow_intrabc, 1);
	} else {
		if (oh)
			put(&b, 0, 1);       /* frame_refs_short_signaling */
		for (int i = 0; i < 7; i++)
			put(&b, ridx[i], 3);
		if (size_override && !err_res)
			for (int i = 0; i < 7; i++)
				put(&b, 0, 1);   /* found_ref */
		FRAME_SIZE();
		if (!(sct && pi->force_integer_mv))
			put(&b, pi->allow_high_precision_mv, 1);
		put(&b, p->interp_filter == 4, 1);
		if (p->interp_filter != 4)
			put(&b, p->interp_filter, 2);
		put(&b, pi->is_motion_mode_switchable, 1);
		if (!err_res && oh)
			put(&b, pi->use_ref_frame_mvs, 1);
	}
	if (!pi->disable_cdf_update)
		put(&b, pi->disable_frame_end_update_cdf, 1);

	/* tile_info() */
	int sb128 = sq->use_128x128_superblock;
	uint32_t sb_cols = sb128 ? (mi_cols + 31) >> 5 : (mi_cols + 15) >> 4;
	uint32_t sb_rows = sb128 ? (mi_rows + 31) >> 5 : (mi_rows + 15) >> 4;
	int sb_size = (sb128 ? 5 : 4) + 2;
	uint32_t max_w_sb = 4096u >> sb_size, max_area_sb = (4096u * 2304u) >> (2 * sb_size);
	int min_cols_log2 = tile_log2(max_w_sb, sb_cols);
	int max_cols_log2 = tile_log2(1, sb_cols < 64 ? sb_cols : 64);
	int max_rows_log2 = tile_log2(1, sb_rows < 64 ? sb_rows : 64);
	int min_tiles_log2 = tile_log2(max_area_sb, sb_rows * sb_cols);
	if (min_tiles_log2 < min_cols_log2)
		min_tiles_log2 = min_cols_log2;
	int cols_log2 = 0, rows_log2 = 0;
	put(&b, pi->uniform_tile_spacing_flag, 1);
	if (pi->uniform_tile_spacing_flag) {
		/* find the log2 the client's tile counts came from */
		int cl = min_cols_log2;
		for (int l = min_cols_log2; l <= max_cols_log2; l++) {
			uint32_t tw = (sb_cols + (1u << l) - 1) >> l;
			if ((sb_cols + tw - 1) / tw == p->tile_cols &&
			    (!p->tile_cols || p->width_in_sbs_minus_1[0] + 1u == tw ||
			     p->tile_cols == 1)) {
				cl = l;
				break;
			}
		}
		cols_log2 = cl;
		for (int l = min_cols_log2; l < cl; l++)
			put(&b, 1, 1);
		if (cl < max_cols_log2)
			put(&b, 0, 1);
		int min_rows_log2 = min_tiles_log2 - cols_log2 > 0 ? min_tiles_log2 - cols_log2 : 0;
		int rl = min_rows_log2;
		for (int l = min_rows_log2; l <= max_rows_log2; l++) {
			uint32_t th = (sb_rows + (1u << l) - 1) >> l;
			if ((sb_rows + th - 1) / th == p->tile_rows) {
				rl = l;
				break;
			}
		}
		rows_log2 = rl;
		for (int l = min_rows_log2; l < rl; l++)
			put(&b, 1, 1);
		if (rl < max_rows_log2)
			put(&b, 0, 1);
	} else {
		uint32_t widest = 0, start = 0;
		for (unsigned i = 0; i < p->tile_cols && start < sb_cols; i++) {
			uint32_t mw = sb_cols - start < max_w_sb ? sb_cols - start : max_w_sb;
			uint32_t sz = p->width_in_sbs_minus_1[i] + 1u;
			put_ns(&b, mw, sz - 1);
			if (sz > widest)
				widest = sz;
			start += sz;
		}
		cols_log2 = tile_log2(1, p->tile_cols);
		uint32_t area = min_tiles_log2 > 0 ? (sb_rows * sb_cols) >> (min_tiles_log2 + 1) :
				sb_rows * sb_cols;
		uint32_t max_h_sb = widest ? area / widest : 1;
		if (max_h_sb < 1)
			max_h_sb = 1;
		start = 0;
		for (unsigned i = 0; i < p->tile_rows && start < sb_rows; i++) {
			uint32_t mh = sb_rows - start < max_h_sb ? sb_rows - start : max_h_sb;
			uint32_t sz = p->height_in_sbs_minus_1[i] + 1u;
			put_ns(&b, mh, sz - 1);
			start += sz;
		}
		rows_log2 = tile_log2(1, p->tile_rows);
	}
	if (cols_log2 || rows_log2) {
		put(&b, p->context_update_tile_id, cols_log2 + rows_log2);
		put(&b, 3, 2);               /* tile_size_bytes_minus_1: 4-byte tile sizes */
	}
	*ntiles = (int)(p->tile_cols * p->tile_rows);

	/* quantization_params() */
	put(&b, p->base_qindex, 8);
	#define DQ(v) do { put(&b, (v) != 0, 1); if (v) put_su(&b, v, 7); } while (0)
	DQ(p->y_dc_delta_q);
	if (nplanes > 1) {
		put(&b, 1, 1);               /* diff_uv_delta */
		DQ(p->u_dc_delta_q);
		DQ(p->u_ac_delta_q);
		DQ(p->v_dc_delta_q);
		DQ(p->v_ac_delta_q);
	}
	put(&b, p->qmatrix_fields.bits.using_qmatrix, 1);
	if (p->qmatrix_fields.bits.using_qmatrix) {
		put(&b, p->qmatrix_fields.bits.qm_y, 4);
		put(&b, p->qmatrix_fields.bits.qm_u, 4);
		put(&b, p->qmatrix_fields.bits.qm_v, 4);
	}

	/* segmentation_params(): data is always sent in full */
	const VASegmentationStructAV1 *sg = &p->seg_info;
	int seg = sg->segment_info_fields.bits.enabled;
	put(&b, seg, 1);
	if (seg) {
		if (primary != 7) {
			put(&b, sg->segment_info_fields.bits.update_map, 1);
			if (sg->segment_info_fields.bits.update_map)
				put(&b, sg->segment_info_fields.bits.temporal_update, 1);
			put(&b, 1, 1);       /* segmentation_update_data */
		}
		static const int bits[8] = {8, 6, 6, 6, 6, 3, 0, 0};
		static const int sgn[8] = {1, 1, 1, 1, 1, 0, 0, 0};
		static const int lim[8] = {255, 63, 63, 63, 63, 7, 0, 0};
		for (int i = 0; i < 8; i++)
			for (int j = 0; j < 8; j++) {
				int en = (sg->feature_mask[i] >> j) & 1;
				put(&b, en, 1);
				if (!en)
					continue;
				int v = sg->feature_data[i][j];
				if (v > lim[j])
					v = lim[j];
				if (v < (sgn[j] ? -lim[j] : 0))
					v = sgn[j] ? -lim[j] : 0;
				if (sgn[j])
					put_su(&b, v, 1 + bits[j]);
				else
					put(&b, v, bits[j]);
			}
	}

	/* lossless: decides which tools the header carries */
	int coded_lossless = 1;
	for (int i = 0; i < 8; i++) {
		int q = p->base_qindex;
		if (seg && ((sg->feature_mask[i] >> 0) & 1)) {
			q += sg->feature_data[i][0];
			q = q < 0 ? 0 : q > 255 ? 255 : q;
		}
		if (q || p->y_dc_delta_q || p->u_dc_delta_q || p->u_ac_delta_q ||
		    p->v_dc_delta_q || p->v_ac_delta_q)
			coded_lossless = 0;
	}
	int all_lossless = coded_lossless && fw == uw;
	const typeof(p->mode_control_fields.bits) *mc = &p->mode_control_fields.bits;

	/* delta_q_params() and delta_lf_params() */
	if (p->base_qindex > 0)
		put(&b, mc->delta_q_present_flag, 1);
	if (p->base_qindex > 0 && mc->delta_q_present_flag) {
		put(&b, mc->log2_delta_q_res, 2);
		if (!pi->allow_intrabc) {
			put(&b, mc->delta_lf_present_flag, 1);
			if (mc->delta_lf_present_flag) {
				put(&b, mc->log2_delta_lf_res, 2);
				put(&b, mc->delta_lf_multi, 1);
			}
		}
	}

	/* loop_filter_params(): deltas are always sent in full */
	if (!(coded_lossless || pi->allow_intrabc)) {
		put(&b, p->filter_level[0], 6);
		put(&b, p->filter_level[1], 6);
		if (nplanes > 1 && (p->filter_level[0] || p->filter_level[1])) {
			put(&b, p->filter_level_u, 6);
			put(&b, p->filter_level_v, 6);
		}
		put(&b, p->loop_filter_info_fields.bits.sharpness_level, 3);
		int de = p->loop_filter_info_fields.bits.mode_ref_delta_enabled;
		put(&b, de, 1);
		if (de) {
			put(&b, 1, 1);       /* loop_filter_delta_update */
			for (int i = 0; i < 8; i++) {
				put(&b, 1, 1);
				put_su(&b, p->ref_deltas[i], 7);
			}
			for (int i = 0; i < 2; i++) {
				put(&b, 1, 1);
				put_su(&b, p->mode_deltas[i], 7);
			}
		}
	}

	/* cdef_params() */
	if (!(coded_lossless || pi->allow_intrabc || !sq->enable_cdef)) {
		put(&b, p->cdef_damping_minus_3, 2);
		put(&b, p->cdef_bits, 2);
		for (int i = 0; i < (1 << p->cdef_bits); i++) {
			put(&b, p->cdef_y_strengths[i], 6);
			if (nplanes > 1)
				put(&b, p->cdef_uv_strengths[i], 6);
		}
	}

	/* lr_params(): VA's types are FrameRestorationType, the syntax is remapped */
	if (!(all_lossless || pi->allow_intrabc)) {
		static const int remap[4] = {0, 2, 3, 1};
		int types[3] = {p->loop_restoration_fields.bits.yframe_restoration_type,
				p->loop_restoration_fields.bits.cbframe_restoration_type,
				p->loop_restoration_fields.bits.crframe_restoration_type};
		int uses = 0, uses_chroma = 0;
		for (int i = 0; i < nplanes; i++) {
			put(&b, remap[types[i]], 2);
			if (types[i]) {
				uses = 1;
				if (i)
					uses_chroma = 1;
			}
		}
		if (uses) {
			int sh = p->loop_restoration_fields.bits.lr_unit_shift;
			if (sb128) {
				put(&b, sh > 1, 1);
			} else {
				put(&b, sh > 0, 1);
				if (sh > 0)
					put(&b, sh > 1, 1);
			}
			if (sq->subsampling_x && sq->subsampling_y && uses_chroma)
				put(&b, p->loop_restoration_fields.bits.lr_uv_shift, 1);
		}
	}

	if (!coded_lossless)
		put(&b, mc->tx_mode == 2, 1);    /* tx_mode_select */
	if (!intra)
		put(&b, mc->reference_select, 1);

	/* skip_mode_params() */
	if (!intra && mc->reference_select && oh) {
		int fwd = -1, bwd = -1, fh_ = 0, bh_ = 0, allowed;
		for (int i = 0; i < 7; i++) {
			struct av1_ref *r = ref_find(c, p->ref_frame_map[p->ref_frame_idx[i]]);
			int hint = r ? r->order_hint : 0;
			if (rel_dist(p, hint, p->order_hint) < 0) {
				if (fwd < 0 || rel_dist(p, hint, fh_) > 0) {
					fwd = i;
					fh_ = hint;
				}
			} else if (rel_dist(p, hint, p->order_hint) > 0) {
				if (bwd < 0 || rel_dist(p, hint, bh_) < 0) {
					bwd = i;
					bh_ = hint;
				}
			}
		}
		if (fwd < 0) {
			allowed = 0;
		} else if (bwd >= 0) {
			allowed = 1;
		} else {
			int sec = -1, sh_ = 0;
			for (int i = 0; i < 7; i++) {
				struct av1_ref *r = ref_find(c, p->ref_frame_map[p->ref_frame_idx[i]]);
				int hint = r ? r->order_hint : 0;
				if (rel_dist(p, hint, fh_) < 0 && (sec < 0 || rel_dist(p, hint, sh_) > 0)) {
					sec = i;
					sh_ = hint;
				}
			}
			allowed = sec >= 0;
		}
		if (allowed)
			put(&b, mc->skip_mode_present, 1);
	}

	if (!(intra || err_res))
		put(&b, pi->allow_warped_motion, 1);
	put(&b, mc->reduced_tx_set_used, 1);

	/* global_motion_params() */
	if (!intra) {
		const int32_t (*prev)[6] = NULL;
		if (primary != 7) {
			struct av1_ref *r = ref_find(c, p->ref_frame_map[p->ref_frame_idx[primary]]);
			if (r)
				prev = (const int32_t (*)[6])r->gm;
		}
		for (int i = 0; i < 7; i++) {
			const VAWarpedMotionParamsAV1 *wm = &p->wm[i];
			int type = wm->wmtype;
			put(&b, type != 0, 1);
			if (type) {
				put(&b, type == 2, 1);
				if (type != 2)
					put(&b, type == 1, 1);
			}
			const int32_t *pv = prev ? prev[i + 1] : gm_default;
			int hp = pi->allow_high_precision_mv;
			if (type >= 2) {
				put_gm_param(&b, type, hp, 2, wm->wmmat[2], pv[2]);
				put_gm_param(&b, type, hp, 3, wm->wmmat[3], pv[3]);
				if (type == 3) {
					put_gm_param(&b, type, hp, 4, wm->wmmat[4], pv[4]);
					put_gm_param(&b, type, hp, 5, wm->wmmat[5], pv[5]);
				}
			}
			if (type >= 1) {
				put_gm_param(&b, type, hp, 0, wm->wmmat[0], pv[0]);
				put_gm_param(&b, type, hp, 1, wm->wmmat[1], pv[1]);
			}
		}
	}

	/* film_grain_params(): always sent in full */
	if (sq->film_grain_params_present && (show || pi->showable_frame)) {
		const VAFilmGrainStructAV1 *g = &p->film_grain_info;
		const typeof(g->film_grain_info_fields.bits) *gb = &g->film_grain_info_fields.bits;
		put(&b, gb->apply_grain, 1);
		if (gb->apply_grain) {
			put(&b, g->grain_seed, 16);
			if (ft == 1)
				put(&b, 1, 1);       /* update_grain */
			put(&b, g->num_y_points, 4);
			for (int i = 0; i < g->num_y_points; i++) {
				put(&b, g->point_y_value[i], 8);
				put(&b, g->point_y_scaling[i], 8);
			}
			int csl = 0;
			if (!mono) {
				csl = gb->chroma_scaling_from_luma;
				put(&b, csl, 1);
			}
			int ncb = 0, ncr = 0;
			if (!(mono || csl || (sq->subsampling_x && sq->subsampling_y && !g->num_y_points))) {
				ncb = g->num_cb_points;
				ncr = g->num_cr_points;
				put(&b, ncb, 4);
				for (int i = 0; i < ncb; i++) {
					put(&b, g->point_cb_value[i], 8);
					put(&b, g->point_cb_scaling[i], 8);
				}
				put(&b, ncr, 4);
				for (int i = 0; i < ncr; i++) {
					put(&b, g->point_cr_value[i], 8);
					put(&b, g->point_cr_scaling[i], 8);
				}
			}
			put(&b, gb->grain_scaling_minus_8, 2);
			put(&b, gb->ar_coeff_lag, 2);
			int npl = 2 * gb->ar_coeff_lag * (gb->ar_coeff_lag + 1), npc = npl;
			if (g->num_y_points) {
				npc = npl + 1;
				for (int i = 0; i < npl; i++)
					put(&b, (uint8_t)(g->ar_coeffs_y[i] + 128), 8);
			}
			if (csl || ncb)
				for (int i = 0; i < npc; i++)
					put(&b, (uint8_t)(g->ar_coeffs_cb[i] + 128), 8);
			if (csl || ncr)
				for (int i = 0; i < npc; i++)
					put(&b, (uint8_t)(g->ar_coeffs_cr[i] + 128), 8);
			put(&b, gb->ar_coeff_shift_minus_6, 2);
			put(&b, gb->grain_scale_shift, 2);
			if (ncb) {
				put(&b, g->cb_mult, 8);
				put(&b, g->cb_luma_mult, 8);
				put(&b, g->cb_offset, 9);
			}
			if (ncr) {
				put(&b, g->cr_mult, 8);
				put(&b, g->cr_luma_mult, 8);
				put(&b, g->cr_offset, 9);
			}
			put(&b, gb->overlap_flag, 1);
			put(&b, gb->clip_to_restricted_range, 1);
		}
	}
	#undef FRAME_SIZE
	#undef DQ
	align(&b);
	if (*ntiles > 1)
		put(&b, 0, 8);               /* tile_start_and_end_present_flag, aligned */
	return b.err ? 0 : b.bits >> 3;
}

/* ---- tiles and the whole picture ---- */

int av1_add_tiles(struct context *c, const struct buffer *data)
{
	size_t total = (size_t)data->size * data->num;
	for (unsigned i = 0; i < c->av1_nslices; i++) {
		const VASliceParameterBufferAV1 *sp = &c->av1_slices[i];
		if ((size_t)sp->slice_data_offset + sp->slice_data_size > total)
			return -1;
		if (c->tiles_len + sp->slice_data_size + 4 > c->tiles_cap) {
			size_t cap = (c->tiles_len + sp->slice_data_size + 4) * 2;
			uint8_t *n = realloc(c->tiles, cap);
			if (!n)
				return -1;
			c->tiles = n;
			c->tiles_cap = cap;
		}
		uint32_t len = sp->slice_data_size;
		memcpy(c->tiles + c->tiles_len, &len, 4);
		memcpy(c->tiles + c->tiles_len + 4, data->data + sp->slice_data_offset, len);
		c->tiles_len += 4 + len;
		c->av1_ntiles++;
	}
	c->av1_nslices = 0;
	return 0;
}

static size_t obu(uint8_t *out, int type, const uint8_t *pl, size_t n)
{
	size_t o = 0;
	out[o++] = (uint8_t)(type << 3 | 2);
	size_t v = n;
	do {
		out[o] = v & 0x7f;
		v >>= 7;
		if (v)
			out[o] |= 0x80;
		o++;
	} while (v);
	memcpy(out + o, pl, n);
	return o + n;
}

static int free_slot(const struct context *c, const VASurfaceID map[8])
{
	for (int j = 0; j < 8; j++) {
		if (!map_has(map, c->av1_slot[j]))
			return j;
		for (int k = 0; k < j; k++)
			if (c->av1_slot[k] == c->av1_slot[j])
				return j;
	}
	return -1;
}

int av1_finish_refs(struct context *c)
{
	if (!c->av1_deferred.data)
		return 0;
	int ret = 0;
	VASurfaceID id = c->av1_deferred.surface;
	if (map_has(c->av1.ref_frame_map, id)) {
		int slot = free_slot(c, c->av1.ref_frame_map);
		struct surface *s = obj_get(c->drv, O_SURFACE, id);
		if (slot < 0 || !s || s->ctx != c ||
		    c->av1_deferred.refresh_bit + 8 > c->av1_deferred.len * 8) {
			dbg(c->drv, "av1: cannot retain deferred reference %u", id);
			ret = -1;
			goto done;
		}
		uint8_t flags = (uint8_t)(1u << slot);
		for (int i = 0; i < 8; i++) {
			size_t bit = c->av1_deferred.refresh_bit + i;
			uint8_t mask = (uint8_t)(1u << (7 - (bit & 7)));
			uint8_t *byte = &c->av1_deferred.data[bit >> 3];
			*byte = (uint8_t)((*byte & ~mask) |
				((flags >> (7 - i) & 1) ? mask : 0));
		}
		trace(c->drv, "av1: retaining deferred surface %u in slot %d", id, slot);
		if (dec_submit(c, c->av1_deferred.data, c->av1_deferred.len, s) ||
		    dec_wait(c, s, 1000)) {
			dbg(c->drv, "av1: deferred reference %u failed to decode", id);
			ret = -1;
			goto done;
		}
		c->av1_slot[slot] = id;
	}
done:
	free(c->av1_deferred.data);
	memset(&c->av1_deferred, 0, sizeof(c->av1_deferred));
	return ret;
}

size_t av1_build(struct context *c, uint8_t **out)
{
	const VADecPictureParameterBufferAV1 *p = &c->av1;
	int ft = p->pic_info_fields.bits.frame_type;
	int intra = ft == 0 || ft == 2;
	int key_all = ft == 3 || ft == 0;

	if (ft == 0 && !p->pic_info_fields.bits.show_frame) {
		dbg(c->drv, "av1: hidden key frames are not supported");
		return 0;
	}

	/* Slots: the client's surfaces keep their place, the new frame takes a free one. */
	for (int i = 0; i < 8; i++)
		if (c->av1_slot[i] == p->current_frame)
			c->av1_slot[i] = 0;          /* the client reused the surface */
	uint8_t ridx[7] = {0};
	if (!intra)
		for (int i = 0; i < 7; i++) {
			if (p->ref_frame_idx[i] >= 8) {
				dbg(c->drv, "av1: invalid reference index %u", p->ref_frame_idx[i]);
				return 0;
			}
			VASurfaceID s = p->ref_frame_map[p->ref_frame_idx[i]];
			int slot = -1;
			for (int j = 0; j < 8 && s && s != VA_INVALID_ID; j++)
				if (slot < 0 && c->av1_slot[j] == s)
					slot = j;
			if (slot < 0) {
				dbg(c->drv, "av1: reference %d (idx %d, surface %u cur %u) not decoded", i, p->ref_frame_idx[i], s, p->current_frame);
				return 0;
			}
			ridx[i] = (uint8_t)slot;
		}
	uint32_t flags = 0xff;
	if (!key_all) {
		int pick = free_slot(c, p->ref_frame_map);
		flags = pick < 0 ? 0 : 1u << pick;
	}

#ifdef AV1_TRACE
	dbg(c->drv, "cur %u ft %d source_show %d map %u %u %u %u %u %u %u %u idx %u %u %u %u %u %u %u | slots %u %u %u %u %u %u %u %u -> flags %02x ridx %d%d%d%d%d%d%d", p->current_frame, ft, p->pic_info_fields.bits.show_frame,
	    p->ref_frame_map[0], p->ref_frame_map[1], p->ref_frame_map[2], p->ref_frame_map[3], p->ref_frame_map[4], p->ref_frame_map[5], p->ref_frame_map[6], p->ref_frame_map[7],
	    p->ref_frame_idx[0], p->ref_frame_idx[1], p->ref_frame_idx[2], p->ref_frame_idx[3], p->ref_frame_idx[4], p->ref_frame_idx[5], p->ref_frame_idx[6],
	    c->av1_slot[0], c->av1_slot[1], c->av1_slot[2], c->av1_slot[3], c->av1_slot[4], c->av1_slot[5], c->av1_slot[6], c->av1_slot[7], flags,
	    ridx[0], ridx[1], ridx[2], ridx[3], ridx[4], ridx[5], ridx[6]);
#endif
	uint8_t seq[48], fh[1024];
	size_t sl = write_seq(c, seq, sizeof(seq));
	size_t refresh_bit = 0;
	int nt = 0;
	size_t fl = write_frame(c, fh, sizeof(fh), flags, ridx, &nt, &refresh_bit);
	if (!sl || !fl || nt != (int)c->av1_ntiles || !nt) {
		dbg(c->drv, "av1: can't write headers (seq %zu frame %zu tiles %d of %u)", sl, fl, nt,
		    c->av1_ntiles);
		return 0;
	}

	size_t total = 2 + 16 + sl + 16 + fl + c->tiles_len + 8 * c->av1_ntiles;
	uint8_t *o = malloc(total), *w = o;
	if (!o)
		return 0;
	*w++ = 0x12;                 /* one temporal unit per decoded VA surface */
	*w++ = 0;
	if (ft == 0 || (int)sl != c->av1_seq_len || memcmp(seq, c->av1_seq, sl)) {
		w += obu(w, 1, seq, sl);
		memcpy(c->av1_seq, seq, sl);
		c->av1_seq_len = (int)sl;
	}
	/* OBU_FRAME: header, then the tile group made of 4-byte-sized tiles */
	size_t cap = fl + c->tiles_len + 4;
	uint8_t *pl = malloc(cap);
	if (!pl) {
		free(o);
		return 0;
	}
	size_t n = 0;
	memcpy(pl, fh, fl);
	n = fl;
	const uint8_t *t = c->tiles;
	for (int i = 0; i < nt; i++) {
		uint32_t len;
		memcpy(&len, t, 4);
		if (i + 1 < nt) {
			uint32_t m = len - 1;
			memcpy(pl + n, &m, 4);       /* tile_size_minus_1, little endian */
			n += 4;
		}
		memcpy(pl + n, t + 4, len);
		n += len;
		t += 4 + len;
	}
	size_t frame_len = obu(w, 6, pl, n);
	refresh_bit += ((size_t)(w - o) + frame_len - n) * 8;
	w += frame_len;
	free(pl);

	if (!flags) {
		c->av1_deferred.len = (size_t)(w - o);
		c->av1_deferred.data = malloc(c->av1_deferred.len);
		if (!c->av1_deferred.data) {
			free(o);
			return 0;
		}
		memcpy(c->av1_deferred.data, o, c->av1_deferred.len);
		c->av1_deferred.refresh_bit = refresh_bit;
		c->av1_deferred.surface = p->current_frame;
	}
	for (int i = 0; i < 8; i++)
		if (flags >> i & 1)
			c->av1_slot[i] = p->current_frame;
	if (ref_save(c, intra)) {
		free(o);
		return 0;
	}
	*out = o;
	return (size_t)(w - o);
}
