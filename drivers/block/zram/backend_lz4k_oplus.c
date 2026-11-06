// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/kernel.h>
#include <linux/vmalloc.h>
#include "zcomp.h"
#include "backend_lz4k_oplus.h"

extern int lz4k_compress(void *const state, const void *const source,
			 void *dest, unsigned source_max, unsigned dest_max);
extern int lz4k_decompress(const void *const source, void *const dest,
			   unsigned source_max, unsigned dest_max);

static void lz4k_oplus_release_params(struct zcomp_params *params) {}

static int lz4k_oplus_setup_params(struct zcomp_params *params)
{
	return 0;
}

static int lz4k_oplus_create(struct zcomp_params *params, struct zcomp_ctx *ctx)
{
	ctx->context = vmalloc(PAGE_SIZE * 2);
	if (!ctx->context)
		return -ENOMEM;
	return 0;
}

static void lz4k_oplus_destroy(struct zcomp_ctx *ctx)
{
	vfree(ctx->context);
}

static int lz4k_oplus_compress(struct zcomp_params *params, struct zcomp_ctx *ctx,
				struct zcomp_req *req)
{
	int ret;

	ret = lz4k_compress(ctx->context, req->src, req->dst, req->src_len, req->dst_len);
	if (ret < 0)
		return -EINVAL;

	req->dst_len = ret;
	return 0;
}

static int lz4k_oplus_decompress(struct zcomp_params *params, struct zcomp_ctx *ctx,
				  struct zcomp_req *req)
{
	int ret;

	ret = lz4k_decompress(req->src, req->dst, req->src_len, req->dst_len);
	if (ret <= 0)
		return -EINVAL;

	return 0;
}

const struct zcomp_ops backend_lz4k_oplus = {
	.compress	= lz4k_oplus_compress,
	.decompress	= lz4k_oplus_decompress,
	.create_ctx	= lz4k_oplus_create,
	.destroy_ctx	= lz4k_oplus_destroy,
	.setup_params	= lz4k_oplus_setup_params,
	.release_params	= lz4k_oplus_release_params,
	.name		= "lz4k_oplus",
};
