#!/bin/bash
# build.sh - KernelSU-Next minimal build + AnyKernel3 pack
# Usage:
#   bash build.sh <target_device> [ksu] [miui|aosp|both]
#
# Examples:
#   bash build.sh lmi
#   bash build.sh lmi ksu miui

set -euo pipefail
shopt -s nullglob

TOOLCHAIN_PATH="${HOME}/proton-clang/proton-clang-20210522/bin"
KSU_SETUP_URL="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh"
KSU_TAG_DEFAULT="v1.0.8"

ANYKERNEL_REPO="https://github.com/liyafe1997/AnyKernel3"
ANYKERNEL_BRANCH="kona"

OUTDIR="out"
AKDIR="anykernel"

die() { echo "[!] $*" >&2; exit 1; }
log() { echo "[*] $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

cfg_has() { grep -qE "^(# )?CONFIG_${1}(=| is not set)" "${OUTDIR}/.config"; }
cfg_enable() {
  local sym="$1"
  if cfg_has "$sym"; then scripts/config --file "${OUTDIR}/.config" -e "$sym"; log "Enabled ${sym}"
  else log "Skip ${sym} (symbol not found)"; fi
}
cfg_disable() {
  local sym="$1"
  if cfg_has "$sym"; then scripts/config --file "${OUTDIR}/.config" -d "$sym"; log "Disabled ${sym}"
  else log "Skip ${sym} (symbol not found)"; fi
}
cfg_set_str() {
  local sym="$1"; local val="$2"
  if cfg_has "$sym"; then scripts/config --file "${OUTDIR}/.config" --set-str "$sym" "$val"; log "Set ${sym}=\"${val}\""
  else log "Skip ${sym} (symbol not found)"; fi
}

sed_glob() {
  local pattern="$1"
  local expr="$2"
  local files=( $pattern )
  [ ${#files[@]} -eq 0 ] && return 0
  for f in "${files[@]}"; do sed -i "$expr" "$f"; done
}

TARGET_DEVICE="${1:-}"
ARG2="${2:-}"
ARG3="${3:-}"

[ -n "$TARGET_DEVICE" ] || die "No target device. Example: bash build.sh lmi ksu miui"

KSU_ENABLE=0
BUILD_VARIANT="miui"

if [ "${ARG2}" = "ksu" ]; then
  KSU_ENABLE=1
  [ -n "${ARG3}" ] && BUILD_VARIANT="${ARG3}"
else
  [ -n "${ARG2}" ] && BUILD_VARIANT="${ARG2}"
fi

case "${BUILD_VARIANT}" in miui|aosp|both) ;; *) die "Unknown variant: ${BUILD_VARIANT} (miui|aosp|both)";; esac

GIT_COMMIT_ID="$(git rev-parse --short=8 HEAD)"
DATE_TAG="$(date +'%Y%m%d_%H%M%S')"
LOCALVER="-perf-ksunext-${DATE_TAG}-${GIT_COMMIT_ID}"

[ -d "${TOOLCHAIN_PATH}" ] || die "TOOLCHAIN_PATH not found: ${TOOLCHAIN_PATH}"

# ---- IMPORTANT: put ccache first, then toolchain ----
export PATH="/usr/lib/ccache:${TOOLCHAIN_PATH}:${PATH}"

need_cmd clang
need_cmd ld.lld
need_cmd aarch64-linux-gnu-ld
need_cmd arm-linux-gnueabi-ld
need_cmd make
need_cmd git
need_cmd curl
need_cmd zip
need_cmd bc

log "TOOLCHAIN_PATH: ${TOOLCHAIN_PATH}"
log "clang --version:"
clang --version

# ---- Fix: force HOST tools to use clang + lld (avoid old binutils ld from toolchain) ----
export HOSTCC="clang"
export HOSTCXX="clang++"
export HOSTLD="ld.lld"
export HOSTCFLAGS="-fuse-ld=lld"
export HOSTLDFLAGS="-fuse-ld=lld"

# ccache dir
export CCACHE_DIR="${HOME}/.cache/ccache_mikernel"
log "CCACHE_DIR: ${CCACHE_DIR}"

MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=${OUTDIR} CC=clang \
CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

DEFCONFIG="arch/arm64/configs/${TARGET_DEVICE}_defconfig"
[ -f "${DEFCONFIG}" ] || die "Defconfig not found: ${DEFCONFIG}
Available:
$(ls arch/arm64/configs/*_defconfig 2>/dev/null | sed 's/^/  - /')"

if [ "${KSU_ENABLE}" -eq 1 ]; then
  log "KernelSU-Next enabled"
  KSU_TAG="${KSU_TAG:-${KSU_TAG_DEFAULT}}"
  log "Running KernelSU-Next setup: tag=${KSU_TAG}"
  curl -LSs "${KSU_SETUP_URL}" | bash -s "${KSU_TAG}"
else
  log "KernelSU-Next disabled"
fi

log "Cleaning build output..."
rm -rf "${OUTDIR}" "${AKDIR}"

log "Cloning AnyKernel3: ${ANYKERNEL_REPO} (branch ${ANYKERNEL_BRANCH})"
git clone "${ANYKERNEL_REPO}" -b "${ANYKERNEL_BRANCH}" --single-branch --depth=1 "${AKDIR}"

pack_anykernel() {
  local zip_prefix="$1"
  local ksu_str="$2"

  log "Generating dtb..."
  find "${OUTDIR}/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "${OUTDIR}/arch/arm64/boot/dtb"

  rm -rf "${AKDIR}/kernels"
  mkdir -p "${AKDIR}/kernels"

  cp "${OUTDIR}/arch/arm64/boot/Image" "${AKDIR}/kernels/"
  cp "${OUTDIR}/arch/arm64/boot/dtb"  "${AKDIR}/kernels/"

  ( cd "${AKDIR}" && \
    ZIP_FILENAME="${zip_prefix}_${TARGET_DEVICE}_${ksu_str}_${DATE_TAG}_anykernel3_${GIT_COMMIT_ID}.zip" && \
    zip -r9 "${ZIP_FILENAME}" ./* -x .git .gitignore out/ ./*.zip && \
    mv "${ZIP_FILENAME}" "../" \
  )
}

build_aosp() {
  log "===== Building for AOSP ====="
  make ${MAKE_ARGS} "${TARGET_DEVICE}_defconfig"

  cfg_set_str LOCALVERSION "${LOCALVER}"
  cfg_disable LOCALVERSION_AUTO

  if [ "${KSU_ENABLE}" -eq 1 ]; then
    cfg_enable KSU
    cfg_enable KSU_MANUAL_HOOK
  else
    cfg_disable KSU
  fi

  make ${MAKE_ARGS} olddefconfig
  make ${MAKE_ARGS} -j"$(nproc)"

  [ -f "${OUTDIR}/arch/arm64/boot/Image" ] || die "AOSP build failed: Image not found"

  local ksu_str="NoKernelSU"
  [ "${KSU_ENABLE}" -eq 1 ] && ksu_str="KernelSU-Next"
  pack_anykernel "Kernel_AOSP" "${ksu_str}"
  log "AOSP package done."
}

build_miui() {
  log "===== Building for MIUI/HyperOS ====="

  # backup & patch dts (safe no-op if missing)
  local dts_source="arch/arm64/boot/dts/vendor/qcom"
  if [ -d "${dts_source}" ]; then
    rm -rf .dts.bak
    cp -a "${dts_source}" .dts.bak

    sed_glob "${dts_source}/dsi-panel-j1s*" 's/<154>/<1537>/g'
    sed_glob "${dts_source}/dsi-panel-j2*"  's/<154>/<1537>/g'
    sed_glob "${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi" 's/<155>/<1544>/g'
    sed_glob "${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi"    's/<155>/<1545>/g'
    sed_glob "${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi"   's/<155>/<1546>/g'
    sed_glob "${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi"   's/<155>/<1546>/g'
    sed_glob "${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi"    's/<70>/<695>/g'
    sed_glob "${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi"  's/<70>/<695>/g'
    sed_glob "${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi"   's/<70>/<695>/g'
    sed_glob "${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi"   's/<70>/<695>/g'
    sed_glob "${dts_source}/dsi-panel-j1s*" 's/<71>/<710>/g'
    sed_glob "${dts_source}/dsi-panel-j2*"  's/<71>/<710>/g'

    sed_glob "${dts_source}/dsi-panel*" 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g'
    sed_glob "${dts_source}/dsi-panel*" 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g'
    sed_glob "${dts_source}/dsi-panel*" 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g'
    sed_glob "${dts_source}/dsi-panel*" 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g'

    sed_glob "${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi" 's/120 90 60/120 90 60 50 30/g'
    sed_glob "${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi" 's/120 90 60/120 90 60 50 30/g'
    sed_glob "${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi" 's/120 90 60/120 90 60 50 30/g'
    sed_glob "${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi"  's/144 120 90 60/144 120 90 60 50 48 30/g'
  fi

  make ${MAKE_ARGS} "${TARGET_DEVICE}_defconfig"

  cfg_set_str LOCALVERSION "${LOCALVER}"
  cfg_disable LOCALVERSION_AUTO

  if [ "${KSU_ENABLE}" -eq 1 ]; then
    cfg_enable KSU
    cfg_enable KSU_MANUAL_HOOK
  else
    cfg_disable KSU
  fi

  # Optional MIUI-ish toggles (apply only if symbol exists)
  cfg_set_str STATIC_USERMODEHELPER_PATH "/system/bin/micd"
  cfg_enable XIAOMI_MIUI
  cfg_disable DEBUG_FS

  make ${MAKE_ARGS} olddefconfig
  make ${MAKE_ARGS} -j"$(nproc)"

  [ -f "${OUTDIR}/arch/arm64/boot/Image" ] || die "MIUI build failed: Image not found"

  # restore dts
  if [ -d ".dts.bak" ]; then
    rm -rf "${dts_source}"
    mv .dts.bak "${dts_source}"
  fi

  local ksu_str="NoKernelSU"
  [ "${KSU_ENABLE}" -eq 1 ] && ksu_str="KernelSU-Next"
  pack_anykernel "Kernel_MIUI" "${ksu_str}"
  log "MIUI package done."
}

log "TARGET_DEVICE: ${TARGET_DEVICE}"
log "KSU_ENABLE: ${KSU_ENABLE}"
log "BUILD_VARIANT: ${BUILD_VARIANT}"

case "${BUILD_VARIANT}" in
  aosp) build_aosp ;;
  miui) build_miui ;;
  both)
    build_aosp
    rm -rf "${OUTDIR}"
    build_miui
    ;;
esac

log "Done. Flashable zip(s):"
ls -1 ./*.zip 2>/dev/null || true
