#!/bin/bash
# build.sh - KernelSU-Next (minimal) build + AnyKernel3 pack script for sm8250 kernels
# Usage:
#   bash build.sh <target_device> [ksu] [miui|aosp|both]
#
# Examples:
#   bash build.sh lmi
#   bash build.sh lmi ksu
#   bash build.sh lmi ksu miui
#   bash build.sh lmi both
#   bash build.sh lmi ksu both

set -euo pipefail
shopt -s nullglob

# -----------------------------
# User tunables
# -----------------------------
TOOLCHAIN_PATH="${HOME}/proton-clang/proton-clang-20210522/bin"

# KernelSU-Next setup script (pin a tag for stability on 4.19 if needed)
KSU_SETUP_URL="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh"
KSU_TAG_DEFAULT="v1.0.8"   # change if build fails on your tree (e.g. v1.0.3)

# AnyKernel3 repo/branch
ANYKERNEL_REPO="https://github.com/liyafe1997/AnyKernel3"
ANYKERNEL_BRANCH="kona"

# Output dir
OUTDIR="out"
AKDIR="anykernel"

# -----------------------------
# Helpers
# -----------------------------
die() { echo "[!] $*" >&2; exit 1; }
log() { echo "[*] $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

cfg_has() {
  local sym="$1"
  grep -qE "^(# )?CONFIG_${sym}(=| is not set)" "${OUTDIR}/.config"
}

cfg_enable() {
  local sym="$1"
  if cfg_has "$sym"; then
    scripts/config --file "${OUTDIR}/.config" -e "$sym"
    log "Enabled ${sym}"
  else
    log "Skip ${sym} (symbol not found)"
  fi
}

cfg_disable() {
  local sym="$1"
  if cfg_has "$sym"; then
    scripts/config --file "${OUTDIR}/.config" -d "$sym"
    log "Disabled ${sym}"
  else
    log "Skip ${sym} (symbol not found)"
  fi
}

cfg_set_str() {
  local sym="$1"
  local val="$2"
  if cfg_has "$sym"; then
    scripts/config --file "${OUTDIR}/.config" --set-str "$sym" "$val"
    log "Set ${sym}=\"${val}\""
  else
    log "Skip ${sym} (symbol not found)"
  fi
}

# Apply sed to all files matching a glob (safe when no matches)
sed_glob() {
  local pattern="$1"
  local expr="$2"
  local files=( $pattern )
  if [ ${#files[@]} -eq 0 ]; then
    return 0
  fi
  for f in "${files[@]}"; do
    sed -i "$expr" "$f"
  done
}

# -----------------------------
# Parse args
# -----------------------------
TARGET_DEVICE="${1:-}"
ARG2="${2:-}"
ARG3="${3:-}"

[ -n "$TARGET_DEVICE" ] || die "No target device. Example: bash build.sh lmi ksu miui"

KSU_ENABLE=0
BUILD_VARIANT="miui"  # default

if [ "${ARG2}" = "ksu" ]; then
  KSU_ENABLE=1
  [ -n "${ARG3}" ] && BUILD_VARIANT="${ARG3}"
else
  [ -n "${ARG2}" ] && BUILD_VARIANT="${ARG2}"
fi

case "${BUILD_VARIANT}" in
  miui|aosp|both) ;;
  *) die "Unknown variant: ${BUILD_VARIANT} (use miui|aosp|both)" ;;
esac

GIT_COMMIT_ID="$(git rev-parse --short=8 HEAD)"
DATE_TAG="$(date +'%Y%m%d_%H%M%S')"
LOCALVER="-perf-ksunext-${DATE_TAG}-${GIT_COMMIT_ID}"

# -----------------------------
# Environment checks
# -----------------------------
[ -d "${TOOLCHAIN_PATH}" ] || die "TOOLCHAIN_PATH not found: ${TOOLCHAIN_PATH}"
export PATH="${TOOLCHAIN_PATH}:${PATH}"

need_cmd clang
need_cmd aarch64-linux-gnu-ld
need_cmd arm-linux-gnueabi-ld
need_cmd make
need_cmd git
need_cmd curl
need_cmd zip
need_cmd bc
need_cmd python || true

log "TOOLCHAIN_PATH: ${TOOLCHAIN_PATH}"
log "clang --version:"
clang --version

# Enable ccache (optional)
export CCACHE_DIR="${HOME}/.cache/ccache_mikernel"
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/ccache:${PATH}"
log "CCACHE_DIR: ${CCACHE_DIR}"

MAKE_ARGS="ARCH=arm64 SUBARCH=arm64 O=${OUTDIR} CC=clang \
CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
CROSS_COMPILE_COMPAT=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu-"

DEFCONFIG="arch/arm64/configs/${TARGET_DEVICE}_defconfig"
[ -f "${DEFCONFIG}" ] || die "Defconfig not found: ${DEFCONFIG}
Available:
$(ls arch/arm64/configs/*_defconfig 2>/dev/null | sed 's/^/  - /')"

# -----------------------------
# Optional KernelSU-Next integration
# -----------------------------
if [ "${KSU_ENABLE}" -eq 1 ]; then
  log "KernelSU-Next enabled"
  KSU_TAG="${KSU_TAG:-${KSU_TAG_DEFAULT}}"
  log "Running KernelSU-Next setup: tag=${KSU_TAG}"
  # Pin tag for stability on 4.19; you can export KSU_TAG=v1.0.3 before running if needed
  curl -LSs "${KSU_SETUP_URL}" | bash -s "${KSU_TAG}"
else
  log "KernelSU-Next disabled"
fi

# -----------------------------
# Clean & prepare AnyKernel3
# -----------------------------
log "Cleaning build output..."
rm -rf "${OUTDIR}" "${AKDIR}"

log "Cloning AnyKernel3: ${ANYKERNEL_REPO} (branch ${ANYKERNEL_BRANCH})"
git clone "${ANYKERNEL_REPO}" -b "${ANYKERNEL_BRANCH}" --single-branch --depth=1 "${AKDIR}"

# -----------------------------
# Common pack steps
# -----------------------------
pack_anykernel() {
  local variant="$1"   # AOSP / MIUI
  local zip_prefix="$2"
  local ksu_str="$3"

  # dtb merge
  log "Generating dtb..."
  find "${OUTDIR}/arch/arm64/boot/dts" -name '*.dtb' -exec cat {} + > "${OUTDIR}/arch/arm64/boot/dtb"

  rm -rf "${AKDIR}/kernels"
  mkdir -p "${AKDIR}/kernels"

  # NOTE: This repo packs Image + dtb separately; AnyKernel3 kona scripts will handle them.
  cp "${OUTDIR}/arch/arm64/boot/Image" "${AKDIR}/kernels/"
  cp "${OUTDIR}/arch/arm64/boot/dtb"  "${AKDIR}/kernels/"

  ( cd "${AKDIR}" && \
      ZIP_FILENAME="${zip_prefix}_${TARGET_DEVICE}_${ksu_str}_${DATE_TAG}_anykernel3_${GIT_COMMIT_ID}.zip" && \
      zip -r9 "${ZIP_FILENAME}" ./* -x .git .gitignore out/ ./*.zip && \
      mv "${ZIP_FILENAME}" "../" \
  )
}

# -----------------------------
# Build AOSP
# -----------------------------
build_aosp() {
  log "===== Building for AOSP ====="
  make ${MAKE_ARGS} "${TARGET_DEVICE}_defconfig"

  # Set localversion in .config (do NOT edit defconfig file)
  cfg_set_str LOCALVERSION "${LOCALVER}"
  cfg_disable LOCALVERSION_AUTO

  if [ "${KSU_ENABLE}" -eq 1 ]; then
    cfg_enable KSU
    # Optional: enable manual hook only if symbol exists
    cfg_enable KSU_MANUAL_HOOK
  else
    cfg_disable KSU
  fi

  # Reconcile config
  make ${MAKE_ARGS} olddefconfig

  make ${MAKE_ARGS} -j"$(nproc)"

  [ -f "${OUTDIR}/arch/arm64/boot/Image" ] || die "AOSP build failed: Image not found"
  log "AOSP build OK: ${OUTDIR}/arch/arm64/boot/Image"

  local ksu_str="NoKernelSU"
  [ "${KSU_ENABLE}" -eq 1 ] && ksu_str="KernelSU-Next"

  pack_anykernel "AOSP" "Kernel_AOSP" "${ksu_str}"
  log "AOSP package done."
}

# -----------------------------
# Build MIUI / HyperOS
# -----------------------------
build_miui() {
  log "===== Building for MIUI/HyperOS ====="
  make ${MAKE_ARGS} "${TARGET_DEVICE}_defconfig"

  # Backup dts & apply MIUI panel fixes (safe no-op if files not present)
  local dts_source="arch/arm64/boot/dts/vendor/qcom"
  if [ -d "${dts_source}" ]; then
    log "Backing up DTS: ${dts_source} -> .dts.bak"
    rm -rf .dts.bak
    cp -a "${dts_source}" .dts.bak

    # Correct panel dimensions on MIUI builds
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

    # Enable back mi smartfps while disabling qsync min refresh-rate
    sed_glob "${dts_source}/dsi-panel*" 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g'
    sed_glob "${dts_source}/dsi-panel*" 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g'
    sed_glob "${dts_source}/dsi-panel*" 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g'
    sed_glob "${dts_source}/dsi-panel*" 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g'

    # Enable back refresh rates supported on MIUI
    sed_glob "${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi" 's/120 90 60/120 90 60 50 30/g'
    sed_glob "${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi" 's/120 90 60/120 90 60 50 30/g'
    sed_glob "${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi" 's/120 90 60/120 90 60 50 30/g'
    sed_glob "${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi"  's/144 120 90 60/144 120 90 60 50 48 30/g'

    # Enable back brightness control from dtsi (safe globs)
    sed_glob "${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi"           's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g'
    sed_glob "${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi"        's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g'
    sed_glob "${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi"            's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi"         's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi"          's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi"        's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi"         's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi"             's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi"            's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g'
    sed_glob "${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi"            's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g'
    sed_glob "${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi"             's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g'
    sed_glob "${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi"          's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g'
    sed_glob "${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi"            's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g'
    sed_glob "${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi"             's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g'
    sed_glob "${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi"          's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g'
    sed_glob "${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi"            's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi"         's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi"          's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi"        's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi"         's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g'
    sed_glob "${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi"            's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g'
    sed_glob "${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi"        's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g'
  fi

  # Refresh config after dts edits
  make ${MAKE_ARGS} "${TARGET_DEVICE}_defconfig"

  # Set localversion in .config (do NOT edit defconfig file)
  cfg_set_str LOCALVERSION "${LOCALVER}"
  cfg_disable LOCALVERSION_AUTO

  # KernelSU minimal config
  if [ "${KSU_ENABLE}" -eq 1 ]; then
    cfg_enable KSU
    cfg_enable KSU_MANUAL_HOOK
  else
    cfg_disable KSU
  fi

  # MIUI-ish toggles (safe: only apply if symbols exist in this tree)
  cfg_set_str STATIC_USERMODEHELPER_PATH "/system/bin/micd"
  cfg_enable PERF_CRITICAL_RT_TASK
  cfg_enable SF_BINDER
  cfg_enable OVERLAY_FS
  cfg_disable DEBUG_FS
  cfg_enable MIGT
  cfg_enable MIGT_ENERGY_MODEL
  cfg_enable MIHW
  cfg_enable PACKAGE_RUNTIME_INFO
  cfg_enable BINDER_OPT
  cfg_enable KPERFEVENTS
  cfg_enable MILLET
  cfg_enable PERF_HUMANTASK
  cfg_enable XIAOMI_MIUI
  cfg_disable MI_MEMORY_SYSFS
  cfg_enable TASK_DELAY_ACCT
  cfg_enable MIUI_ZRAM_MEMORY_TRACKING
  cfg_disable MODULE_SIG_SHA512
  cfg_disable MODULE_SIG_HASH
  cfg_enable MI_FRAGMENTION
  cfg_enable PERF_HELPER
  cfg_enable BOOTUP_RECLAIM
  cfg_enable MI_RECLAIM
  cfg_enable RTMM

  # Reconcile config
  make ${MAKE_ARGS} olddefconfig

  # Build
  make ${MAKE_ARGS} -j"$(nproc)"

  [ -f "${OUTDIR}/arch/arm64/boot/Image" ] || die "MIUI build failed: Image not found"
  log "MIUI build OK: ${OUTDIR}/arch/arm64/boot/Image"

  # Restore dts
  if [ -d ".dts.bak" ]; then
    log "Restoring DTS backup..."
    rm -rf "${dts_source}"
    mv .dts.bak "${dts_source}"
  fi

  local ksu_str="NoKernelSU"
  [ "${KSU_ENABLE}" -eq 1 ] && ksu_str="KernelSU-Next"

  pack_anykernel "MIUI" "Kernel_MIUI" "${ksu_str}"
  log "MIUI package done."
}

# -----------------------------
# Entry
# -----------------------------
log "TARGET_DEVICE: ${TARGET_DEVICE}"
log "KSU_ENABLE: ${KSU_ENABLE}"
log "BUILD_VARIANT: ${BUILD_VARIANT}"

case "${BUILD_VARIANT}" in
  aosp)
    build_aosp
    ;;
  miui)
    build_miui
    ;;
  both)
    build_aosp
    rm -rf "${OUTDIR}"  # ensure clean between variants
    build_miui
    ;;
esac

log "Done. Flashable zip(s) are in repo root:"
ls -1 ./*.zip 2>/dev/null || true
