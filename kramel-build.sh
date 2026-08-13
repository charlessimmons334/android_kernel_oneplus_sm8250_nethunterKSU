#!/usr/bin/env bash
# Self-hosted GitHub runner build script for OnePlus 8 / 8 Pro NetErnels kernel
# Optimized for the persistent Ubuntu/Proxmox Android builder.
#
# Highlights:
# - Uses persistent Proton Clang at /opt/android/toolchains/proton-clang
# - Uses persistent 80G ccache at /opt/android/ccache
# - Keeps native Ubuntu GCC/G++ + /usr/bin linker for HOST tools
# - Supports incremental builds
# - Reuses AnyKernel3/libufdt checkouts when present
# - Produces a flashable ZIP + SHA256 in dist/

set -Eeuo pipefail

trap 'printf "\n\033[1;31mERROR: build failed at line %s\033[0m\n" "$LINENO" >&2' ERR

# ------------------------------
# User-configurable settings
# ------------------------------
ZIPNAME="${ZIPNAME:-ChatGPTKSU}"
AUTHOR="${AUTHOR:-Krucial}"
ARCH="${ARCH:-arm64}"
MODEL="${MODEL:-OnePlus 8 / 8 Pro}"
DEVICE="${DEVICE:-unified_op8}"
DEFCONFIG="${DEFCONFIG:-neternels_defconfig}"
FILES="${FILES:-Image.gz-dtb}"

MODULES="${MODULES:-0}"
BUILD_DTBO="${BUILD_DTBO:-0}"
INCREMENTAL="${INCREMENTAL:-1}"
SILENCE="${SILENCE:-0}"
UPDATE_TOOLS="${UPDATE_TOOLS:-0}"

ANDROID_BUILD_ROOT="${ANDROID_BUILD_ROOT:-/opt/android}"
PROTON_CLANG="${PROTON_CLANG:-$ANDROID_BUILD_ROOT/toolchains/proton-clang}"
CCACHE_DIR="${CCACHE_DIR:-$ANDROID_BUILD_ROOT/ccache}"
CCACHE_SIZE="${CCACHE_SIZE:-80G}"

KERNEL_DIR="$(pwd -P)"
OUT_DIR="$KERNEL_DIR/out"
DIST_DIR="$KERNEL_DIR/dist"
LOG_FILE="$KERNEL_DIR/error.log"

# Native HOST tools must not use Proton's older GNU linker.
HOSTCC="${HOSTCC:-/usr/bin/gcc -B/usr/bin}"
HOSTCXX="${HOSTCXX:-/usr/bin/g++ -B/usr/bin}"

msg() {
    printf '\n\033[1;32m%s\033[0m\n\n' "$*"
}

warn() {
    printf '\n\033[1;33mWARNING: %s\033[0m\n\n' "$*" >&2
}

err() {
    printf '\n\033[1;31mERROR: %s\033[0m\n\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

check_host() {
    msg "Checking host dependencies"

    local cmds=(
        git make zip perl bc bison flex python3
        ccache sha256sum find
    )

    local cmd
    for cmd in "${cmds[@]}"; do
        need_cmd "$cmd"
    done

    [[ -x /usr/bin/gcc ]] || err "Host GCC not found at /usr/bin/gcc"
    [[ -x /usr/bin/g++ ]] || err "Host G++ not found at /usr/bin/g++"
    [[ -x /usr/bin/ld ]]  || err "Host linker not found at /usr/bin/ld"

    local host_ld
    host_ld="$(/usr/bin/gcc -B/usr/bin -print-prog-name=ld)"

    case "$host_ld" in
        /usr/bin/ld|/usr/bin/x86_64-linux-gnu-ld)
            ;;
        */clang-llvm/*|*/proton-clang/*)
            err "Host GCC is resolving a Proton linker: $host_ld"
            ;;
        /usr/bin/*)
            warn "Using native host linker reported by GCC: $host_ld"
            ;;
        *)
            err "Unexpected host linker outside /usr/bin: $host_ld"
            ;;
    esac

    need_cmd aarch64-linux-gnu-gcc
    need_cmd arm-linux-gnueabi-gcc

    [[ -f "$KERNEL_DIR/Makefile" ]] ||
        err "Run this script from the kernel source root"

    [[ -f "$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG" ]] ||
        err "Defconfig not found: arch/arm64/configs/$DEFCONFIG"
}

find_existing_clang() {
    local candidates=(
        "$PROTON_CLANG"
        "$KERNEL_DIR/clang-llvm"
        "$HOME/kernel-builder/toolchains/proton-clang"
        "$HOME/kernel-builder/toolchains/clang-llvm"
    )

    local d
    for d in "${candidates[@]}"; do
        if [[ -x "$d/bin/clang" && -x "$d/bin/ld.lld" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
    done

    return 1
}

prepare_clang() {
    msg "Preparing Proton Clang"

    if TC_DIR="$(find_existing_clang)"; then
        msg "Reusing Proton Clang: $TC_DIR"
    else
        TC_DIR="$PROTON_CLANG"

        mkdir -p "$(dirname "$TC_DIR")"

        if [[ -e "$TC_DIR" ]]; then
            err "$TC_DIR exists but is not a usable Proton Clang checkout"
        fi

        git clone --depth=1 \
            https://github.com/kdrag0n/proton-clang.git \
            "$TC_DIR"
    fi

    if [[ "$UPDATE_TOOLS" == "1" && -d "$TC_DIR/.git" ]]; then
        msg "Updating Proton Clang"
        git -C "$TC_DIR" pull --ff-only ||
            warn "Could not fast-forward Proton Clang; continuing with existing checkout"
    fi

    export TC_DIR
    export PATH="$TC_DIR/bin:$PATH"

    export KBUILD_COMPILER_STRING
    KBUILD_COMPILER_STRING="$("$TC_DIR/bin/clang" --version | head -n 1)"

    msg "Host linker isolation"
    printf 'Native host ld: %s\n' "$(/usr/bin/gcc -B/usr/bin -print-prog-name=ld)"

    msg "Target compiler"
    "$TC_DIR/bin/clang" --version | head -n 3
}

prepare_ccache() {
    msg "Preparing persistent ccache"

    mkdir -p "$CCACHE_DIR"

    export CCACHE_DIR
    export CCACHE_BASEDIR="$KERNEL_DIR"
    export CCACHE_COMPILERCHECK="content"

    ccache --set-config="cache_dir=$CCACHE_DIR"
    ccache --set-config="max_size=$CCACHE_SIZE"
    ccache --set-config="compression=true"

    printf 'Cache dir : %s\n' "$CCACHE_DIR"
    printf 'Cache size: %s\n' "$CCACHE_SIZE"
    ccache -s
}

prepare_anykernel() {
    msg "Preparing NetErnels AnyKernel3 (op8)"

    AK3_DIR="$KERNEL_DIR/AnyKernel3"

    if [[ -d "$AK3_DIR/.git" ]]; then
        msg "Reusing AnyKernel3: $AK3_DIR"
    elif [[ -e "$AK3_DIR" ]]; then
        err "$AK3_DIR exists but is not a Git checkout. Rename/remove it first."
    else
        git clone --depth=1 --branch op8 --single-branch \
            https://github.com/NetErnels/AnyKernel3.git \
            "$AK3_DIR"
    fi

    local remote
    remote="$(git -C "$AK3_DIR" remote get-url origin 2>/dev/null || true)"

    if [[ "$remote" != *"NetErnels/AnyKernel3"* ]]; then
        warn "Existing AnyKernel3 remote is '$remote', not NetErnels/AnyKernel3"
    fi

    if git -C "$AK3_DIR" show-ref --verify --quiet refs/heads/op8; then
        local branch
        branch="$(git -C "$AK3_DIR" branch --show-current)"

        if [[ "$branch" != "op8" ]]; then
            git -C "$AK3_DIR" checkout op8
        fi
    elif git -C "$AK3_DIR" show-ref --verify --quiet refs/remotes/origin/op8; then
        git -C "$AK3_DIR" checkout -b op8 --track origin/op8
    else
        git -C "$AK3_DIR" fetch --depth=1 origin op8:refs/remotes/origin/op8
        git -C "$AK3_DIR" checkout -b op8 --track origin/op8
    fi

    if [[ "$UPDATE_TOOLS" == "1" ]]; then
        git -C "$AK3_DIR" pull --ff-only ||
            warn "Could not fast-forward AnyKernel3; continuing with existing checkout"
    fi

    export AK3_DIR
}

prepare_libufdt() {
    msg "Preparing libufdt"

    LIBUFDT_DIR="$KERNEL_DIR/scripts/ufdt/libufdt"

    if [[ -d "$LIBUFDT_DIR/.git" ]]; then
        msg "Reusing libufdt: $LIBUFDT_DIR"
    elif [[ -e "$LIBUFDT_DIR" ]]; then
        if [[ -n "$(find "$LIBUFDT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            msg "Reusing existing libufdt source tree: $LIBUFDT_DIR"
        else
            rm -rf "$LIBUFDT_DIR"
            git clone \
                https://android.googlesource.com/platform/system/libufdt \
                "$LIBUFDT_DIR"
        fi
    else
        mkdir -p "$(dirname "$LIBUFDT_DIR")"
        git clone \
            https://android.googlesource.com/platform/system/libufdt \
            "$LIBUFDT_DIR"
    fi

    if [[ "$UPDATE_TOOLS" == "1" && -d "$LIBUFDT_DIR/.git" ]]; then
        git -C "$LIBUFDT_DIR" pull --ff-only ||
            warn "Could not fast-forward libufdt; continuing with existing checkout"
    fi
}

build_args() {
    MAKE_ARGS=(
        "ARCH=$ARCH"
        "SUBARCH=$ARCH"
        "HOSTCC=$HOSTCC"
        "HOSTCXX=$HOSTCXX"
        "CROSS_COMPILE=aarch64-linux-gnu-"
        "CROSS_COMPILE_ARM32=arm-linux-gnueabi-"
        "CC=ccache clang"
        "LLVM=1"
        "LLVM_IAS=1"
        "AR=llvm-ar"
        "NM=llvm-nm"
        "LD=ld.lld"
        "OBJCOPY=llvm-objcopy"
        "OBJDUMP=llvm-objdump"
        "STRIP=llvm-strip"
    )

    if [[ "$SILENCE" == "1" ]]; then
        MAKE_ARGS+=("-s")
    fi
}

configure_kernel() {
    msg "Generating $DEFCONFIG"

    if [[ "$INCREMENTAL" == "0" ]]; then
        msg "Cleaning previous output"
        rm -rf "$OUT_DIR"
    fi

    mkdir -p "$OUT_DIR"

    make O="$OUT_DIR" "${MAKE_ARGS[@]}" "$DEFCONFIG"
}

build_kernel() {
    msg "Starting kernel compilation"

    local start end diff
    start="$(date +%s)"

    make -j"$(nproc --all)" \
        O="$OUT_DIR" \
        "${MAKE_ARGS[@]}" \
        2>&1 | tee "$LOG_FILE"

    end="$(date +%s)"
    diff=$((end - start))

    KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/$FILES"

    [[ -f "$KERNEL_IMAGE" ]] ||
        err "Build finished without expected artifact: $KERNEL_IMAGE"

    msg "Kernel compiled successfully in $((diff / 60))m $((diff % 60))s"
    ls -lh "$KERNEL_IMAGE"

    if [[ "$BUILD_DTBO" == "1" ]]; then
        msg "Building DTBO/DTB images"

        make -j"$(nproc --all)" \
            O="$OUT_DIR" \
            "${MAKE_ARGS[@]}" \
            dtbo.img dtb.img
    fi
}

build_modules() {
    [[ "$MODULES" == "1" ]] || return 0

    msg "Building loadable modules"

    MOD_REPO="$KERNEL_DIR/Mod"

    if [[ -d "$MOD_REPO/.git" ]]; then
        msg "Reusing neternels-modules: $MOD_REPO"
    elif [[ -e "$MOD_REPO" ]]; then
        err "$MOD_REPO exists but is not a Git checkout"
    else
        git clone --depth=1 \
            https://github.com/neternels/neternels-modules.git \
            "$MOD_REPO"
    fi

    make -j"$(nproc --all)" \
        O="$OUT_DIR" \
        "${MAKE_ARGS[@]}" \
        modules_prepare

    make -j"$(nproc --all)" \
        O="$OUT_DIR" \
        "${MAKE_ARGS[@]}" \
        modules

    rm -rf "$OUT_DIR/modules"
    mkdir -p "$OUT_DIR/modules"

    make -j"$(nproc --all)" \
        O="$OUT_DIR" \
        "${MAKE_ARGS[@]}" \
        modules_install \
        INSTALL_MOD_PATH="$OUT_DIR/modules"

    mkdir -p "$MOD_REPO/system/lib/modules"
    find "$MOD_REPO/system/lib/modules" -type f -name '*.ko' -delete
    find "$OUT_DIR/modules" -type f -name '*.ko' \
        -exec cp -f {} "$MOD_REPO/system/lib/modules/" \;
}

package_kernel() {
    msg "Creating AnyKernel3 flashable ZIP"

    mkdir -p "$DIST_DIR"

    KERVER="$(make kernelversion)"
    VERSION="${VERSION:-$KERVER}"
    DATE="$(date +%Y%m%d-%H%M)"
    ZIP_BASE="${ZIPNAME}-${DEVICE}-${VERSION}-${DATE}"
    ZIP_PATH="$DIST_DIR/${ZIP_BASE}.zip"

    # Prevent stale payloads from an earlier build from being packaged.
    rm -f \
        "$AK3_DIR/Image" \
        "$AK3_DIR/Image.gz" \
        "$AK3_DIR/Image.gz-dtb" \
        "$AK3_DIR/dtb" \
        "$AK3_DIR/dtb.img" \
        "$AK3_DIR/dtbo.img"

    cp -f "$KERNEL_IMAGE" "$AK3_DIR/$FILES"

    if [[ "$BUILD_DTBO" == "1" ]]; then
        [[ -f "$OUT_DIR/arch/arm64/boot/dtbo.img" ]] &&
            cp -f "$OUT_DIR/arch/arm64/boot/dtbo.img" "$AK3_DIR/dtbo.img"

        [[ -f "$OUT_DIR/arch/arm64/boot/dtb.img" ]] &&
            cp -f "$OUT_DIR/arch/arm64/boot/dtb.img" "$AK3_DIR/dtb.img"
    fi

    rm -f "$ZIP_PATH"

    (
        cd "$AK3_DIR"

        zip -r9 "$ZIP_PATH" . \
            -x '.git/*' \
               '.github/*' \
               'README.md' \
               '*.zip' \
               '*placeholder'
    )

    sha256sum "$ZIP_PATH" | tee "$ZIP_PATH.sha256"

    msg "Flashable package created"
    printf 'ZIP:    %s\n' "$ZIP_PATH"
    printf 'SHA256: %s\n' "$ZIP_PATH.sha256"
}

show_summary() {
    msg "Build configuration"

    printf 'Kernel source : %s\n' "$KERNEL_DIR"
    printf 'Kernel version: %s\n' "$(make kernelversion)"
    printf 'Device        : %s [%s]\n' "$MODEL" "$DEVICE"
    printf 'Defconfig     : %s\n' "$DEFCONFIG"
    printf 'Kernel image  : %s\n' "$FILES"
    printf 'Modules       : %s\n' "$MODULES"
    printf 'Build DTBO    : %s\n' "$BUILD_DTBO"
    printf 'Incremental   : %s\n' "$INCREMENTAL"
    printf 'Host compiler : %s\n' "$(/usr/bin/gcc --version | head -n 1)"
    printf 'Host linker   : %s\n' "$(/usr/bin/gcc -B/usr/bin -print-prog-name=ld)"
    printf 'Target clang  : %s\n' "$("$TC_DIR/bin/clang" --version | head -n 1)"
    printf 'ccache dir    : %s\n' "$CCACHE_DIR"
    printf 'ccache max    : %s\n' "$CCACHE_SIZE"
    printf 'Jobs          : %s\n' "$(nproc --all)"
}

show_results() {
    msg "Build results"

    printf 'Kernel: %s\n' "$KERNEL_IMAGE"
    printf 'ZIP:    %s\n' "$ZIP_PATH"
    printf 'Log:    %s\n' "$LOG_FILE"

    ls -lh "$KERNEL_IMAGE" "$ZIP_PATH" "$ZIP_PATH.sha256"

    echo
    ccache -s
}

main() {
    check_host
    prepare_clang
    prepare_ccache
    prepare_anykernel
    prepare_libufdt

    export KBUILD_BUILD_USER="$AUTHOR"
    export KBUILD_BUILD_HOST="$(hostname)"
    export ARCH
    export SUBARCH="$ARCH"

    build_args
    show_summary
    configure_kernel
    build_kernel
    build_modules
    package_kernel
    show_results

    msg "Done"
}

main "$@"
