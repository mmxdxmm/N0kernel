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

#include "backend_zmako.h"

#define DICT_SIZE 64
#define DICT_MASK 0x3F

#define WKDM_HASH(w) (((((w) >> 16) * 0x2545F4914F6CDD1DULL) >> 58) & DICT_MASK)

static const u8 payload_step[4] = {0, 1, 3, 8};

static const u8 zmako_perm_tables[16][16] = {
	{255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{17, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{17, 8, 9, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{8, 9, 10, 11, 12, 13, 14, 15, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 17, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 17, 8, 9, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 8, 9, 10, 11, 12, 13, 14, 15, 255, 255, 255, 255, 255, 255, 255},
	{16, 0, 1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 0, 1, 17, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 0, 1, 17, 8, 9, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{16, 0, 1, 8, 9, 10, 11, 12, 13, 14, 15, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 17, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 17, 8, 9, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
};

static const u8 zmako_unperm_tables[16][16] = {
	{255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{255, 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255},
	{255, 255, 255, 255, 255, 255, 255, 255, 0, 1, 2, 255, 255, 255, 255, 255},
	{255, 255, 255, 255, 255, 255, 255, 255, 0, 1, 2, 3, 4, 5, 6, 7},
	{0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 255, 255, 255, 255, 255, 255, 255, 1, 255, 255, 255, 255, 255, 255, 255},
	{0, 255, 255, 255, 255, 255, 255, 255, 1, 2, 3, 255, 255, 255, 255, 255},
	{0, 255, 255, 255, 255, 255, 255, 255, 1, 2, 3, 4, 5, 6, 7, 8},
	{0, 1, 2, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 255, 255, 255, 255, 255, 3, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 255, 255, 255, 255, 255, 3, 4, 5, 255, 255, 255, 255, 255},
	{0, 1, 2, 255, 255, 255, 255, 255, 3, 4, 5, 6, 7, 8, 9, 10},
	{0, 1, 2, 3, 4, 5, 6, 7, 255, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 255, 255, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 255, 255, 255, 255, 255},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
};

static const u8 zmako_length_tables[16] = {
	0, 1, 3, 8, 1, 2, 4, 9, 3, 4, 6, 11, 8, 9, 11, 16
};

static void zmako_release_params(struct zcomp_params *params) {}
static int zmako_setup_params(struct zcomp_params *params) { return 0; }
static void zmako_destroy(struct zcomp_ctx *ctx) {}

static int zmako_create(struct zcomp_params *params, struct zcomp_ctx *ctx)
{
	ctx->context = NULL;
	return 0;
}

static int zmako_compress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			  struct zcomp_req *req)
{
	const u64 *src_words = (const u64 *)req->src;
	int words_per_page = PAGE_SIZE / 8;
	int tag_area_size = words_per_page * 2 / 8;

	u64 *tags_out = (u64 *)req->dst;
	u8 *payload_base = req->dst + tag_area_size;

	u32 payload_offset = 0;
	u64 dict[65] = {0};

	kernel_neon_begin();
	for (int i = 0; i < words_per_page; i += 32) {
		u64 current_tags = 0;
		for (int j = 0; j < 32; j += 4) {
			__builtin_prefetch(&src_words[i + j + 16], 0, 0);

			uint64x2_t w01 = vld1q_u64((const unsigned long *)&src_words[i + j]);
			uint64x2_t w23 = vld1q_u64((const unsigned long *)&src_words[i + j + 2]);

			u64 w0 = vgetq_lane_u64(w01, 0);
			u64 w1 = vgetq_lane_u64(w01, 1);
			u64 w2 = vgetq_lane_u64(w23, 0);
			u64 w3 = vgetq_lane_u64(w23, 1);

			u8 h0 = WKDM_HASH(w0);
			u64 d0 = dict[h0];
			u8 s0 = (w0 == 0) ? 0 : ((d0 == w0) ? 1 : ((((w0 ^ d0) >> 16) == 0) ? 2 : 3));
			dict[h0 | ((w0 == 0) << 6)] = w0; 

			u8 h1 = WKDM_HASH(w1);
			u64 d1 = dict[h1];
			u8 s1 = (w1 == 0) ? 0 : ((d1 == w1) ? 1 : ((((w1 ^ d1) >> 16) == 0) ? 2 : 3));
			dict[h1 | ((w1 == 0) << 6)] = w1;

			u8 h2 = WKDM_HASH(w2);
			u64 d2 = dict[h2];
			u8 s2 = (w2 == 0) ? 0 : ((d2 == w2) ? 1 : ((((w2 ^ d2) >> 16) == 0) ? 2 : 3));
			dict[h2 | ((w2 == 0) << 6)] = w2;

			u8 h3 = WKDM_HASH(w3);
			u64 d3 = dict[h3];
			u8 s3 = (w3 == 0) ? 0 : ((d3 == w3) ? 1 : ((((w3 ^ d3) >> 16) == 0) ? 2 : 3));
			dict[h3 | ((w3 == 0) << 6)] = w3;

			u8 cs01 = (s0 << 2) | s1;
			u8 cs23 = (s2 << 2) | s3;

			current_tags |= ((u64)s0 << (j * 2));
			current_tags |= ((u64)s1 << (j * 2 + 2));
			current_tags |= ((u64)s2 << (j * 2 + 4));
			current_tags |= ((u64)s3 << (j * 2 + 6));

			uint8x16_t perm01 = vld1q_u8(zmako_perm_tables[cs01]);
			uint8x16_t perm23 = vld1q_u8(zmako_perm_tables[cs23]);

			uint8x16_t words_reg01 = vreinterpretq_u8_u64(w01);
			uint8x16_t words_reg23 = vreinterpretq_u8_u64(w23);

			uint16_t hashes01 = h0 | ((u16)h1 << 8);
			uint16_t hashes23 = h2 | ((u16)h3 << 8);

			uint8x16_t hash_reg01 = vreinterpretq_u8_u16(vdupq_n_u16(hashes01));
			uint8x16_t hash_reg23 = vreinterpretq_u8_u16(vdupq_n_u16(hashes23));

			uint8x16x2_t table01 = { words_reg01, hash_reg01 };
			uint8x16x2_t table23 = { words_reg23, hash_reg23 };

			uint8x16_t packed01 = vqtbl2q_u8(table01, perm01);
			vst1q_u8(payload_base + payload_offset, packed01);
			payload_offset += zmako_length_tables[cs01];

			uint8x16_t packed23 = vqtbl2q_u8(table23, perm23);
			vst1q_u8(payload_base + payload_offset, packed23);
			payload_offset += zmako_length_tables[cs23];
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

static int zmako_decompress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			    struct zcomp_req *req)
{
	u64 *dst_words = (u64 *)req->dst;
	int words_per_page = PAGE_SIZE / 8;
	int tag_area_size = words_per_page * 2 / 8;

	const u64 *tags_in = (const u64 *)req->src;
	const u8 *payload = req->src + tag_area_size;

	u64 dict[65] = {0};

	kernel_neon_begin();
	for (int i = 0; i < words_per_page; i += 32) {
		u64 current_tags = *tags_in++;
		for (int j = 0; j < 32; j += 4) {
			__builtin_prefetch(payload + 64, 0, 0);

			u8 s0 = (current_tags >> (j * 2)) & 3;
			u8 s1 = (current_tags >> (j * 2 + 2)) & 3;
			u8 s2 = (current_tags >> (j * 2 + 4)) & 3;
			u8 s3 = (current_tags >> (j * 2 + 6)) & 3;
			
			u8 cs01 = (s0 << 2) | s1;
			u8 cs23 = (s2 << 2) | s3;

			uint8x16_t packed01 = vld1q_u8(payload);
			uint8x16_t unpacked01 = vqtbl1q_u8(packed01, vld1q_u8(zmako_unperm_tables[cs01]));
			payload += zmako_length_tables[cs01];

			uint8x16_t packed23 = vld1q_u8(payload);
			uint8x16_t unpacked23 = vqtbl1q_u8(packed23, vld1q_u8(zmako_unperm_tables[cs23]));
			payload += zmako_length_tables[cs23];

			uint64x2_t u64_01 = vreinterpretq_u64_u8(unpacked01);
			uint64x2_t u64_23 = vreinterpretq_u64_u8(unpacked23);

			u64 w0_raw = vgetq_lane_u64(u64_01, 0);
			u64 w1_raw = vgetq_lane_u64(u64_01, 1);
			u64 w2_raw = vgetq_lane_u64(u64_23, 0);
			u64 w3_raw = vgetq_lane_u64(u64_23, 1);

			u64 d0 = dict[w0_raw & DICT_MASK];
			u64 out0 = (s0 == 3) ? w0_raw :
			           (s0 == 2) ? ((d0 & 0xFFFFFFFFFFFF0000ULL) | ((w0_raw >> 8) & 0xFFFF)) :
			           (s0 == 1) ? d0 : 0;
			dst_words[i + j + 0] = out0;
			dict[WKDM_HASH(out0) | ((out0 == 0) << 6)] = out0;

			u64 d1 = dict[w1_raw & DICT_MASK];
			u64 out1 = (s1 == 3) ? w1_raw :
			           (s1 == 2) ? ((d1 & 0xFFFFFFFFFFFF0000ULL) | ((w1_raw >> 8) & 0xFFFF)) :
			           (s1 == 1) ? d1 : 0;
			dst_words[i + j + 1] = out1;
			dict[WKDM_HASH(out1) | ((out1 == 0) << 6)] = out1;

			u64 d2 = dict[w2_raw & DICT_MASK];
			u64 out2 = (s2 == 3) ? w2_raw :
			           (s2 == 2) ? ((d2 & 0xFFFFFFFFFFFF0000ULL) | ((w2_raw >> 8) & 0xFFFF)) :
			           (s2 == 1) ? d2 : 0;
			dst_words[i + j + 2] = out2;
			dict[WKDM_HASH(out2) | ((out2 == 0) << 6)] = out2;

			u64 d3 = dict[w3_raw & DICT_MASK];
			u64 out3 = (s3 == 3) ? w3_raw :
			           (s3 == 2) ? ((d3 & 0xFFFFFFFFFFFF0000ULL) | ((w3_raw >> 8) & 0xFFFF)) :
			           (s3 == 1) ? d3 : 0;
			dst_words[i + j + 3] = out3;
			dict[WKDM_HASH(out3) | ((out3 == 0) << 6)] = out3;
		}
	}
	kernel_neon_end();

	return 0;
}

const struct zcomp_ops backend_zmako = {
	.compress	= zmako_compress,
	.decompress	= zmako_decompress,
	.create_ctx	= zmako_create,
	.destroy_ctx	= zmako_destroy,
	.setup_params	= zmako_setup_params,
	.release_params	= zmako_release_params,
	.name		= "zmako",
};
