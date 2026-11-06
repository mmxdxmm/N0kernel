#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <asm/unaligned.h>
#include <linux/types.h>
#include <asm/neon.h>

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wbuiltin-macro-redefined"

#undef __INT64_TYPE__
#define __INT64_TYPE__ long long
#undef __UINT64_TYPE__
#define __UINT64_TYPE__ unsigned long long

#undef __SIZE_MAX__
#define __SIZE_MAX__ (~(size_t)0)
#undef __UINTPTR_MAX__
#define __UINTPTR_MAX__ ULONG_MAX

#include <arm_neon.h>
#pragma GCC diagnostic pop

#include "backend_zmako_h.h"

#define DICT_SIZE 512

#define WKDM_HASH(w) ((((u64)(w) * 0x9E3779B185EBCA87ULL) >> 57) & 0x7F)

struct zmako_h_ctx {
	u64 dict[DICT_SIZE];
};

static const u8 zmako_h_perm_tables[16][16] = {
	{255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{17, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{8, 9, 10, 11, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{8, 9, 10, 11, 12, 13, 14, 15, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 17, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 8, 9, 10, 11, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 8, 9, 10, 11, 12, 13, 14, 15, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 17, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 8, 9, 10, 11, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 8, 9, 10, 11, 12, 13, 14, 15, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 17, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
};

static const u8 zmako_h_unperm_tables[16][16] = {
	{255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{255, 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255},
	{255, 255, 255, 255, 255, 255, 255, 255, 0, 1, 2, 3, 255, 255, 255, 255},
	{255, 255, 255, 255, 255, 255, 255, 255, 0, 1, 2, 3, 4, 5, 6, 7},
	{0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 255, 255, 255, 255, 255, 255, 255, 1, 255, 255, 255, 255, 255, 255, 255},
	{0, 255, 255, 255, 255, 255, 255, 255, 1, 2, 3, 4, 255, 255, 255, 255},
	{0, 255, 255, 255, 255, 255, 255, 255, 1, 2, 3, 4, 5, 6, 7, 8},
	{0, 1, 2, 3, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 255, 255, 255, 255, 4, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 255, 255, 255, 255, 4, 5, 6, 7, 255, 255, 255, 255},
	{0, 1, 2, 3, 255, 255, 255, 255, 4, 5, 6, 7, 8, 9, 10, 11},
	{0, 1, 2, 3, 4, 5, 6, 7, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
};

static const u8 zmako_h_length_tables[16] = {
	0, 1, 4, 8, 1, 2, 5, 9, 4, 5, 8, 12, 8, 9, 12, 16
};

static void zmako_h_release_params(struct zcomp_params *params) {}
static int zmako_h_setup_params(struct zcomp_params *params) { return 0; }

static void zmako_h_destroy(struct zcomp_ctx *ctx) 
{
	kfree(ctx->context);
	ctx->context = NULL;
}

static int zmako_h_create(struct zcomp_params *params, struct zcomp_ctx *ctx)
{
	struct zmako_h_ctx *zctx;
	zctx = kzalloc(sizeof(*zctx), GFP_KERNEL);
	if (!zctx)
		return -ENOMEM;
	ctx->context = zctx;
	return 0;
}

static int zmako_h_compress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			  struct zcomp_req *req)
{
	struct zmako_h_ctx *zctx = ctx->context;
	u64 *dict = zctx->dict;
	
	memset(dict, 0, sizeof(u64) * DICT_SIZE);

	const u64 *src_words = (const u64 *)req->src;
	int words_per_page = PAGE_SIZE / 8;
	int tag_area_size = words_per_page * 2 / 8;

	u64 *tags_out = (u64 *)req->dst;
	u8 *payload_base = req->dst + tag_area_size;
	u32 payload_offset = 0;

	kernel_neon_begin();
	
	for (int i = 0; i < words_per_page; i += 32) {
		u64 current_tags = 0;

		for (int j = 0; j < 32; j += 4) {
			int idx = i + j;
			
			__builtin_prefetch(&src_words[idx + 16], 0, 1);
			__builtin_prefetch(payload_base + payload_offset + 128, 1, 1);

			u64 w0 = src_words[idx];
			u64 w1 = src_words[idx+1];
			u64 w2 = src_words[idx+2];
			u64 w3 = src_words[idx+3];

			u8 h0 = WKDM_HASH(w0);
			u8 h1 = WKDM_HASH(w1);
			u8 h2 = WKDM_HASH(w2);
			u8 h3 = WKDM_HASH(w3);

			u32 z0 = (w0 == 0); u32 z1 = (w1 == 0); u32 z2 = (w2 == 0); u32 z3 = (w3 == 0);

			u16 i0_1 = h0 | (z0 << 8); u16 i0_2 = (h0 | 128) | (z0 << 8);
			u16 i1_1 = h1 | (z1 << 8); u16 i1_2 = (h1 | 128) | (z1 << 8);
			u16 i2_1 = h2 | (z2 << 8); u16 i2_2 = (h2 | 128) | (z2 << 8);
			u16 i3_1 = h3 | (z3 << 8); u16 i3_2 = (h3 | 128) | (z3 << 8);

			u64 d0_1 = dict[i0_1]; u64 d0_2 = dict[i0_2];
			u64 d1_1 = dict[i1_1]; u64 d1_2 = dict[i1_2];
			u64 d2_1 = dict[i2_1]; u64 d2_2 = dict[i2_2];
			u64 d3_1 = dict[i3_1]; u64 d3_2 = dict[i3_2];

			bool m0_1 = (d0_1 == w0); bool m0_2 = (d0_2 == w0);
			bool m1_1 = (d1_1 == w1); bool m1_2 = (d1_2 == w1);
			bool m2_1 = (d2_1 == w2); bool m2_2 = (d2_2 == w2);
			bool m3_1 = (d3_1 == w3); bool m3_2 = (d3_2 == w3);

			u8 s0 = z0 ? 0 : ((m0_1 | m0_2) ? 1 : ((w0 <= 0xFFFFFFFFULL) ? 2 : 3));
			u8 s1 = z1 ? 0 : ((m1_1 | m1_2) ? 1 : ((w1 <= 0xFFFFFFFFULL) ? 2 : 3));
			u8 s2 = z2 ? 0 : ((m2_1 | m2_2) ? 1 : ((w2 <= 0xFFFFFFFFULL) ? 2 : 3));
			u8 s3 = z3 ? 0 : ((m3_1 | m3_2) ? 1 : ((w3 <= 0xFFFFFFFFULL) ? 2 : 3));

			u8 p0 = m0_2 ? (h0 | 128) : h0;
			u8 p1 = m1_2 ? (h1 | 128) : h1;
			u8 p2 = m2_2 ? (h2 | 128) : h2;
			u8 p3 = m3_2 ? (h3 | 128) : h3;

			dict[i0_2] = m0_1 ? d0_2 : d0_1; dict[i0_1] = w0;
			dict[i1_2] = m1_1 ? d1_2 : d1_1; dict[i1_1] = w1;
			dict[i2_2] = m2_1 ? d2_2 : d2_1; dict[i2_1] = w2;
			dict[i3_2] = m3_1 ? d3_2 : d3_1; dict[i3_1] = w3;

			u8 cs01 = (s0 << 2) | s1;
			uint64x2_t w64_01 = vsetq_lane_u64(w0, vdupq_n_u64(0), 0);
			w64_01 = vsetq_lane_u64(w1, w64_01, 1);

			uint8x16x2_t tab01 = { vreinterpretq_u8_u64(w64_01), vreinterpretq_u8_u16(vdupq_n_u16(p0 | ((u16)p1 << 8))) };
			vst1q_u8(payload_base + payload_offset, vqtbl2q_u8(tab01, vld1q_u8(zmako_h_perm_tables[cs01])));
			payload_offset += zmako_h_length_tables[cs01];

			u8 cs23 = (s2 << 2) | s3;
			uint64x2_t w64_23 = vsetq_lane_u64(w2, vdupq_n_u64(0), 0);
			w64_23 = vsetq_lane_u64(w3, w64_23, 1);
			uint8x16x2_t tab23 = { vreinterpretq_u8_u64(w64_23), vreinterpretq_u8_u16(vdupq_n_u16(p2 | ((u16)p3 << 8))) };
			vst1q_u8(payload_base + payload_offset, vqtbl2q_u8(tab23, vld1q_u8(zmako_h_perm_tables[cs23])));
			payload_offset += zmako_h_length_tables[cs23];

			current_tags |= ((u64)s0 << (j * 2)) | ((u64)s1 << (j * 2 + 2)) | 
			                ((u64)s2 << (j * 2 + 4)) | ((u64)s3 << (j * 2 + 6));
		}
		
		*tags_out++ = current_tags;
	}
	kernel_neon_end();

	put_unaligned(0ULL, (u64 *)(payload_base + payload_offset));
	put_unaligned(0ULL, (u64 *)(payload_base + payload_offset + 8));
	
	u32 final_size = tag_area_size + payload_offset + 16;
	req->dst_len = final_size;
	return -(int)(final_size >= PAGE_SIZE);
}

static int zmako_h_decompress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			    struct zcomp_req *req)
{
	struct zmako_h_ctx *zctx = ctx->context;
	u64 *dict = zctx->dict;
	
	memset(dict, 0, sizeof(u64) * DICT_SIZE);

	u64 *dst_words = (u64 *)req->dst;
	int words_per_page = PAGE_SIZE / 8;
	int tag_area_size = words_per_page * 2 / 8;

	const u64 *tags_in = (const u64 *)req->src;
	const u8 *payload = req->src + tag_area_size;

	kernel_neon_begin();
	
	for (int i = 0; i < words_per_page; i += 32) {
		u64 current_tags = *tags_in++;

		for (int j = 0; j < 32; j += 4) {
			int idx = i + j;
			
			__builtin_prefetch(payload + 64, 0, 1);
			__builtin_prefetch(dst_words + idx + 16, 1, 1);

			u8 s0 = (current_tags >> (j * 2)) & 0x03;
			u8 s1 = (current_tags >> (j * 2 + 2)) & 0x03;
			u8 s2 = (current_tags >> (j * 2 + 4)) & 0x03;
			u8 s3 = (current_tags >> (j * 2 + 6)) & 0x03;

			u8 cs01 = (s0 << 2) | s1;
			uint8x16_t unpacked01 = vqtbl1q_u8(vld1q_u8(payload), vld1q_u8(zmako_h_unperm_tables[cs01]));
			payload += zmako_h_length_tables[cs01];
			uint64x2_t u64_01 = vreinterpretq_u64_u8(unpacked01);
			u64 w0_raw = vgetq_lane_u64(u64_01, 0);
			u64 w1_raw = vgetq_lane_u64(u64_01, 1);

			u8 cs23 = (s2 << 2) | s3;
			uint8x16_t unpacked23 = vqtbl1q_u8(vld1q_u8(payload), vld1q_u8(zmako_h_unperm_tables[cs23]));
			payload += zmako_h_length_tables[cs23];
			uint64x2_t u64_23 = vreinterpretq_u64_u8(unpacked23);
			u64 w2_raw = vgetq_lane_u64(u64_23, 0);
			u64 w3_raw = vgetq_lane_u64(u64_23, 1);

			u64 out0 = (s0 == 3) ? w0_raw : ((s0 == 2) ? (u32)w0_raw : ((s0 == 1) ? dict[w0_raw & 0xFF] : 0));
			u64 out1 = (s1 == 3) ? w1_raw : ((s1 == 2) ? (u32)w1_raw : ((s1 == 1) ? dict[w1_raw & 0xFF] : 0));
			u64 out2 = (s2 == 3) ? w2_raw : ((s2 == 2) ? (u32)w2_raw : ((s2 == 1) ? dict[w2_raw & 0xFF] : 0));
			u64 out3 = (s3 == 3) ? w3_raw : ((s3 == 2) ? (u32)w3_raw : ((s3 == 1) ? dict[w3_raw & 0xFF] : 0));

			dst_words[idx] = out0;
			dst_words[idx+1] = out1;
			dst_words[idx+2] = out2;
			dst_words[idx+3] = out3;

			u32 z0 = (s0 == 0); u8 h0 = WKDM_HASH(out0);
			u32 z1 = (s1 == 0); u8 h1 = WKDM_HASH(out1);
			u32 z2 = (s2 == 0); u8 h2 = WKDM_HASH(out2);
			u32 z3 = (s3 == 0); u8 h3 = WKDM_HASH(out3);

			u16 i0_1 = h0 | (z0 << 8); u16 i0_2 = (h0 | 128) | (z0 << 8);
			u16 i1_1 = h1 | (z1 << 8); u16 i1_2 = (h1 | 128) | (z1 << 8);
			u16 i2_1 = h2 | (z2 << 8); u16 i2_2 = (h2 | 128) | (z2 << 8);
			u16 i3_1 = h3 | (z3 << 8); u16 i3_2 = (h3 | 128) | (z3 << 8);

			u64 d0_1 = dict[i0_1]; u64 d0_2 = dict[i0_2];
			u64 d1_1 = dict[i1_1]; u64 d1_2 = dict[i1_2];
			u64 d2_1 = dict[i2_1]; u64 d2_2 = dict[i2_2];
			u64 d3_1 = dict[i3_1]; u64 d3_2 = dict[i3_2];

			bool m0_1 = (d0_1 == out0);
			bool m1_1 = (d1_1 == out1);
			bool m2_1 = (d2_1 == out2);
			bool m3_1 = (d3_1 == out3);

			dict[i0_2] = m0_1 ? d0_2 : d0_1; dict[i0_1] = out0;
			dict[i1_2] = m1_1 ? d1_2 : d1_1; dict[i1_1] = out1;
			dict[i2_2] = m2_1 ? d2_2 : d2_1; dict[i2_1] = out2;
			dict[i3_2] = m3_1 ? d3_2 : d3_1; dict[i3_1] = out3;
		}
	}
	kernel_neon_end();

	return 0;
}

const struct zcomp_ops backend_zmako_h = {
	.compress	= zmako_h_compress,
	.decompress	= zmako_h_decompress,
	.create_ctx	= zmako_h_create,
	.destroy_ctx	= zmako_h_destroy,
	.setup_params	= zmako_h_setup_params,
	.release_params	= zmako_h_release_params,
	.name		= "zmako_h",
};
