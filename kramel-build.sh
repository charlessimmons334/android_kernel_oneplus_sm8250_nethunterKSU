#!/bin/bash

# Simplified Kernel Build Script for ChatGPTKSU Kernel by Krucial
# Telegram and debug uploads removed

set -e

msg() {
    echo -e "\n\e[1;32m$*\e[0m\n"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
    exit 1
}

cdir() {
    cd "$1" 2>/dev/null || err "The directory $1 doesn't exist!"
}

# Build config
KERNEL_DIR="$(pwd)"
ZIPNAME="ChatGPTKSU"
DEFCONFIG=neternels_defconfig
COMPILER=clang
MODULES=1
FILES=Image.gz-dtb
BUILD_DTBO=0
SIGN=1
SILENCE=0
AUTHOR="Krucial"

clone() {
    msg "|| Cloning Proton Clang ||"
    git clone --depth=1 https://github.com/kdrag0n/proton-clang.git clang-llvm

    msg "|| Cloning AnyKernel3 ||"
    git clone --depth 1 --no-single-branch https://github.com/NetErnels/AnyKernel3.git -b op8

    # Add custom banner
 cat << "EOF" > AnyKernel3/banner
   _____ _           _    _____ _  __
  / ____| |         | |  / ____| |/ /
 | |    | |__   __ _| |_| (___ | ' / 
 | |    | '_ \ / _\` | __|\___ \|  <  
 | |____| | | | (_| | |_ ____) | . \ 
  \_____|_| |_|\__,_|\__|_____/|_|\_\

      ChatGPTKSU Kernel by Krucial
     Speed. Stability. Rooted Intelligence
----------------------------------------------------
EOF


    if [ $MODULES = "1" ]; then
        msg "|| Cloning kernel modules ||"
        git clone --depth 1 https://github.com/neternels/neternels-modules.git Mod
    fi
}

exports() {
    export ARCH=arm64
    export SUBARCH=arm64
    export PATH="$KERNEL_DIR/clang-llvm/bin:$PATH"
    export KBUILD_BUILD_USER=$AUTHOR
    export KBUILD_COMPILER_STRING=$("$KERNEL_DIR/clang-llvm/bin/clang" --version | head -n1)
    PROCS=$(nproc --all)
}

build_kernel() {
    msg "|| Starting Kernel Compilation ||"
    make O=out $DEFCONFIG

    make -j"$PROCS" O=out \ 
        CROSS_COMPILE=aarch64-linux-gnu- \ 
        CROSS_COMPILE_ARM32=arm-linux-gnueabi- \ 
        CC=clang \ 
        LLVM=1 \ 
        LLVM_IAS=1 \ 
        AR=llvm-ar \ 
        LD=ld.lld \ 
        OBJDUMP=llvm-objdump \ 
        STRIP=llvm-strip

    if [ $MODULES = "1" ]; then
        make -j"$PROCS" O=out modules_prepare
        make -j"$PROCS" O=out modules INSTALL_MOD_PATH="$KERNEL_DIR/out/modules"
        make -j"$PROCS" O=out modules_install INSTALL_MOD_PATH="$KERNEL_DIR/out/modules"
        find "$KERNEL_DIR/out/modules" -type f -iname '*.ko' -exec cp {} Mod/system/lib/modules/ \;
    fi

    if [ -f "$KERNEL_DIR/out/arch/arm64/boot/$FILES" ]; then
        msg "|| Kernel compiled successfully ||"
        gen_zip
    else
        err "Compilation failed. Output file not found."
    fi
}

gen_zip() {
    msg "|| Creating flashable zip ||"
    cp "$KERNEL_DIR/out/arch/arm64/boot/$FILES" AnyKernel3/$FILES || err "Failed to copy $FILES to AnyKernel3"
    cdir AnyKernel3
    zip -r9 "$ZIPNAME.zip" . -x ".git*" -x "README.md" -x "*.zip"
    msg "|| Zip created: $ZIPNAME.zip ||"
    cd ..
}

# Execution
clone
exports
build_kernel
