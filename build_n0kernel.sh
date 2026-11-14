#!/bin/bash
# N0kernel 一键编译脚本（匹配「原版 lz4 v1.10.0 + 主线 MGLRU + 关闭 KSM/UKSM」源码仓库）
#
# 本次移植：mm 引入 multi-gen LRU（CONFIG_LRU_GEN，取代 uksm）；
# lib/lz4 保持原版 v1.10.0（含 arm64 NEON 快路径）——升级到 v1.11.1 会造成实机卡死，已回退；
# uksm/ksm 全面关闭；运行时开关切到 /sys/kernel/mm/lru_gen/{enabled,min_ttl_ms}。
#
# 与旧 build.sh / build_test.sh 的关键差异：
#   - 不再 unzip Makefile2.zip/change2.zip：自定义文件已固化进仓库，解压会抹掉 A/B/C/D 的全部修复
#   - 不再 wget setup.sh --cleanup：该远端脚本无条件执行且会污染源码；KSU 集成改为本脚本内可控流程
#   - AnyKernel3 克隆分支 main -> master（仓库默认分支为 master）
#   - KSU 默认关闭（scripts/config -d KSU）；--ksu 时完整集成 SukiSU-Ultra(susfs-1.5.5)，
#     并强制用 ksu_change.zip 覆盖 throne_tracker.c（修「安装新应用卡死」）
#   - 支持 cas / cmi 双设备；每个设备编译后立即把产物另存 build_out/$DEVICE/（KSU 版另存 *_sukisu-ultra-v3.2.0/）
#   - 打包用仓库内 anykernel-$DEVICE/（含定制 anykernel.sh + C 的运行时开关）
#   - 内存优化联动：zram 默认 lz4 + CONFIG_ZRAM_ASYNC_GC + CONFIG_LRU_GEN 启用、
#     KSM/UKSM 关闭；编译前后各做一次配置自检（verify_memopt_config），不符即拒绝编译
#   - STRICT_WARNINGS=1（默认）：编译日志出现 error/warning 即拒绝打包
#   - zip 名中的版本串默认取编译当天日期 YYYYMMDD（可用 KERNEL_TAG 显式覆盖）
#
# 用法:
#   bash build_n0kernel.sh cas|cmi|all [--ksu] [--pack-only] [--local-ak3]
# 详见 usage()。

set -e
set -o pipefail

ROOT=$PWD
KERNEL_TAG=${KERNEL_TAG:-$(date +%Y%m%d)}
OUT_DIR=${OUT_DIR:-$ROOT}
STRICT_WARNINGS=${STRICT_WARNINGS:-1}
CLANG_URL="https://github.com/mmxdxmm/aosp-clang/releases/download/main-kernel/clang-r547379.tar.gz"
# 国内/受限网络走中转（只影响工具链下载，不影响编译产物）：
#   MIRROR_PREFIX="https://<中转域名>/<你的token>/" bash build_n0kernel.sh cas
# 也可 CLANG_URL_OVERRIDE=<完整URL> 直接指定；CI（境外）默认直连。
MIRROR_PREFIX=${MIRROR_PREFIX:-}
CLANG_URL_OVERRIDE=${CLANG_URL_OVERRIDE:-}

usage() {
  cat <<'EOF'
用法: bash build_n0kernel.sh <cas|cmi|all> [选项]

设备:
  cas          编译 cas (Mi 10 Ultra)
  cmi          编译 cmi (Mi 10 Pro)
  all          一次编译 cas + cmi（每个设备编译后立即另存 build_out/$DEVICE/）

选项:
  --ksu        启用 KSU：拉取 SukiSU-Ultra(susfs-1.5.5) + susfs-1.5.5.zip 补丁 +
               ksu_change.zip 覆盖 throne_tracker.c（默认关闭；产物另存 *_sukisu-ultra-v3.2.0/）
  --pack-only  仅用 build_out/ 下已有 Image+dtb 打包刷机 zip（不编译）
  --local-ak3  跳过 AnyKernel3 clone，直接用仓库内置 anykernel-$DEVICE/ 模板
  -h/--help    显示本帮助

环境变量:
  OUT_DIR             刷机 zip 输出目录（默认=仓库根）
  KERNEL_TAG          zip 名中的版本串（默认=编译当天日期 YYYYMMDD；显式指定可复现旧命名）
  MIRROR_PREFIX       工具链下载中转前缀，形如 https://<中转域名>/<token>/
  CLANG_URL_OVERRIDE  直接指定工具链完整下载 URL（优先级高于 MIRROR_PREFIX）

示例:
  bash build_n0kernel.sh cas
  bash build_n0kernel.sh all
  bash build_n0kernel.sh cmi --ksu
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

# SukiSU-Ultra 版产物与刷机包独立命名/独立目录，绝不覆盖无 KSU 版本
# 后缀用准确版本标识 sukisu-ultra-v3.2.0（历史曾用 _ksu，易与 KSU 变量名混淆）
OUT_SUFFIX=""
[ "$KSU" = "1" ] && OUT_SUFFIX="_sukisu-ultra-v3.2.0"

# ---------- 工具链：clang/bin/clang 已存在则跳过；否则从 clang.tar.gz 解压 ----------
if [ "$PACK_ONLY" = "1" ]; then
  echo "[toolchain] --pack-only：跳过工具链检查"
else
  if [ -x "$ROOT/clang/bin/clang" ]; then
    echo "[toolchain] clang/bin/clang 已存在，跳过下载与解压"
  else
    if [ ! -f "$ROOT/clang.tar.gz" ]; then
      CLANG_DL_URL="${CLANG_URL_OVERRIDE:-${MIRROR_PREFIX}${CLANG_URL}}"
      echo "[toolchain] 下载 clang.tar.gz ..."
      echo "[toolchain] URL: $CLANG_DL_URL"
      wget -c -nv -O clang.tar.gz "$CLANG_DL_URL" || { echo "工具链下载失败"; rm -f clang.tar.gz; exit 1; }
    fi
    echo "[toolchain] 解压 clang.tar.gz -> clang/"
    mkdir -p clang
    # 个别 clang 发行包内含 lldb 目录重命名，tar 会报非致命告警；
    # 以 clang/bin/clang 是否可执行为最终判据（紧随其后的 -x 检查）。
    tar -xf clang.tar.gz -C clang || true
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
    -d CONFIG_KSM \
    -d CONFIG_UKSM \
    -e CONFIG_LRU_GEN \
    -e CONFIG_LRU_GEN_ENABLED
}

# ---------- KSU 集成（--ksu 时）----------
# 为什么必须覆盖 ksu_change.zip：
#   上游 SukiSU-Ultra 的 KernelSU/kernel/throne_tracker.c 在 iterate_dir() 的
#   actor 回调（持目录锁、GFP_ATOMIC 上下文）里直接调用 kern_path()/vfs_getattr()，
#   二者是可能睡眠的 VFS 操作。安装新应用时 KSU 的 throne_tracker 线程扫描
#   /data/user_de 会与 installd 的目录操作死锁，表现为「安装新应用卡死」。
#   补丁把包名先存进链表，等 iterate_dir 返回、filp_close 之后再统一做路径查找。
#   该补丁必须在拉取 KSU 源码「之后」覆盖，否则会被上游源码冲掉。
KSU_OVERLAY_LIST="$ROOT/.ksu_overlay_files"
KSU_BASELINE="$ROOT/.ksu_baseline_modified"
KSU_NOW="$ROOT/.ksu_now_modified"
KSU_REPO="mmxdxmm/SukiSU-Ultra"

clone_ksu() {
  local URL=$1
  rm -rf "$ROOT/KernelSU"
  if git clone --depth=1 --branch susfs-1.5.5 "$URL" "$ROOT/KernelSU" 2>/dev/null; then
    return 0
  fi
  rm -rf "$ROOT/KernelSU"
  if git clone --depth=1 "$URL" "$ROOT/KernelSU" 2>/dev/null; then
    git -C "$ROOT/KernelSU" checkout susfs-1.5.5 2>/dev/null && return 0
  fi
  return 1
}

# susfs-1.5.5.zip 内含整份 include/linux/sched.h；--ksu 时 unzip -o 会覆盖掉
# MGLRU 的 struct task_struct::in_lru_fault 字段，而 mm_inline.h 的
# lru_gen_in_fault() 在 CONFIG_LRU_GEN 下仍引用它，mm/page_alloc.c 会直接
# 报 "no member named 'in_lru_fault' in 'struct task_struct'"。
# 覆盖后幂等补回，同时保留 SUSFS 自己的 ANDROID_KABI/KSU 字段。
restore_mglru_sched_field() {
  local h="$ROOT/include/linux/sched.h"
  python3 "$ROOT/scripts/restore_mglru_sched_field.py" "$h" || {
    echo "[MGLRU] 无法补回 sched.h 的 in_lru_fault 字段，拒绝编译"; exit 1; }
  grep -q 'in_lru_fault' "$h" || {
    echo "[MGLRU] 补回后校验仍失败，拒绝编译"; exit 1; }
}

setup_ksu() {
  echo "[KSU] 集成 $KSU_REPO (susfs-1.5.5)"
  # 记录集成前已修改的已跟踪文件：cleanup 时只还原「集成期间新产生」的改动，
  # 不碰用户在编译前自己的未提交改动（例如刚改过的本脚本）。
  git -C "$ROOT" diff --name-only 2>/dev/null | sort > "$KSU_BASELINE" || : > "$KSU_BASELINE"
  # 1) KSU 源码；仓库自带软链 drivers/kernelsu -> ../KernelSU/kernel，补齐即可生效
  if [ ! -f "$ROOT/KernelSU/kernel/Kconfig" ]; then
    clone_ksu "https://github.com/${KSU_REPO}.git" || \
      clone_ksu "${MIRROR_PREFIX}https://github.com/${KSU_REPO}.git" || {
        echo "[KSU] KSU 源码拉取失败，无法继续（无 KSU 版本请用不带 --ksu 的构建）"; exit 1; }
  fi
  [ -f "$ROOT/KernelSU/kernel/Kconfig" ] || { echo "[KSU] KernelSU/kernel 不完整"; exit 1; }
  # 2) Kconfig / Makefile（幂等；Makefile 已被改为 obj-$(CONFIG_KSU) += kernelsu/）
  grep -q 'drivers/kernelsu/Kconfig' "$ROOT/drivers/Kconfig" || \
    sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" "$ROOT/drivers/Kconfig"
  grep -q 'kernelsu/' "$ROOT/drivers/Makefile" || \
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$ROOT/drivers/Makefile"
  # 3) SUSFS 内核侧补丁；记录覆盖清单以便编译后还原源码工作区
  unzip -Z1 "$ROOT/susfs-1.5.5.zip" | grep -v '/$' > "$KSU_OVERLAY_LIST"
  unzip -o -q "$ROOT/susfs-1.5.5.zip" -d "$ROOT"
  # 3b) susfs 覆盖了 include/linux/sched.h，必须补回 MGLRU 字段；
  #     否则 mm_inline.h 的 lru_gen_in_fault() 会让 mm/page_alloc.c 编译失败。
  restore_mglru_sched_field
  # 4) 关键：覆盖 throne_tracker.c，修复「安装新应用卡死」
  unzip -o -q "$ROOT/ksu_change.zip" -d "$ROOT"
  grep -q "pkg_name_node" "$ROOT/KernelSU/kernel/throne_tracker.c" || {
    echo "[KSU] ksu_change.zip 未生效（throne_tracker.c 仍是上游版），拒绝编译"; exit 1; }
  echo "[KSU] throne_tracker.c 已应用 VFS 死锁修复"
  # 5) 旧脚本同款：去掉 KSU 对 OVERLAY_FS 的 select，避免与本机 overlayfs 冲突
  sed -i '/config KSU/,/help/{/select OVERLAY_FS/d}' "$ROOT/arch/arm64/Kconfig"
}

cleanup_ksu() {
  echo "[KSU] 还原集成期的临时改动（保持源码仓库干净）"
  sed -i '/source "drivers\/kernelsu\/Kconfig"/d' "$ROOT/drivers/Kconfig" 2>/dev/null || true
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" checkout -- arch/arm64/Kconfig drivers/Makefile 2>/dev/null || true
    # 兜底：还原集成期间「新产生」的已跟踪文件改动。
    # KSU 构建除 susfs zip 覆盖外，还会自动给 fs/internal.h 加 path_umount() 声明
    # （4.19 未导出该函数，KSU 需要），这类文件不在 zip 清单里，必须靠 diff 基线兜住。
    git -C "$ROOT" diff --name-only 2>/dev/null | sort > "$KSU_NOW" || : > "$KSU_NOW"
    [ -f "$KSU_BASELINE" ] || : > "$KSU_BASELINE"
    comm -23 "$KSU_NOW" "$KSU_BASELINE" 2>/dev/null | while IFS= read -r f; do
      [ -z "$f" ] && continue
      git -C "$ROOT" checkout -- "$f" 2>/dev/null || true
    done
    if [ -f "$KSU_OVERLAY_LIST" ]; then
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        if git -C "$ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
          git -C "$ROOT" checkout -- "$f" 2>/dev/null || true
        else
          rm -f "$ROOT/$f"
        fi
      done < "$KSU_OVERLAY_LIST"
    fi
  else
    echo "[KSU] 警告：当前目录不是 git 仓库，susfs 覆盖的文件无法自动还原，请手动检查"
  fi
  rm -f "$KSU_OVERLAY_LIST" "$KSU_BASELINE" "$KSU_NOW"
  rm -rf "$ROOT/KernelSU"
  mkdir -p "$ROOT/KernelSU"   # 保留 tarball 自带空目录；软链保持悬空但 CONFIG_KSU=n 时无害
}

# ---------- 内存优化特性：配置联动 + 编译前后自检 ----------
# 本仓库已移植：zram 异步 GC（CONFIG_ZRAM_ASYNC_GC）、默认压缩器 lz4、
# lz4/zstd 后端。以下函数保证「改了源码也必须真的编进去」。
apply_memopt_config() {
  scripts/config --file out/.config \
    -e CONFIG_ZRAM \
    -e CONFIG_ZRAM_BACKEND_LZ4 \
    -e CONFIG_ZRAM_BACKEND_ZSTD \
    -e CONFIG_ZRAM_ASYNC_GC \
    -d CONFIG_ZRAM_DEF_COMP_LZORLE \
    -d CONFIG_ZRAM_DEF_COMP_LZO \
    -d CONFIG_ZRAM_DEF_COMP_LZ4HC \
    -d CONFIG_ZRAM_DEF_COMP_LZ4K \
    -d CONFIG_ZRAM_DEF_COMP_LZ4K_OPLUS \
    -d CONFIG_ZRAM_DEF_COMP_LZ4KD \
    -d CONFIG_ZRAM_DEF_COMP_ZSTD \
    -d CONFIG_ZRAM_DEF_COMP_DEFLATE \
    -d CONFIG_ZRAM_DEF_COMP_842 \
    -d CONFIG_ZRAM_DEF_COMP_ZMAKO \
    -d CONFIG_ZRAM_DEF_COMP_ZMAKO_H \
    -e CONFIG_ZRAM_DEF_COMP_LZ4 \
    -e CONFIG_LRU_GEN \
    -e CONFIG_LRU_GEN_ENABLED \
    --set-str CONFIG_ZRAM_DEF_COMP lz4
}

verify_memopt_config() {
  local cfg=out/.config
  local bad=0
  local line
  # 自检证据同时落到 build_<device>.log，便于随包追溯
  vlog() { echo "$@" | tee -a "${BUILD_LOG:-/dev/null}"; }
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    if ! grep -qxF "$line" "$cfg"; then
      vlog "[verify] 配置不符: $line"
      bad=1
    fi
  done <<'MEMOPT_CFG'
CONFIG_ZRAM=y
CONFIG_ZRAM_ASYNC_GC=y
CONFIG_ZRAM_BACKEND_LZ4=y
CONFIG_ZRAM_BACKEND_ZSTD=y
CONFIG_ZRAM_DEF_COMP_LZ4=y
CONFIG_ZRAM_DEF_COMP="lz4"
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
CONFIG_LZ4_COMPRESS=y
CONFIG_LZ4_DECOMPRESS=y
CONFIG_ZSTD_COMPRESS=y
CONFIG_ZSTD_DECOMPRESS=y
MEMOPT_CFG
  # KSM/UKSM 必须关闭（.config 中不允许出现 =y）
  if grep -qE '^CONFIG_(KSM|UKSM)=y' "$cfg"; then
    vlog "[verify] CONFIG_KSM / CONFIG_UKSM 仍处于开启状态（MGLRU 已取代 uksm）"
    bad=1
  fi
  if [ "$bad" != "0" ]; then
    vlog "[verify] 内存优化配置未生效，拒绝继续编译（检查 defconfig / Kconfig / scripts/config）"
    exit 1
  fi
  vlog "[verify] 内存优化配置 OK：lz4=zram 默认, async_gc=y, MGLRU=y, KSM/UKSM=off"
}

verify_source_markers() {
  grep -q 'config ZRAM_ASYNC_GC' drivers/block/zram/Kconfig || {
    echo "[verify] 源码缺少 CONFIG_ZRAM_ASYNC_GC，疑似拉错分支/旧源码"; exit 1; }
  grep -q 'zram_gc_work' drivers/block/zram/zram_drv.c || {
    echo "[verify] 源码缺少 zram 异步 GC 实现"; exit 1; }
  grep -q 'config LRU_GEN' mm/Kconfig || {
    echo "[verify] 源码缺少 CONFIG_LRU_GEN（MGLRU 未移植）"; exit 1; }
  grep -q 'lru_gen_age_node' mm/vmscan.c || {
    echo "[verify] 源码缺少 MGLRU aging 实现"; exit 1; }
  # KSU/susfs 覆盖 sched.h 会冲掉该字段；编译前显式拦截，避免编译到一半才报错
  grep -q 'in_lru_fault' include/linux/sched.h || {
    echo "[verify] sched.h 缺少 CONFIG_LRU_GEN 的 in_lru_fault 字段（KSU/susfs 覆盖会冲掉）"; exit 1; }
  grep -qE 'LZ4_VERSION_MINOR[[:space:]]+10' lib/lz4/lz4.h || {
    echo "[verify] lib/lz4 不是原版 v1.10.0"; exit 1; }
  grep -q 'lz4accel.o' lib/lz4/Makefile || {
    echo "[verify] lib/lz4/Makefile 未启用 arm64 NEON 快路径"; exit 1; }
  local d
  for d in $DEVICES; do
    grep -q 'CONFIG_ZRAM_DEF_COMP="lz4"' "arch/arm64/configs/${d}_defconfig" || {
      echo "[verify] ${d}_defconfig 默认压缩器不是 lz4"; exit 1; }
    grep -q '^CONFIG_LRU_GEN=y' "arch/arm64/configs/${d}_defconfig" || {
      echo "[verify] ${d}_defconfig 未启用 MGLRU"; exit 1; }
    grep -q '^# CONFIG_KSM is not set' "arch/arm64/configs/${d}_defconfig" || {
      echo "[verify] ${d}_defconfig 未关闭 KSM"; exit 1; }
    grep -q '^# CONFIG_UKSM is not set' "arch/arm64/configs/${d}_defconfig" || {
      echo "[verify] ${d}_defconfig 未关闭 UKSM"; exit 1; }
    grep -q 'lru_gen/enabled' "anykernel-${d}/ramdisk/n0kernel/n0kernel-tune.sh" || {
      echo "[verify] anykernel-${d} 运行时未联动 MGLRU"; exit 1; }
  done
  echo "[verify] 源码标记 OK（原版 lz4 1.10.0 + NEON + MGLRU + KSM/UKSM 关闭 + 双设备联动）"
}

summarize_build_log() {
  local log=$1
  [ -f "$log" ] || return 0
  local nerr nwarn
  # 只认编译器/链接器诊断，不把 git/curl/fetch-pack 的网络噪声当编译错误。
  # KSU 的 Kbuild 会在编译期间执行 git 取版本号，网络抖动会输出
  # "error: RPC failed; curl 56 ..."；旧版宽松的 'error:' 匹配会把它计为
  # 编译错误并拒绝打包（编译本体其实是成功的）。
  # 匹配形态：path.c:12:34: error: / clang: error: / make[2]: *** Error 1
  local DIAG_ERR='(^|[[:space:]])[^[:space:]]+\.(c|h|cc|cpp|C|S|s|o|ld):[0-9]+(:[0-9]+)?:[[:space:]]*error:|(^|[[:space:]])(clang|clang\+\+|gcc|cc|ld|ld\.lld|lld|collect2|as|ar|objcopy):[[:space:]]*error:|Error [0-9]+'
  local DIAG_WARN='(^|[[:space:]])[^[:space:]]+\.(c|h|cc|cpp|C|S|s|o):[0-9]+(:[0-9]+)?:[[:space:]]*warning:|(^|[[:space:]])(clang|clang\+\+|gcc|cc|ld|ld\.lld|lld|collect2):[[:space:]]*warning:'
  nerr=$(grep -ciE "$DIAG_ERR" "$log" || true)
  nwarn=$(grep -ciE "$DIAG_WARN" "$log" || true)
  echo "[build] 日志统计: $log"
  echo "  error   : $nerr"
  echo "  warning : $nwarn"
  if [ "$STRICT_WARNINGS" = "1" ]; then
    [ "$nerr" = "0" ] || { echo "[build] 编译日志存在 error，拒绝打包"; exit 1; }
    [ "$nwarn" = "0" ] || { echo "[build] 编译日志存在 warning，拒绝打包（STRICT_WARNINGS=1）"; exit 1; }
  fi
}

apply_ksu_switch() {
  if [ "$KSU" = "1" ]; then
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
  local SRCDIR="$ROOT/build_out/${DEVICE}${OUT_SUFFIX}"
  local OUTNAME="N0kernel_${DEVICE}${OUT_SUFFIX}_${KERNEL_TAG}_anykernel3.zip"
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
  cp "$SRCDIR/Image" "$STAGE/Image"
  cp "$SRCDIR/dtb"   "$STAGE/dtb"
  mkdir -p "$OUT_DIR"
  ( cd "$STAGE" && zip -r9 "$OUT_DIR/$OUTNAME" . -x '*.zip' >/dev/null )
  echo "[pack:$DEVICE] 生成 $OUT_DIR/$OUTNAME"
}

# ---------- 主流程 ----------
if [ "$KSU" = "1" ] && [ "$PACK_ONLY" != "1" ]; then
  setup_ksu
  trap cleanup_ksu EXIT
fi

if [ "$PACK_ONLY" != "1" ]; then
  verify_source_markers
fi

for DEVICE in $DEVICES; do
  if [ "$PACK_ONLY" = "1" ]; then
    [ -f "$ROOT/build_out/${DEVICE}${OUT_SUFFIX}/Image" ] && \
      [ -f "$ROOT/build_out/${DEVICE}${OUT_SUFFIX}/dtb" ] || {
      echo "缺少 $DEVICE 产物（build_out/${DEVICE}${OUT_SUFFIX}/Image 或 dtb）"; exit 1; }
    pack_device "$DEVICE"
    continue
  fi

  [ -f "arch/arm64/configs/${DEVICE}_defconfig" ] || {
    echo "缺少 arch/arm64/configs/${DEVICE}_defconfig"; exit 1; }
  echo "===== 编译 $DEVICE (KSU=$KSU) ====="
  rm -rf out/
  BUILD_LOG="$ROOT/build_${DEVICE}${OUT_SUFFIX}.log"
  : > "$BUILD_LOG"
  make CFLAGS="$CFLAGS" CXXFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" $MAKE_ARGS ${DEVICE}_defconfig
  apply_ksu_switch
  apply_config_extras
  apply_memopt_config
  # 让 Kconfig 收敛后再校验，防止 oldconfig 把 choice 选回 ZMAKO
  make $MAKE_ARGS olddefconfig
  verify_memopt_config
  make CFLAGS="$CFLAGS" CXXFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" $MAKE_ARGS -j$(nproc) 2>&1 | tee -a "$BUILD_LOG"
  # 编译后再次校验：确认 make 没有把内存优化配置改回去
  verify_memopt_config
  summarize_build_log "$BUILD_LOG"
  [ -f out/arch/arm64/boot/Image ] || { echo "编译失败：未生成 Image"; exit 1; }
  find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb

  # 立即另存（下个设备会 rm -rf out/，避免覆盖第一个设备产物）
  mkdir -p "build_out/${DEVICE}${OUT_SUFFIX}"
  cp out/arch/arm64/boot/Image "build_out/${DEVICE}${OUT_SUFFIX}/Image"
  cp out/arch/arm64/boot/dtb   "build_out/${DEVICE}${OUT_SUFFIX}/dtb"
  cp out/.config               "build_out/${DEVICE}${OUT_SUFFIX}/.config"
  cp out/System.map            "build_out/${DEVICE}${OUT_SUFFIX}/System.map"

  pack_device "$DEVICE"
done

echo "完成。刷机 zip 位于 $OUT_DIR/N0kernel_*_anykernel3.zip"
