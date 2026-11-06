#!/system/bin/sh
# N0kernel 运行时调参（落地 stage C 的 zram-first 开关清单）
# 读取 persist.n0kernel.* 系统属性，写 sysfs / sysctl。
# 默认：zram 回写 OFF、磁盘 swap OFF；UKSM max_cpu 由默认 95 限到 30。
# 由 init.n0kernel.rc (on property:sys.boot_completed=1) 或
# Magisk/KernelSU 模块的 post-fs-data.sh / service.sh 调用。
# 用户 setprop 改属性后重启（或再次执行本脚本）即可生效。

# 属性默认值兜底：仅当属性未设置时写入（persist 属性，用户 setprop 可覆盖）
defprop() { [ -n "$(getprop "$1")" ] || setprop "$1" "$2"; }
defprop persist.n0kernel.zram.comp_algorithm        zmako
defprop persist.n0kernel.zram.writeback             0
defprop persist.n0kernel.swap.enable                0
defprop persist.n0kernel.vm.swappiness              100
defprop persist.n0kernel.vm.watermark_scale_factor  100
defprop persist.n0kernel.uksm.run                   1
defprop persist.n0kernel.uksm.max_cpu               30
defprop persist.n0kernel.uksm.governor              low
# 以下默认沿用 Rom / 留空即不干预：
#   zram.disksize / zram.backing_dev / swap.device(辅助) / lmk.minfree

# 目标节点存在且可写才写，避免不同机型缺节点时报错
w() { [ -w "$1" ] && echo "$2" > "$1"; }

# --- zram：默认压缩器 + 可选容量 ---
w /sys/block/zram0/comp_algorithm "$(getprop persist.n0kernel.zram.comp_algorithm)"
ZDSIZE=$(getprop persist.n0kernel.zram.disksize)
[ -n "$ZDSIZE" ] && w /sys/block/zram0/disksize "$ZDSIZE"

# --- zram 回写：默认 OFF (0)。仅显式 =1 且 backing_dev 非空才启用 ---
if [ "$(getprop persist.n0kernel.zram.writeback)" = "1" ]; then
  BDEV=$(getprop persist.n0kernel.zram.backing_dev)
  if [ -n "$BDEV" ]; then
    w /sys/block/zram0/backing_dev "$BDEV"
    w /sys/block/zram0/writeback idle
  fi
fi
# 关键：默认路径绝不主动写 backing_dev / writeback —— zram_drv.c:842
# 在 backing_dev 未设置时直接返回 -ENODEV，提供第二层兜底。

# --- 磁盘/文件 swap：默认 OFF (0)。仅显式 =1 且 device 非空才 swapon ---
if [ "$(getprop persist.n0kernel.swap.enable)" = "1" ]; then
  SDEV=$(getprop persist.n0kernel.swap.device)
  if [ -n "$SDEV" ]; then
    /system/bin/swapon "$SDEV" 2>/dev/null || swapon "$SDEV" 2>/dev/null
  fi
fi

# --- vm：提前异步回收 / 保活-流畅平衡 ---
w /proc/sys/vm/swappiness              "$(getprop persist.n0kernel.vm.swappiness)"
w /proc/sys/vm/watermark_scale_factor "$(getprop persist.n0kernel.vm.watermark_scale_factor)"

# --- UKSM：保留页合并(保活)，但压掉 95% CPU 抢占(流畅) ---
w /sys/kernel/mm/uksm/run                 "$(getprop persist.n0kernel.uksm.run)"
w /sys/kernel/mm/uksm/max_cpu_percentage "$(getprop persist.n0kernel.uksm.max_cpu)"
w /sys/kernel/mm/uksm/cpu_governor       "$(getprop persist.n0kernel.uksm.governor)"

# --- LMK：仅当 simple_lmk 的 minfree 节点存在才写（cmi）。
#     cas 走标准 userspace lmkd，路径不同，此处不硬编码，由 Rom 决定。 ---
LMK=$(getprop persist.n0kernel.lmk.minfree)
[ -n "$LMK" ] && w /sys/module/lowmemorykiller/parameters/minfree "$LMK"
