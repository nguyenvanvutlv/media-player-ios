#!/usr/bin/env bash
#
# Production FFmpeg → libffmpeg.xcframework for iOS + tvOS (device + simulator).
# LGPL: --disable-gpl --disable-nonfree. Builds from ./FFmpeg only (no prebuilt deps).
#
# Usage:
#   ./scripts/build-ffmpeg-xcframework.sh
#   MIN_IOS=13.0 MIN_TVOS=13.0 ./scripts/build-ffmpeg-xcframework.sh
#   SKIP_SIM_X86=1 ./scripts/build-ffmpeg-xcframework.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FFMPEG_SRC="${FFMPEG_SRC:-${REPO_ROOT}/FFmpeg}"
OUT_ROOT="${OUT_ROOT:-${REPO_ROOT}/output}"
BUILD_ROOT="${BUILD_ROOT:-${OUT_ROOT}/build}"
LICENSE_DIR="${OUT_ROOT}/LICENSE"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
BUILD_LOG="${OUT_ROOT}/ffmpeg-build.log"

MIN_IOS="${MIN_IOS:-13.0}"
MIN_TVOS="${MIN_TVOS:-13.0}"
SKIP_SIM_X86="${SKIP_SIM_X86:-0}"
: "${FFMPEG_EXTRA_CONFIGURE:=}"
: "${DEPS_BUILD_ROOT:=${REPO_ROOT}/build}"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "${FFMPEG_SRC}" ]] || die "FFmpeg sources not found: ${FFMPEG_SRC}"
[[ -f "${FFMPEG_SRC}/configure" ]] || die "Missing ${FFMPEG_SRC}/configure"

command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"
command -v xcrun >/dev/null || die "xcrun not found"
command -v libtool >/dev/null || die "libtool not found (expected /usr/bin/libtool on macOS)"
command -v pkg-config >/dev/null || die "pkg-config not found (install via Homebrew: brew install pkg-config)"

mkdir -p "${OUT_ROOT}" "${BUILD_ROOT}" "${LICENSE_DIR}"

rm -f "${BUILD_LOG}"

cp -f "${FFMPEG_SRC}/LICENSE.md" "${LICENSE_DIR}/" 2>/dev/null || true
cp -f "${FFMPEG_SRC}/COPYING.LGPLv2.1" "${LICENSE_DIR}/" 2>/dev/null || true
cp -f "${FFMPEG_SRC}/COPYING.LGPLv3" "${LICENSE_DIR}/" 2>/dev/null || true
cp -f "${REPO_ROOT}/scripts/ffmpeg/README_LGPL.md" "${OUT_ROOT}/README_LGPL.md"

STATIC_LIBS=(
  libavutil
  libavcodec
  libavformat
  libavfilter
  libswscale
  libswresample
)

#
# Whitelist build (required by refactor plan):
# - Start from nothing: --disable-everything
# - Enable only required components explicitly
#
declare -a REQ_DEMUXERS=(hls mpegts mov matroska)
declare -a REQ_DECODERS=(h264 hevc vp8 vp9 aac ac3 eac3 opus vorbis dca ass subrip webvtt)
declare -a REQ_PARSERS=(h264 hevc aac ac3)
declare -a REQ_PROTOCOLS=(http https tcp tls file crypto)

# Some components can be auto-enabled as dependencies even with `--disable-everything`.
# Keep a small explicit denylist to satisfy the required whitelist exactly.
declare -a DENY_DECODERS=(av1)
# NOTE: bash + `set -u` can treat empty arrays as "unbound" in some environments.
# Use a sentinel value to represent "no entries".
declare -a DENY_PARSERS=(__none__)

merge_static_libs() {
  local out="$1"
  shift
  local args=()
  local lib
  for lib in "$@"; do
    [[ -f "$lib" ]] || die "missing archive: $lib"
    args+=("$lib")
  done
  rm -f "${out}"
  libtool -static -o "${out}" "${args[@]}"
}

FAKE_PREFIX="/ffmpeg"

build_deps() {
  # Builds static freetype/fribidi/harfbuzz/libass for all FFmpeg slices.
  # Output prefixes:
  #   ${DEPS_BUILD_ROOT}/{slice}/prefix
  BUILD_ROOT="${DEPS_BUILD_ROOT}" \
  MIN_IOS="${MIN_IOS}" \
  MIN_TVOS="${MIN_TVOS}" \
  SKIP_SIM_X86="${SKIP_SIM_X86}" \
  JOBS="${JOBS}" \
    "${REPO_ROOT}/scripts/build-deps.sh"
}

# Best-effort guardrail: prevent pkg-config from resolving host .pc files.
# We intentionally want ONLY per-slice, cross-compiled deps.
pkg_config_env_for_prefix() {
  local deps_prefix="$1"
  echo "PKG_CONFIG_DIR=" \
       "PKG_CONFIG_LIBDIR=${deps_prefix}/lib/pkgconfig" \
       "PKG_CONFIG_PATH=${deps_prefix}/lib/pkgconfig"
}

assert_no_host_libs_in_pkg_config() {
  local name="$1"
  local deps_prefix="$2"
  local sysroot="$3"

  local pc_env libs cflags
  pc_env="$(pkg_config_env_for_prefix "${deps_prefix}")"

  # shellcheck disable=SC2086
  libs="$(env ${pc_env} PKG_CONFIG_SYSROOT_DIR="${sysroot}" pkg-config --libs --static libass 2>/dev/null || true)"
  # shellcheck disable=SC2086
  cflags="$(env ${pc_env} PKG_CONFIG_SYSROOT_DIR="${sysroot}" pkg-config --cflags libass 2>/dev/null || true)"

  # Reject obvious host paths. (SDK frameworks are fine; Homebrew/system dylib paths are not.)
  if echo "${libs} ${cflags}" | grep -Eq '(/usr/local|/opt/homebrew|/usr/lib( |$))'; then
    echo "error: ${name}: pkg-config for libass contains host paths:" >&2
    echo "  cflags: ${cflags}" >&2
    echo "  libs:   ${libs}" >&2
    return 1
  fi
}

# Returns path to merged libffmpeg.a on stdout; 0 on success, 1 on failure.
run_configure_make_install() {
  local name="$1"
  local sdk="$2"
  local clang_arch="$3"
  local min_cflags="$4"
  local min_ldflags="$5"
  local asm_flags="$6"

  local deps_prefix="${DEPS_BUILD_ROOT}/${name}/prefix"
  [[ -d "${deps_prefix}/include" ]] || die "missing deps prefix for ${name}: ${deps_prefix} (run scripts/build-deps.sh)"
  [[ -f "${deps_prefix}/lib/pkgconfig/libass.pc" ]] || die "missing libass.pc for ${name}: ${deps_prefix}/lib/pkgconfig/libass.pc"

  local build_dir="${BUILD_ROOT}/${name}"
  local staging="${BUILD_ROOT}/${name}-install"
  rm -rf "${build_dir}" "${staging}"
  mkdir -p "${build_dir}" "${staging}"

  local sysroot
  sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  [[ -d "${sysroot}" ]] || { echo "Bad SDK path for ${sdk}: ${sysroot}" >&2; return 1; }

  assert_no_host_libs_in_pkg_config "${name}" "${deps_prefix}" "${sysroot}"

  local cc cxx ar ranlib strip nm
  cc="xcrun -sdk ${sdk} clang"
  cxx="xcrun -sdk ${sdk} clang++"
  ar="xcrun -sdk ${sdk} ar"
  ranlib="xcrun -sdk ${sdk} ranlib"
  strip="xcrun -sdk ${sdk} strip"
  nm="xcrun -sdk ${sdk} nm"

  local ff_arch="${clang_arch}"
  if [[ "${clang_arch}" == "arm64" ]]; then
    ff_arch="aarch64"
  fi

  local cflags="-arch ${clang_arch} -isysroot ${sysroot} ${min_cflags}"
  local ldflags="-arch ${clang_arch} -isysroot ${sysroot} ${min_ldflags}"

  # External deps (libass + freetype/fribidi/harfbuzz) are built per-slice under ${DEPS_BUILD_ROOT}.
  # Wire them into configure via pkg-config + explicit include/lib paths.
  local deps_cflags="-I${deps_prefix}/include"
  local deps_ldflags="-L${deps_prefix}/lib"
  local pkg_config_path="${deps_prefix}/lib/pkgconfig"

  local enable_demuxers=()
  local enable_decoders=()
  local enable_parsers=()
  local enable_protocols=()
  local disable_decoders=()
  local disable_parsers_flags=""
  local item
  for item in "${REQ_DEMUXERS[@]}"; do enable_demuxers+=("--enable-demuxer=${item}"); done
  for item in "${REQ_DECODERS[@]}"; do enable_decoders+=("--enable-decoder=${item}"); done
  for item in "${REQ_PARSERS[@]}"; do enable_parsers+=("--enable-parser=${item}"); done
  for item in "${REQ_PROTOCOLS[@]}"; do enable_protocols+=("--enable-protocol=${item}"); done
  for item in "${DENY_DECODERS[@]}"; do disable_decoders+=("--disable-decoder=${item}"); done
  for item in "${DENY_PARSERS[@]}"; do
    [[ "${item}" == "__none__" ]] && continue
    disable_parsers_flags+=" --disable-parser=${item}"
  done

  pushd "${build_dir}" >/dev/null

  {
    echo "=== ${name} ==="
    echo "sdk=${sdk} arch=${clang_arch} ff_arch=${ff_arch}"
    echo "configure whitelist:"
    echo "  demuxers:   ${REQ_DEMUXERS[*]}"
    echo "  decoders:   ${REQ_DECODERS[*]}"
    echo "  parsers:    ${REQ_PARSERS[*]}"
    echo "  protocols:  ${REQ_PROTOCOLS[*]}"
    echo "  extra:      ${FFMPEG_EXTRA_CONFIGURE:-<none>}"
    echo
  } >> "${BUILD_LOG}"

  # shellcheck disable=SC2086
  if ! \
  env \
    PKG_CONFIG_DIR= \
    PKG_CONFIG_LIBDIR="${pkg_config_path}" \
    PKG_CONFIG_PATH="${pkg_config_path}" \
    PKG_CONFIG_SYSROOT_DIR="${sysroot}" \
  "${FFMPEG_SRC}/configure" \
    --prefix="${FAKE_PREFIX}" \
    --cc="${cc}" \
    --cxx="${cxx}" \
    --ar="${ar}" \
    --ranlib="${ranlib}" \
    --strip="${strip}" \
    --nm="${nm}" \
    --sysroot="${sysroot}" \
    --arch="${ff_arch}" \
    --target-os=darwin \
    --enable-cross-compile \
    ${asm_flags} \
    --disable-everything \
    --disable-programs \
    --disable-doc \
    --disable-avdevice \
    --enable-pic \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --disable-gpl \
    --disable-nonfree \
    --enable-avcodec \
    --enable-avformat \
    --enable-avutil \
    --enable-swscale \
    --enable-swresample \
    --enable-avfilter \
    --enable-libass \
    --enable-filter=ass \
    --enable-filter=subtitles \
    --disable-encoders \
    --disable-muxers \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    --enable-hwaccel=h264_videotoolbox \
    --enable-hwaccel=hevc_videotoolbox \
    --pkg-config-flags="--static" \
    "${enable_demuxers[@]}" \
    "${enable_decoders[@]}" \
    "${enable_parsers[@]}" \
    "${enable_protocols[@]}" \
    "${disable_decoders[@]}" \
    ${disable_parsers_flags} \
    --extra-cflags="${cflags} ${deps_cflags}" \
    --extra-ldflags="${ldflags} ${deps_ldflags}" \
    --extra-libs="-lass -lharfbuzz -lfribidi -lfreetype" \
    ${FFMPEG_EXTRA_CONFIGURE} \
    2>&1 | tee -a "${BUILD_LOG}" >&2
  then
    popd >/dev/null
    return 1
  fi

  if ! make -j"${JOBS}" 2>&1 | tee -a "${BUILD_LOG}" >&2; then
    popd >/dev/null
    return 1
  fi
  if ! make install DESTDIR="${staging}" 2>&1 | tee -a "${BUILD_LOG}" >&2; then
    popd >/dev/null
    return 1
  fi

  # Persist build evidence per-slice for auditing/repro:
  mkdir -p "${OUT_ROOT}/ffmpeg-config/${name}"
  cp -f "${build_dir}/ffbuild/config.log" "${OUT_ROOT}/ffmpeg-config/${name}/config.log" 2>/dev/null || true
  cp -f "${build_dir}/ffbuild/config.mak" "${OUT_ROOT}/ffmpeg-config/${name}/config.mak" 2>/dev/null || true
  cp -f "${build_dir}/config.h" "${OUT_ROOT}/ffmpeg-config/${name}/config.h" 2>/dev/null || true

  # Emit a small, parseable enabled-components report from config.mak.
  # Note: `--disable-everything` + explicit enables should make these lists tight.
  if [[ -f "${build_dir}/ffbuild/config.mak" ]]; then
    {
      echo "# ${name} enabled components (from ffbuild/config.mak)"
      echo "[demuxers]"
      grep -E '^CONFIG_[A-Za-z0-9_]+_DEMUXER=yes$' "${build_dir}/ffbuild/config.mak" | sed -E 's/^CONFIG_//; s/_DEMUXER=yes$//; s/_/./g' | sort
      echo
      echo "[decoders]"
      grep -E '^CONFIG_[A-Za-z0-9_]+_DECODER=yes$' "${build_dir}/ffbuild/config.mak" | sed -E 's/^CONFIG_//; s/_DECODER=yes$//; s/_/./g' | sort
      echo
      echo "[parsers]"
      grep -E '^CONFIG_[A-Za-z0-9_]+_PARSER=yes$' "${build_dir}/ffbuild/config.mak" | sed -E 's/^CONFIG_//; s/_PARSER=yes$//; s/_/./g' | sort
      echo
      echo "[protocols]"
      grep -E '^CONFIG_[A-Za-z0-9_]+_PROTOCOL=yes$' "${build_dir}/ffbuild/config.mak" | sed -E 's/^CONFIG_//; s/_PROTOCOL=yes$//; s/_/./g' | sort
      echo
      echo "[hwaccels]"
      grep -E '^CONFIG_[A-Za-z0-9_]+_HWACCEL=yes$' "${build_dir}/ffbuild/config.mak" | sed -E 's/^CONFIG_//; s/_HWACCEL=yes$//; s/_/./g' | sort
    } > "${OUT_ROOT}/ffmpeg-config/${name}/enabled-components.txt"
  fi

  popd >/dev/null

  local prefix="${staging}${FAKE_PREFIX}"
  [[ -d "${prefix}/lib" ]] || { echo "Expected ${prefix}/lib after install" >&2; return 1; }

  mkdir -p "${BUILD_ROOT}/dist/${name}"
  local merged="${BUILD_ROOT}/dist/${name}/libffmpeg.a"
  local lib_paths=()
  local lib
  for lib in "${STATIC_LIBS[@]}"; do
    lib_paths+=("${prefix}/lib/${lib}.a")
  done
  merge_static_libs "${merged}" "${lib_paths[@]}"

  mkdir -p "${BUILD_ROOT}/${name}-libs"
  for lib in "${STATIC_LIBS[@]}"; do
    cp -f "${prefix}/lib/${lib}.a" "${BUILD_ROOT}/${name}-libs/"
  done

  printf '%s' "${merged}"
  return 0
}

# Simulator: try NEON/asm first; on failure retry with --disable-asm (and --disable-neon on arm64).
run_sim_build_with_asm_fallback() {
  local base_name="$1"
  local sdk="$2"
  local clang_arch="$3"
  local min_c="$4"
  local min_l="$5"
  local primary_asm="$6"
  local fallback_asm="$7"

  local out
  if out="$(run_configure_make_install "${base_name}" "${sdk}" "${clang_arch}" "${min_c}" "${min_l}" "${primary_asm}")"; then
    printf '%s' "${out}"
    return 0
  fi
  echo "WARN: ${base_name} failed with ASM flags [${primary_asm}], retrying with [${fallback_asm}]" >&2
  rm -rf "${BUILD_ROOT}/${base_name}" "${BUILD_ROOT}/${base_name}-install"
  run_configure_make_install "${base_name}-noasm" "${sdk}" "${clang_arch}" "${min_c}" "${min_l}" "${fallback_asm}"
}

build_deps

# --- iOS device (arm64) ---
IOS_DEVICE_LIB="$(run_configure_make_install \
  "ios-arm64" \
  "iphoneos" \
  "arm64" \
  "-miphoneos-version-min=${MIN_IOS}" \
  "-miphoneos-version-min=${MIN_IOS}" \
  "--enable-asm --enable-neon")" || die "iOS device build failed"

# --- iOS simulator arm64 (ASM fallback) ---
IOS_SIM_ARM64_LIB="$(run_sim_build_with_asm_fallback \
  "ios-sim-arm64" \
  "iphonesimulator" \
  "arm64" \
  "-mios-simulator-version-min=${MIN_IOS}" \
  "-mios-simulator-version-min=${MIN_IOS}" \
  "--enable-asm --enable-neon" \
  "--disable-asm --disable-neon")" || die "iOS sim arm64 build failed"

IOS_SIM_X86_LIB=""
if [[ "${SKIP_SIM_X86}" != "1" ]]; then
  IOS_SIM_X86_LIB="$(run_sim_build_with_asm_fallback \
    "ios-sim-x86_64" \
    "iphonesimulator" \
    "x86_64" \
    "-mios-simulator-version-min=${MIN_IOS}" \
    "-mios-simulator-version-min=${MIN_IOS}" \
    "--enable-asm --disable-neon" \
    "--disable-asm --disable-neon")" || die "iOS sim x86_64 build failed"
fi

# --- tvOS device (arm64) ---
TVOS_DEVICE_LIB="$(run_configure_make_install \
  "tvos-arm64" \
  "appletvos" \
  "arm64" \
  "-mtvos-version-min=${MIN_TVOS}" \
  "-mtvos-version-min=${MIN_TVOS}" \
  "--enable-asm --enable-neon")" || die "tvOS device build failed"

# --- tvOS simulator arm64 (ASM fallback) ---
TVOS_SIM_ARM64_LIB="$(run_sim_build_with_asm_fallback \
  "tvos-sim-arm64" \
  "appletvsimulator" \
  "arm64" \
  "-mtvos-simulator-version-min=${MIN_TVOS}" \
  "-mtvos-simulator-version-min=${MIN_TVOS}" \
  "--enable-asm --enable-neon" \
  "--disable-asm --disable-neon")" || die "tvOS sim arm64 build failed"

TVOS_SIM_X86_LIB=""
if [[ "${SKIP_SIM_X86}" != "1" ]]; then
  TVOS_SIM_X86_LIB="$(run_sim_build_with_asm_fallback \
    "tvos-sim-x86_64" \
    "appletvsimulator" \
    "x86_64" \
    "-mtvos-simulator-version-min=${MIN_TVOS}" \
    "-mtvos-simulator-version-min=${MIN_TVOS}" \
    "--enable-asm --disable-neon" \
    "--disable-asm --disable-neon")" || die "tvOS sim x86_64 build failed"
fi

IOS_SIM_UNI="${BUILD_ROOT}/dist/ios-simulator-universal/libffmpeg.a"
TVOS_SIM_UNI="${BUILD_ROOT}/dist/tvos-simulator-universal/libffmpeg.a"
mkdir -p "${BUILD_ROOT}/dist/ios-simulator-universal" "${BUILD_ROOT}/dist/tvos-simulator-universal"

if [[ -n "${IOS_SIM_X86_LIB}" ]]; then
  lipo -create "${IOS_SIM_ARM64_LIB}" "${IOS_SIM_X86_LIB}" -output "${IOS_SIM_UNI}"
else
  cp -f "${IOS_SIM_ARM64_LIB}" "${IOS_SIM_UNI}"
fi

if [[ -n "${TVOS_SIM_X86_LIB}" ]]; then
  lipo -create "${TVOS_SIM_ARM64_LIB}" "${TVOS_SIM_X86_LIB}" -output "${TVOS_SIM_UNI}"
else
  cp -f "${TVOS_SIM_ARM64_LIB}" "${TVOS_SIM_UNI}"
fi

HEADER_SRC="${BUILD_ROOT}/ios-arm64-install${FAKE_PREFIX}/include"
[[ -d "${HEADER_SRC}" ]] || die "Missing headers: ${HEADER_SRC}"

rm -rf "${OUT_ROOT}/ffmpeg-headers"
mkdir -p "${OUT_ROOT}/ffmpeg-headers"
cp -R "${HEADER_SRC}/." "${OUT_ROOT}/ffmpeg-headers/"

cat > "${OUT_ROOT}/ffmpeg-headers/libffmpeg-umbrella.h" <<'EOF'
/* Umbrella header for Swift / Obj-C bridging (optional). */
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/codec_par.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
EOF

XCFW="${OUT_ROOT}/libffmpeg.xcframework"
rm -rf "${XCFW}"

xcodebuild -create-xcframework \
  -library "${IOS_DEVICE_LIB}" \
  -headers "${OUT_ROOT}/ffmpeg-headers" \
  -library "${IOS_SIM_UNI}" \
  -headers "${OUT_ROOT}/ffmpeg-headers" \
  -library "${TVOS_DEVICE_LIB}" \
  -headers "${OUT_ROOT}/ffmpeg-headers" \
  -library "${TVOS_SIM_UNI}" \
  -headers "${OUT_ROOT}/ffmpeg-headers" \
  -output "${XCFW}"

# Resolve install lib paths (prefer successful -noasm tree if present)
resolve_sim_lib_prefix() {
  local base="$1"
  if [[ -d "${BUILD_ROOT}/${base}-noasm-install${FAKE_PREFIX}/lib" ]]; then
    echo "${BUILD_ROOT}/${base}-noasm-install${FAKE_PREFIX}/lib"
  else
    echo "${BUILD_ROOT}/${base}-install${FAKE_PREFIX}/lib"
  fi
}

IOS_SIM_ARM_PREFIX="$(resolve_sim_lib_prefix "ios-sim-arm64")"
IOS_SIM_X86_PREFIX="$(resolve_sim_lib_prefix "ios-sim-x86_64")"
TVOS_SIM_ARM_PREFIX="$(resolve_sim_lib_prefix "tvos-sim-arm64")"
TVOS_SIM_X86_PREFIX="$(resolve_sim_lib_prefix "tvos-sim-x86_64")"

copy_individual_libs_to_slice() {
  local slice="$1"
  local which="$2"
  local libname
  case "${which}" in
    ios_device)
      for libname in "${STATIC_LIBS[@]}"; do
        cp -f "${BUILD_ROOT}/ios-arm64-libs/${libname}.a" "${slice}/"
      done
      ;;
    ios_sim)
      if [[ -n "${IOS_SIM_X86_LIB}" && -n "${IOS_SIM_ARM_PREFIX}" && -n "${IOS_SIM_X86_PREFIX}" ]]; then
        for libname in "${STATIC_LIBS[@]}"; do
          lipo -create \
            "${IOS_SIM_ARM_PREFIX}/${libname}.a" \
            "${IOS_SIM_X86_PREFIX}/${libname}.a" \
            -output "${slice}/${libname}.a"
        done
      else
        for libname in "${STATIC_LIBS[@]}"; do
          cp -f "${IOS_SIM_ARM_PREFIX}/${libname}.a" "${slice}/"
        done
      fi
      ;;
    tvos_device)
      for libname in "${STATIC_LIBS[@]}"; do
        cp -f "${BUILD_ROOT}/tvos-arm64-libs/${libname}.a" "${slice}/"
      done
      ;;
    tvos_sim)
      if [[ -n "${TVOS_SIM_X86_LIB}" && -n "${TVOS_SIM_ARM_PREFIX}" && -n "${TVOS_SIM_X86_PREFIX}" ]]; then
        for libname in "${STATIC_LIBS[@]}"; do
          lipo -create \
            "${TVOS_SIM_ARM_PREFIX}/${libname}.a" \
            "${TVOS_SIM_X86_PREFIX}/${libname}.a" \
            -output "${slice}/${libname}.a"
        done
      else
        for libname in "${STATIC_LIBS[@]}"; do
          cp -f "${TVOS_SIM_ARM_PREFIX}/${libname}.a" "${slice}/"
        done
      fi
      ;;
  esac
}

shopt -s nullglob
for slice in "${XCFW}"/*; do
  [[ -d "${slice}" ]] || continue
  base="$(basename "${slice}")"
  case "${base}" in
    ios-arm64)
      copy_individual_libs_to_slice "${slice}" ios_device
      ;;
    ios-arm64_x86_64-simulator|ios-arm64-simulator)
      copy_individual_libs_to_slice "${slice}" ios_sim
      ;;
    tvos-arm64)
      copy_individual_libs_to_slice "${slice}" tvos_device
      ;;
    tvos-arm64_x86_64-simulator|tvos-arm64-simulator)
      copy_individual_libs_to_slice "${slice}" tvos_sim
      ;;
  esac
done
shopt -u nullglob

cp -f "${REPO_ROOT}/scripts/ffmpeg/xcode-link-flags.xcconfig" "${OUT_ROOT}/"

echo "" >&2
echo "Built: ${XCFW}" >&2
echo "Docs:  ${OUT_ROOT}/README_LGPL.md" >&2
echo "Licenses: ${LICENSE_DIR}/" >&2
echo "Linker flags sample: ${OUT_ROOT}/xcode-link-flags.xcconfig" >&2
echo "Build log: ${BUILD_LOG}" >&2
echo "Config snapshots: ${OUT_ROOT}/ffmpeg-config/" >&2
