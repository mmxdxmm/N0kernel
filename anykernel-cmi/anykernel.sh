### AnyKernel3 Ramdisk Mod Script
### N0kernel / device: cmi (Xiaomi Mi 10 Pro, sm8250)
### 运行时调参脚本在 ramdisk/n0kernel/，由 init.n0kernel.rc 在开机后拉起。

### AnyKernel setup
# global properties
properties() { '
kernel.string=N0kernel 4.19.246 for cmi (Mi 10 Pro) by mmxdxmm
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=cmi
device.name2=cmi
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
# 运行时调参脚本需可执行
set_perm_recursive 0 0 755 755 $RAMDISK/n0kernel;
} # end attributes

# boot shell variables (sm8250 / A-B slot / boot by-name)
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# ramdisk/n0kernel/ 与 ramdisk/init.n0kernel.rc 由 AK3 标准 ramdisk 合并机制
# (tools/ak3-core.sh unpack_ramdisk 的 rdtmp 回拷) 自动打进 boot ramdisk。
dump_boot;

# 幂等注入 init.rc：开机完成后执行运行时调参脚本。
# dump_boot 后 cwd 为 ramdisk 根；同时兼容 init.rc 位于 system/etc/init/hw/ 的机型。
for rc in init.rc system/etc/init/hw/init.rc; do
  [ -f "$rc" ] || continue;
  grep -q "init.n0kernel.rc" "$rc" || echo "import /init.n0kernel.rc" >> "$rc";
done;

write_boot;
## end boot install
