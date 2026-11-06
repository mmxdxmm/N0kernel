# SPDX-License-Identifier: GPL-2.0-only

zram-y	:=	zcomp.o zram_drv.o

zram-$(CONFIG_ZRAM_BACKEND_LZO)		+= backend_lzorle.o backend_lzo.o
zram-$(CONFIG_ZRAM_BACKEND_LZ4)		+= backend_lz4.o
zram-$(CONFIG_ZRAM_BACKEND_LZ4HC)	+= backend_lz4hc.o
zram-$(CONFIG_ZRAM_BACKEND_ZSTD)	+= backend_zstd.o
zram-$(CONFIG_ZRAM_BACKEND_DEFLATE)	+= backend_deflate.o
zram-$(CONFIG_ZRAM_BACKEND_842)		+= backend_842.o
zram-$(CONFIG_ZRAM_BACKEND_LZ4K) += backend_lz4k.o
zram-$(CONFIG_ZRAM_BACKEND_LZ4KD) += backend_lz4kd.o
zram-$(CONFIG_ZRAM_BACKEND_LZ4K_OPLUS) += backend_lz4k_oplus.o
zram-$(CONFIG_ZRAM_BACKEND_ZMAKO) += backend_zmako.o
zram-$(CONFIG_ZRAM_BACKEND_ZMAKO_H) += backend_zmako_h.o

obj-$(CONFIG_ZRAM)	+=	zram.o

CFLAGS_REMOVE_backend_zmako.o += -mgeneral-regs-only
CFLAGS_backend_zmako.o += -march=armv8-a+simd -Wno-declaration-after-statement -Wno-gcc-compat
CFLAGS_REMOVE_backend_zmako_h.o += -mgeneral-regs-only
CFLAGS_backend_zmako_h.o += -march=armv8-a+simd -Wno-declaration-after-statement -Wno-gcc-compat