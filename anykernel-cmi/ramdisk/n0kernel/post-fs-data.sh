#!/system/bin/sh
# Magisk / KernelSU 模块：post-fs-data 阶段应用 N0kernel 运行时开关
# （纯 AnyKernel3 无 root 方案时，改由 init.n0kernel.rc 在 boot_completed 拉起）
MODDIR=${0%/*}
[ -f "$MODDIR/n0kernel-tune.sh" ] && . "$MODDIR/n0kernel-tune.sh"
