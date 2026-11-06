#!/system/bin/sh
# Magisk / KernelSU 模块：late_start 再应用一次
# （部分 sysfs 节点在 boot_completed 之后才就绪）
MODDIR=${0%/*}
[ -f "$MODDIR/n0kernel-tune.sh" ] && . "$MODDIR/n0kernel-tune.sh"
