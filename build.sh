#!/bin/bash

set -e

if [ -f "android-ndk-r29.zip" ]; then
    echo "文件已存在，正在解压..."
    yes | unzip android-ndk-r29.zip
else
    echo "文件不存在，正在下载..."
    wget -nv -O android-ndk-r29.zip "https://dl.google.com/android/repository/android-ndk-r29-linux.zip"
    if [ $? -eq 0 ]; then
        echo "下载完成，正在解压..."
        yes | unzip android-ndk-r29.zip
    else
        echo "下载失败，请检查网络或链接是否正确。"
    fi
fi

yes | unzip change.zip
yes | unzip swappiness.zip
#yes | tar -xvf electron-binutils-2.41.tar.xz
TOOLCHAIN_PATH=$PWD/android-ndk-r29/toolchains/llvm/prebuilt/linux-x86_64/bin
#BINUTILS_PATH=$PWD/electron-binutils-2.41/bin
GIT_COMMIT_ID="mmxdxmm"

TARGET_DEVICE=$1

if [ -z "$1" ]; then
    echo "Error: No argument provided, please specific a target device." 
    echo "If you need KernelSU, please add [ksu] as the second arg."
    echo "Examples:"
    echo "Build for lmi(K30 Pro/POCO F2 Pro) without KernelSU:"
    echo "    bash build.sh lmi"
    echo "Build for umi(Mi10) with KernelSU:"
    echo "    bash build.sh umi ksu"
    exit 1
fi



if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"


# Enable ccache for speed up compiling 
export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
export PATH="/usr/lib/ccache:$PATH"
echo "CCACHE_DIR: [$CCACHE_DIR]"


MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=out LVM=1 LLVM_IAS=1 AR=llvm-ar NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump HOSTAR=llvm-ar"
set_C="ccache clang --target=aarch64-linux-musl -O3 -march=armv8.2-a+lse+crypto+dotprod -mcpu=cortex-a77 -flto=thin -Wno-error -ffunction-sections -fdata-sections"
set_HOSTC="ccache clang -O3 -flto=thin -Wno-error -ffunction-sections -fdata-sections"
set_LD="ld.lld --strip-debug -O3 --plugin-opt=O3"
set_HOSTLD="ld.lld --strip-debug --gc-sections -O3 --plugin-opt=O3"


if [ "$1" == "j1" ]; then
    make $MAKE_ARGS -j1
    exit
fi

if [ "$1" == "continue" ]; then
    make $MAKE_ARGS -j$(nproc)
    exit
fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Avaliable defconfigs, please choose one target from below down:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi


# Check clang is existing.
echo "[clang --version]:"
clang --version $CFLAGS



KSU_ZIP_STR=NoKernelSU
if [ "$2" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=SukiSU-Ultra
else
    KSU_ENABLE=0
fi


echo "TARGET_DEVICE: $TARGET_DEVICE"

wget -O setup.sh https://raw.githubusercontent.com/mmxdxmm/SukiSU-Ultra/susfs-1.5.5/kernel/setup.sh && chmod +x setup.sh && bash ./setup.sh --cleanup

if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    yes | unzip susfs-1.5.5.zip
    curl -LSs "https://raw.githubusercontent.com/mmxdxmm/SukiSU-Ultra/susfs-1.5.5/kernel/setup.sh" | bash -s susfs-1.5.5
    sed -i '/config KSU/,/help/{/select OVERLAY_FS/d}' arch/arm64/Kconfig
else
    echo "KSU is disabled"
fi
    

echo "Cleaning..."

rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/mmxdxmm/AnyKernel3)"
git clone https://github.com/mmxdxmm/AnyKernel3 -b main --single-branch --depth=1 anykernel

# 添加内核信息
#local_version_str="-N0kernel"
#local_version_date_str="-$(date +%Y%m%d)-${GIT_COMMIT_ID}-N0kernel"
#sed -i "s/${local_version_date_str}/${local_version_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig
#sed -i "s/${local_version_str}/${local_version_date_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

# ------------- Building -------------


echo "Clearning [out/] and build....."
rm -rf out/

#更新所有文件的时间戳为系统时间
find . -exec touch -h {} +

make LD="$set_LD" HOSTLD="$set_HOSTLD" CC="$set_C" CXX="$set_C" HOSTCC="$set_HOSTC" HOSTCXX="$set_HOSTC" $MAKE_ARGS ${TARGET_DEVICE}_defconfig

if [ $KSU_ENABLE -eq 1 ]; then
    scripts/config --file out/.config \
    -e KSU \
    -e KSU_SUSFS \
    -e KSU_SUSFS_SUS_OVERLAYFS \
    -e CONFIG_KSU_SUSFS_SUS_SU \
    -e CONFIG_KPM
else
    scripts/config --file out/.config -d KSU
fi


scripts/config --file out/.config \
    -e LTO_CLANG \
    -e CONFIG_LTO_CLANG_FULL \
    -d CONFIG_LTO_CLANG_THIN \
    -d CONFIG_ARCH_SUPPORTS_LTO_CLANG_THIN \
    -d CONFIG_LTO_NONE \
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
    -e CONFIG_KALLSYMS_ALL \
    -e CONFIG_LD_DEAD_CODE_DATA_ELIMINATION

make LD="$set_LD" HOSTLD="$set_HOSTLD" CC="$set_C" CXX="$set_C" HOSTCC="$set_HOSTC" HOSTCXX="$set_HOSTC" $MAKE_ARGS -j$(nproc) Image dtbs Image-dtb



if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. MIUI Build successfully."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems MIUI build failed."
    exit 1
fi

#echo "Generating [out/arch/arm64/boot/dtb]......"
#find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb



rm -rf anykernel/Image*
rm -rf anykernel/dtb

# Patch for SukiSU KPM support. 
#if [ $KSU_ENABLE -eq 1 ]; then
#    cd out/arch/arm64/boot/
#    wget https://github.com/mmxdxmm/SukiSU_KernelPatch_patch/releases/download/v0.12.0/patch_linux
#    chmod +x patch_linux
#    ./patch_linux
#    rm Image
#    mv oImage Image
#    cd -
#fi

cp out/arch/arm64/boot/Image-dtb anykernel/
#cp out/arch/arm64/boot/dtb anykernel/

echo "Build finished."

# 恢复内核信息
#sed -i "s/${local_version_date_str}/${local_version_str}/g" arch/arm64/configs/${TARGET_DEVICE}_defconfig

# ------------- End of Building -------------


cd anykernel 

ZIP_FILENAME=N0kernel_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME ../

cd ..

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
