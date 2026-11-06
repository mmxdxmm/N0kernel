// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/kernel.h>
#include <linux/vmalloc.h>
#include <linux/lz4k.h>
#include "zcomp.h"
#include "backend_lz4k.h"

static void lz4k_release_params(struct zcomp_params *params) {}

static int lz4k_setup_params(struct zcomp_params *params)
{
	return 0;
}

static int lz4k_create(struct zcomp_params *params, struct zcomp_ctx *ctx)
{
	ctx->context = vmalloc(lz4k_encode_state_bytes_min());
	if (!ctx->context)
		return -ENOMEM;
	return 0;
}

static void lz4k_destroy(struct zcomp_ctx *ctx)
{
	vfree(ctx->context);
}

static int lz4k_compress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			 struct zcomp_req *req)
{
	int ret;

	ret = lz4k_encode(ctx->context, req->src, req->dst, req->src_len, req->dst_len, 0);
	if (ret < 0)
		return -EINVAL;

	req->dst_len = ret;
	return 0;
}

static int lz4k_decompress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			   struct zcomp_req *req)
{
	int ret;

	ret = lz4k_decode(req->src, req->dst, req->src_len, req->dst_len);
	if (ret <= 0)
		return -EINVAL;

	return 0;
}

const struct zcomp_ops backend_lz4k = {
	.compress	= lz4k_compress,
	.decompress	= lz4k_decompress,
	.create_ctx	= lz4k_create,
	.destroy_ctx	= lz4k_destroy,
	.setup_params	= lz4k_setup_params,
	.release_params	= lz4k_release_params,
	.name		= "lz4k",
};
