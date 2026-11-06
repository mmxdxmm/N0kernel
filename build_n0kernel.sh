#!/bin/bash
# N0kernel 一键编译脚本（匹配「修复后的源码仓库」）
#
# 与旧 build.sh / build_test.sh 的关键差异：
#   - 不再 unzip Makefile2.zip/change2.zip：自定义文件已固化进仓库，解压会抹掉 A/B/C/D 的全部修复
#   - 不再 wget setup.sh --cleanup：该远端脚本无条件执行且会污染源码
#   - AnyKernel3 克隆分支 main -> master（仓库默认分支为 master）
#   - KSU 默认关闭（scripts/config -d KSU），仅 --ksu 时开启 config 开关（未验证）
#   - 支持 cas / cmi 双设备；每个设备编译后立即把产物另存 build_out/$DEVICE/
#   - 打包用仓库内 anykernel-$DEVICE/（含定制 anykernel.sh + C 的运行时开关）
#
# 用法:
#   bash build_n0kernel.sh cas|cmi|all [--ksu] [--pack-only] [--local-ak3]
# 详见 usage()。

set -e

ROOT=$PWD
KERNEL_TAG=${KERNEL_TAG:-20260908}
OUT_DIR=${OUT_DIR:-$ROOT}
CLANG_URL="https://github.com/mmxdxmm/aosp-clang/releases/download/main-kernel/clang-r547379.tar.gz"

usage() {
  cat <<'EOF'
用法: bash build_n0kernel.sh <cas|cmi|all> [选项]

设备:
  cas          编译 cas (Mi 10 Ultra)
  cmi          编译 cmi (Mi 10 Pro)
  all          一次编译 cas + cmi（每个设备编译后立即另存 build_out/$DEVICE/）

选项:
  --ksu        启用 KSU（默认关闭；未验证，需自行集成 KernelSU 源码）
  --pack-only  仅用 build_out/$DEVICE/ 已有 Image+dtb 打包刷机 zip（不编译）
  --local-ak3  跳过 AnyKernel3 clone，直接用仓库内置 anykernel-$DEVICE/ 模板
  -h/--help    显示本帮助

环境变量:
  OUT_DIR      刷机 zip 输出目录（默认=仓库根）
  KERNEL_TAG   zip 名中的版本串（默认 20260908）

示例:
  bash build_n0kernel.sh cas
  bash build_n0kernel.sh all
  OUT_DIR=/workspace bash build_n0kernel.sh all --pack-only --local-ak3
EOF
}

[ $# -ge 1 ] || { usage; exit 1; }
DEVICE_ARG=$1; shift
KSU=0; PACK_ONLY=0; LOCAL_AK3=0
for arg in "$@"; do
  case "$arg" in
    --ksu)       KSU=1;;
    --pack-only) PACK_ONLY=1;;
    --local-ak3) LOCAL_AK3=1;;
    -h|--help)   usage; exit 0;;
    *) echo "未知参数: $arg"; usage; exit 1;;
  esac
done
case "$DEVICE_ARG" in
  cas|cmi) DEVICES="$DEVICE_ARG";;
  all)     DEVICES="cas cmi";;
  *) echo "未知设备: $DEVICE_ARG"; usage; exit 1;;
esac

# ---------- 工具链：clang/bin/clang 已存在则跳过；否则从 clang.tar.gz 解压 ----------
if [ "$PACK_ONLY" = "1" ]; then
  echo "[toolchain] --pack-only：跳过工具链检查"
else
  if [ -x "$ROOT/clang/bin/clang" ]; then
    echo "[toolchain] clang/bin/clang 已存在，跳过下载与解压"
  else
    if [ ! -f "$ROOT/clang.tar.gz" ]; then
      echo "[toolchain] 下载 clang.tar.gz ..."
      wget -nv -O clang.tar.gz "$CLANG_URL" || { echo "工具链下载失败"; rm -f clang.tar.gz; exit 1; }
    fi
    echo "[toolchain] 解压 clang.tar.gz -> clang/"
    mkdir -p clang
    tar -xf clang.tar.gz -C clang
  fi
  [ -x "$ROOT/clang/bin/clang" ] || { echo "clang/bin/clang 仍缺失"; exit 1; }
  export PATH="$ROOT/clang/bin:/usr/lib/ccache:$PATH"
  export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
  export CC="ccache clang -ffunction-sections -fdata-sections"
  export CXX="ccache clang++ -ffunction-sections -fdata-sections"
fi

# ---------- 编译参数（与 handoff_D 2.1 / 旧 build_test.sh:67-69 逐字一致）----------
MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"
CFLAGS="--target=aarch64-linux-gnu -O2 -march=armv8.2-a+lse+crypto+dotprod -mcpu=cortex-a77 -flto=thin -Wno-error"
LDFLAGS="-Wl,--gc-sections --strip-debug"

# ---------- scripts/config 追加项（build_test.sh:158-196 原样，勿删 ZMAKO 后端）----------
apply_config_extras() {
  scripts/config --file out/.config \
    -e LTO_CLANG \
    -e CONFIG_KALLSYMS_ALL \
    -e CONFIG_LD_DEAD_CODE_DATA_ELIMINATION \
    -e CONFIG_MODULES \
    -d CONFIG_KPROBES \
    -e CONFIG_MODULE_FORCE_LOAD \
    -e CONFIG_MODULE_UNLOAD \
    -e CONFIG_MODULE_FORCE_UNLOAD \
    -d CONFIG_MODVERSIONS \
    -d CONFIG_MODULE_SRCVERSION_ALL \
    -d CONFIG_MODULE_SIG \
    -e CONFIG_MODULE_COMPRESS \
    -e CONFIG_MODULE_COMPRESS_GZIP \
    -d CONFIG_MODULE_COMPRESS_XZ \
    -d CONFIG_TRIM_UNUSED_KSYMS \
    -d CONFIG_TEST_ASYNC_DRIVER_PROBE \
    -d CONFIG_MTD_TESTS \
    -d CONFIG_I2C_STUB \
    -d CONFIG_SPI_LOOPBACK_TEST \
    -d CONFIG_RTL8192U \
    -d CONFIG_RTLLIB \
    -d CONFIG_RTL8723BS \
    -d CONFIG_R8188EU \
    -d CONFIG_88EU_AP_MODE \
    -d CONFIG_LTE_GDM724X \
    -d CONFIG_CRYPTO_TEST \
    -d CONFIG_ARM64_RELOC_TEST \
    -d CONFIG_LIB80211_DEBUG \
    -e CONFIG_ZRAM_BACKEND_LZ4KD \
    -e CONFIG_ZRAM_BACKEND_LZ4K_OPLUS \
    -e CONFIG_CRYPTO_LZ4KD \
    -e CONFIG_CRYPTO_LZ4K_OPLUS \
    -e CONFIG_LZ4KD_COMPRESS \
    -e CONFIG_LZ4KD_DECOMPRESS \
    -e CONFIG_ZRAM_BACKEND_ZMAKO \
    -e CONFIG_ZRAM_BACKEND_ZMAKO_H \
    -e CONFIG_KSM \
    -e CONFIG_UKSM
}

# ---------- KSU 开关（默认关闭；--ksu 仅写 config，不执行任何远端脚本/覆盖包）----------
apply_ksu_switch() {
  if [ "$KSU" = "1" ]; then
    echo "[KSU] 已启用（未验证）：仅写 config 开关，需自行集成 KernelSU 源码，否则 drivers/kernelsu 为空目录会失败"
    scripts/config --file out/.config \
      -e KSU \
      -e KSU_SUSFS \
      -e KSU_SUSFS_SUS_OVERLAYFS \
      -e CONFIG_KSU_SUSFS_SUS_SU \
      -d CONFIG_KPM
  else
    scripts/config --file out/.config -d KSU
  fi
}

# ---------- 打包：对应设备的 anykernel.sh + Image + dtb ----------
pack_device() {
  local DEVICE=$1
  local STAGE="$ROOT/anykernel"
  local OUTNAME="N0kernel_${DEVICE}_${KERNEL_TAG}_anykernel3.zip"
  echo "[pack:$DEVICE] 准备 AnyKernel3 目录"
  rm -rf "$STAGE"
  if [ "$LOCAL_AK3" = "1" ]; then
    echo "[pack:$DEVICE] --local-ak3：用仓库内置模板 anykernel-$DEVICE/"
    cp -a "$ROOT/anykernel-$DEVICE" "$STAGE"
  elif git clone https://github.com/mmxdxmm/AnyKernel3 -b master --single-branch --depth=1 "$STAGE" 2>/dev/null; then
    echo "[pack:$DEVICE] 已克隆 AnyKernel3 master"
  else
    echo "[pack:$DEVICE] clone 失败，回退到仓库内置模板 anykernel-$DEVICE/"
    rm -rf "$STAGE"
    cp -a "$ROOT/anykernel-$DEVICE" "$STAGE"
  fi
  # 用本仓库的定制 anykernel.sh + 运行时开关覆盖/补齐（保证两份交付物一致）
  cp -a "$ROOT/anykernel-$DEVICE/." "$STAGE/"
  rm -rf "$STAGE/.git"
  # 拷贝该设备已编译好的内核产物
  cp "$ROOT/build_out/$DEVICE/Image" "$STAGE/Image"
  cp "$ROOT/build_out/$DEVICE/dtb"   "$STAGE/dtb"
  mkdir -p "$OUT_DIR"
  ( cd "$STAGE" && zip -r9 "$OUT_DIR/$OUTNAME" . -x '*.zip' >/dev/null )
  echo "[pack:$DEVICE] 生成 $OUT_DIR/$OUTNAME"
}

# ---------- 主流程 ----------
for DEVICE in $DEVICES; do
  if [ "$PACK_ONLY" = "1" ]; then
    [ -f "$ROOT/build_out/$DEVICE/Image" ] && [ -f "$ROOT/build_out/$DEVICE/dtb" ] || {
      echo "缺少 $DEVICE 产物（build_out/$DEVICE/Image 或 dtb）"; exit 1; }
    pack_device "$DEVICE"
    continue
  fi

  [ -f "arch/arm64/configs/${DEVICE}_defconfig" ] || {
    echo "缺少 arch/arm64/configs/${DEVICE}_defconfig"; exit 1; }
  echo "===== 编译 $DEVICE (KSU=$KSU) ====="
  rm -rf out/
  make CFLAGS="$CFLAGS" CXXFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" $MAKE_ARGS ${DEVICE}_defconfig
  apply_ksu_switch
  apply_config_extras
  make CFLAGS="$CFLAGS" CXXFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" $MAKE_ARGS -j$(nproc)
  [ -f out/arch/arm64/boot/Image ] || { echo "编译失败：未生成 Image"; exit 1; }
  find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb

  # 立即另存（下个设备会 rm -rf out/，避免覆盖第一个设备产物）
  mkdir -p "build_out/$DEVICE"
  cp out/arch/arm64/boot/Image "build_out/$DEVICE/Image"
  cp out/arch/arm64/boot/dtb   "build_out/$DEVICE/dtb"
  cp out/.config               "build_out/$DEVICE/.config"
  cp out/System.map            "build_out/$DEVICE/System.map"

  pack_device "$DEVICE"
done

echo "完成。刷机 zip 位于 $OUT_DIR/N0kernel_*_anykernel3.zip"
