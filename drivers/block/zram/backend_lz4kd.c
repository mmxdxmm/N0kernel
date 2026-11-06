// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/kernel.h>
#include <linux/vmalloc.h>
#include <linux/lz4kd.h>
#include "zcomp.h"
#include "backend_lz4kd.h"

static void lz4kd_release_params(struct zcomp_params *params) {}

static int lz4kd_setup_params(struct zcomp_params *params)
{
	return 0;
}

static int lz4kd_create(struct zcomp_params *params, struct zcomp_ctx *ctx)
{
	ctx->context = vmalloc(lz4kd_encode_state_bytes_min());
	if (!ctx->context)
		return -ENOMEM;
	return 0;
}

static void lz4kd_destroy(struct zcomp_ctx *ctx)
{
	vfree(ctx->context);
}

static int lz4kd_compress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			  struct zcomp_req *req)
{
	int ret;

	ret = lz4kd_encode(ctx->context, req->src, req->dst, req->src_len, req->dst_len, 0);
	if (ret < 0)
		return -EINVAL;

	req->dst_len = ret;
	return 0;
}

static int lz4kd_decompress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			    struct zcomp_req *req)
{
	int ret;

	ret = lz4kd_decode(req->src, req->dst, req->src_len, req->dst_len);
	if (ret <= 0)
		return -EINVAL;

	return 0;
}

const struct zcomp_ops backend_lz4kd = {
	.compress	= lz4kd_compress,
	.decompress	= lz4kd_decompress,
	.create_ctx	= lz4kd_create,
	.destroy_ctx	= lz4kd_destroy,
	.setup_params	= lz4kd_setup_params,
	.release_params	= lz4kd_release_params,
	.name		= "lz4kd",
};
