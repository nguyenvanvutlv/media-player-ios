#!/usr/bin/env bash
#
# Build FFmpeg + libass as dynamic frameworks and package as xcframeworks
# for iOS/tvOS (device + simulator).
#
# Output:
#   output/ffmpeg-dynamic/*.xcframework
#
# Notes:
# - Keeps the same “whitelist build” approach as the static script.
# - Builds libass as a dylib (DEPS_LIBASS_DYNAMIC=1) while keeping freetype/fribidi/harfbuzz static.
# - Produces per-library xcframeworks:
#     libavutil, libavcodec, libavformat, libavfilter, libswscale, libswresample, libass
#
# Usage:
#   ./scripts/build-ffmpeg-dynamic-xcframework.sh
#   MIN_IOS=13.0 MIN_TVOS=13.0 ./scripts/build-ffmpeg-dynamic-xcframework.sh
#   SKIP_SIM_X86=1 ./scripts/build-ffmpeg-dynamic-xcframework.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FFMPEG_SRC="${FFMPEG_SRC:-${REPO_ROOT}/FFmpeg}"
OUT_ROOT="${OUT_ROOT:-${REPO_ROOT}/output}"
OUT_DIR="${OUT_ROOT}/ffmpeg-dynamic"
BUILD_ROOT="${BUILD_ROOT:-${OUT_ROOT}/build-dynamic}"
DEPS_BUILD_ROOT="${DEPS_BUILD_ROOT:-${REPO_ROOT}/build-dynamic}"
LICENSE_DIR="${OUT_DIR}/LICENSE"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
BUILD_LOG="${OUT_DIR}/ffmpeg-dynamic-build.log"

MIN_IOS="${MIN_IOS:-13.0}"
MIN_TVOS="${MIN_TVOS:-13.0}"
SKIP_SIM_X86="${SKIP_SIM_X86:-0}"
: "${FFMPEG_EXTRA_CONFIGURE:=}"

die() { echo "error: $*" >&2; exit 1; }

[[ -d "${FFMPEG_SRC}" ]] || die "FFmpeg sources not found: ${FFMPEG_SRC}"
[[ -f "${FFMPEG_SRC}/configure" ]] || die "Missing ${FFMPEG_SRC}/configure"

command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"
command -v xcrun >/dev/null || die "xcrun not found"
command -v install_name_tool >/dev/null || die "install_name_tool not found"
command -v otool >/dev/null || die "otool not found"
command -v pkg-config >/dev/null || die "pkg-config not found (brew install pkg-config)"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}" "${BUILD_ROOT}" "${DEPS_BUILD_ROOT}" "${LICENSE_DIR}"
rm -f "${BUILD_LOG}"

cp -f "${FFMPEG_SRC}/LICENSE.md" "${LICENSE_DIR}/" 2>/dev/null || true
cp -f "${FFMPEG_SRC}/COPYING.LGPLv2.1" "${LICENSE_DIR}/" 2>/dev/null || true
cp -f "${FFMPEG_SRC}/COPYING.LGPLv3" "${LICENSE_DIR}/" 2>/dev/null || true

FFMPEG_LIBS=(
  libavutil
  libavcodec
  libavformat
  libavfilter
  libswscale
  libswresample
)

declare -a REQ_DEMUXERS=(hls mpegts mov matroska)
declare -a REQ_DECODERS=(h264 hevc vp8 vp9 aac ac3 eac3 opus vorbis dca ass subrip webvtt)
declare -a REQ_PARSERS=(h264 hevc aac ac3)
declare -a REQ_PROTOCOLS=(http https tcp tls file crypto)
declare -a DENY_DECODERS=(av1)
declare -a DENY_PARSERS=(__none__)

FAKE_PREFIX="/ffmpeg"

build_deps_dynamic_libass() {
  BUILD_ROOT="${DEPS_BUILD_ROOT}" \
  MIN_IOS="${MIN_IOS}" \
  MIN_TVOS="${MIN_TVOS}" \
  SKIP_SIM_X86="${SKIP_SIM_X86}" \
  JOBS="${JOBS}" \
  DEPS_LIBASS_DYNAMIC=1 \
    "${REPO_ROOT}/scripts/build-deps.sh"
}

assert_no_host_libs_in_pkg_config() {
  local name="$1"
  local deps_prefix="$2"
  local sysroot="$3"
  local libs cflags
  libs="$(env PKG_CONFIG_DIR= PKG_CONFIG_LIBDIR="${deps_prefix}/lib/pkgconfig" PKG_CONFIG_PATH="${deps_prefix}/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="${sysroot}" pkg-config --libs libass 2>/dev/null || true)"
  cflags="$(env PKG_CONFIG_DIR= PKG_CONFIG_LIBDIR="${deps_prefix}/lib/pkgconfig" PKG_CONFIG_PATH="${deps_prefix}/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="${sysroot}" pkg-config --cflags libass 2>/dev/null || true)"
  if echo "${libs} ${cflags}" | grep -Eq '(/usr/local|/opt/homebrew|/usr/lib( |$))'; then
    echo "error: ${name}: pkg-config for libass contains host paths:" >&2
    echo "  cflags: ${cflags}" >&2
    echo "  libs:   ${libs}" >&2
    return 1
  fi
}

run_configure_make_install_shared() {
  local name="$1"
  local sdk="$2"
  local clang_arch="$3"
  local min_cflags="$4"
  local min_ldflags="$5"
  local asm_flags="$6"

  local deps_prefix="${DEPS_BUILD_ROOT}/${name}/prefix"
  [[ -d "${deps_prefix}/include" ]] || die "missing deps prefix for ${name}: ${deps_prefix} (run build-deps)"
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
    echo "extra: ${FFMPEG_EXTRA_CONFIGURE:-<none>}"
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
    --disable-static \
    --enable-shared \
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
    "${enable_demuxers[@]}" \
    "${enable_decoders[@]}" \
    "${enable_parsers[@]}" \
    "${enable_protocols[@]}" \
    "${disable_decoders[@]}" \
    ${disable_parsers_flags} \
    --extra-cflags="${cflags} -I${deps_prefix}/include" \
    --extra-ldflags="${ldflags} -L${deps_prefix}/lib" \
    --extra-libs="-lass" \
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

  popd >/dev/null
  printf '%s' "${staging}${FAKE_PREFIX}"
}

run_sim_build_with_asm_fallback() {
  local base_name="$1"
  local sdk="$2"
  local clang_arch="$3"
  local min_c="$4"
  local min_l="$5"
  local primary_asm="$6"
  local fallback_asm="$7"

  local out
  if out="$(run_configure_make_install_shared "${base_name}" "${sdk}" "${clang_arch}" "${min_c}" "${min_l}" "${primary_asm}")"; then
    printf '%s' "${out}"
    return 0
  fi
  echo "WARN: ${base_name} failed with ASM flags [${primary_asm}], retrying with [${fallback_asm}]" >&2
  rm -rf "${BUILD_ROOT}/${base_name}" "${BUILD_ROOT}/${base_name}-install"
  run_configure_make_install_shared "${base_name}-noasm" "${sdk}" "${clang_arch}" "${min_c}" "${min_l}" "${fallback_asm}"
}

real_dylib_path() {
  local libdir="$1"
  local base="$2" # e.g. libavcodec
  local p="${libdir}/${base}.dylib"
  [[ -e "${p}" ]] || die "missing ${p}"
  python3 - "${p}" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
}

create_framework_from_dylib() {
  local out_dir="$1"     # slice output directory
  local name="$2"        # e.g. libavcodec
  local dylib="$3"       # resolved dylib file
  local headers_dir="$4" # shared headers root to copy

  local fw="${out_dir}/${name}.framework"
  rm -rf "${fw}"
  mkdir -p "${fw}/Headers" "${fw}/Modules"

  cp -R "${headers_dir}/." "${fw}/Headers/"

  # Framework binary name is the library name without extension.
  cp -f "${dylib}" "${fw}/${name}"

  # Minimal Info.plist is required for app bundle validation.
  python3 - "${fw}/Info.plist" "${name}" <<'PY'
import plistlib, sys
path=sys.argv[1]
name=sys.argv[2]
plist={
  'CFBundleDevelopmentRegion': 'en',
  'CFBundleExecutable': name,
  'CFBundleIdentifier': f'com.nvv.player.{name}',
  'CFBundleInfoDictionaryVersion': '6.0',
  'CFBundlePackageType': 'FMWK',
  'CFBundleShortVersionString': '1.0',
  'CFBundleVersion': '1',
}
with open(path,'wb') as f:
  plistlib.dump(plist,f)
PY

  cat > "${fw}/Modules/module.modulemap" <<EOF
framework module ${name} {
  umbrella "Headers"
  export *
  module * { export * }
}
EOF

  # Set a framework-style install name.
  install_name_tool -id "@rpath/${name}.framework/${name}" "${fw}/${name}"
}

patch_ffmpeg_install_names_in_framework() {
  local fw_bin="$1"
  shift
  local all_names=("$@")

  local dep
  for dep in "${all_names[@]}"; do
    # Replace both versioned and unversioned install names with @rpath framework paths.
    local current
    while read -r current; do
      [[ -z "${current}" ]] && continue
      install_name_tool -change "${current}" "@rpath/${dep}.framework/${dep}" "${fw_bin}" || true
    done < <(otool -L "${fw_bin}" | awk '{print $1}' | grep -E "/${dep}(\.[0-9]+)*\.dylib$" || true)
  done

  # libass may appear as libass.9.dylib or libass.dylib depending on build system.
  while read -r current; do
    [[ -z "${current}" ]] && continue
    install_name_tool -change "${current}" "@rpath/libass.framework/libass" "${fw_bin}" || true
  done < <(otool -L "${fw_bin}" | awk '{print $1}' | grep -E "/libass(\.[0-9]+)*\.dylib$" || true)
}

make_universal_sim_framework() {
  local out_fw="$1"       # output universal framework path
  local arm_fw="$2"       # arm64 framework path
  local x86_fw="$3"       # x86_64 framework path (may be empty)
  local name="$4"         # lib name

  rm -rf "${out_fw}"
  mkdir -p "$(dirname "${out_fw}")"
  cp -R "${arm_fw}" "${out_fw}"

  if [[ -n "${x86_fw}" ]]; then
    lipo -create "${arm_fw}/${name}" "${x86_fw}/${name}" -output "${out_fw}/${name}"
  fi
}

build_deps_dynamic_libass

IOS_DEVICE_PREFIX="$(run_configure_make_install_shared \
  "ios-arm64" "iphoneos" "arm64" \
  "-miphoneos-version-min=${MIN_IOS}" "-miphoneos-version-min=${MIN_IOS}" \
  "--enable-asm --enable-neon")" || die "iOS device build failed"

IOS_SIM_ARM64_PREFIX="$(run_sim_build_with_asm_fallback \
  "ios-sim-arm64" "iphonesimulator" "arm64" \
  "-mios-simulator-version-min=${MIN_IOS}" "-mios-simulator-version-min=${MIN_IOS}" \
  "--enable-asm --enable-neon" "--disable-asm --disable-neon")" || die "iOS sim arm64 build failed"

IOS_SIM_X86_PREFIX=""
if [[ "${SKIP_SIM_X86}" != "1" ]]; then
  IOS_SIM_X86_PREFIX="$(run_sim_build_with_asm_fallback \
    "ios-sim-x86_64" "iphonesimulator" "x86_64" \
    "-mios-simulator-version-min=${MIN_IOS}" "-mios-simulator-version-min=${MIN_IOS}" \
    "--enable-asm --disable-neon" "--disable-asm --disable-neon")" || die "iOS sim x86_64 build failed"
fi

TVOS_DEVICE_PREFIX="$(run_configure_make_install_shared \
  "tvos-arm64" "appletvos" "arm64" \
  "-mtvos-version-min=${MIN_TVOS}" "-mtvos-version-min=${MIN_TVOS}" \
  "--enable-asm --enable-neon")" || die "tvOS device build failed"

TVOS_SIM_ARM64_PREFIX="$(run_sim_build_with_asm_fallback \
  "tvos-sim-arm64" "appletvsimulator" "arm64" \
  "-mtvos-simulator-version-min=${MIN_TVOS}" "-mtvos-simulator-version-min=${MIN_TVOS}" \
  "--enable-asm --enable-neon" "--disable-asm --disable-neon")" || die "tvOS sim arm64 build failed"

TVOS_SIM_X86_PREFIX=""
if [[ "${SKIP_SIM_X86}" != "1" ]]; then
  TVOS_SIM_X86_PREFIX="$(run_sim_build_with_asm_fallback \
    "tvos-sim-x86_64" "appletvsimulator" "x86_64" \
    "-mtvos-simulator-version-min=${MIN_TVOS}" "-mtvos-simulator-version-min=${MIN_TVOS}" \
    "--enable-asm --disable-neon" "--disable-asm --disable-neon")" || die "tvOS sim x86_64 build failed"
fi

# Headers: keep behavior consistent with the static build script (use iOS arm64 headers for all slices).
FFMPEG_HEADERS="${OUT_DIR}/Headers-ffmpeg"
LIBASS_HEADERS="${OUT_DIR}/Headers-libass"
rm -rf "${FFMPEG_HEADERS}" "${LIBASS_HEADERS}"
mkdir -p "${FFMPEG_HEADERS}" "${LIBASS_HEADERS}"
cp -R "${IOS_DEVICE_PREFIX}/include/." "${FFMPEG_HEADERS}/"
cp -R "${DEPS_BUILD_ROOT}/ios-arm64/prefix/include/ass" "${LIBASS_HEADERS}/"

ALL_FFMPEG_NAMES=("${FFMPEG_LIBS[@]}")

make_slice_frameworks() {
  local slice="$1"          # label for directory naming
  local ff_prefix="$2"      # ffmpeg install prefix
  local deps_prefix="$3"    # deps prefix containing libass dylib

  local out="${BUILD_ROOT}/frameworks/${slice}"
  rm -rf "${out}"
  mkdir -p "${out}"

  local libdir="${ff_prefix}/lib"
  local deps_libdir="${deps_prefix}/lib"

  # libass framework first (so we can patch ffmpeg deps to @rpath/libass.framework/libass).
  local libass_dylib=""
  if [[ -e "${deps_libdir}/libass.dylib" ]]; then
    libass_dylib="$(python3 - "${deps_libdir}/libass.dylib" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
  else
    # meson may version the dylib, keep it robust.
    libass_dylib="$(ls -1 "${deps_libdir}/libass."*.dylib 2>/dev/null | head -n 1 || true)"
    [[ -n "${libass_dylib}" ]] || die "missing libass dylib under ${deps_libdir}"
  fi

  create_framework_from_dylib "${out}" "libass" "${libass_dylib}" "${LIBASS_HEADERS}"

  local n dylib
  for n in "${FFMPEG_LIBS[@]}"; do
    dylib="$(real_dylib_path "${libdir}" "${n}")"
    create_framework_from_dylib "${out}" "${n}" "${dylib}" "${FFMPEG_HEADERS}"
  done

  # Patch cross-dependencies to framework-style @rpath paths.
  for n in "libass" "${FFMPEG_LIBS[@]}"; do
    local bin="${out}/${n}.framework/${n}"
    patch_ffmpeg_install_names_in_framework "${bin}" "${ALL_FFMPEG_NAMES[@]}"
  done

  printf '%s' "${out}"
}

IOS_DEVICE_FW_DIR="$(make_slice_frameworks "ios-arm64" "${IOS_DEVICE_PREFIX}" "${DEPS_BUILD_ROOT}/ios-arm64/prefix")"
IOS_SIM_ARM64_FW_DIR="$(make_slice_frameworks "ios-sim-arm64" "${IOS_SIM_ARM64_PREFIX}" "${DEPS_BUILD_ROOT}/ios-sim-arm64/prefix")"
IOS_SIM_X86_FW_DIR=""
if [[ -n "${IOS_SIM_X86_PREFIX}" ]]; then
  IOS_SIM_X86_FW_DIR="$(make_slice_frameworks "ios-sim-x86_64" "${IOS_SIM_X86_PREFIX}" "${DEPS_BUILD_ROOT}/ios-sim-x86_64/prefix")"
fi
TVOS_DEVICE_FW_DIR="$(make_slice_frameworks "tvos-arm64" "${TVOS_DEVICE_PREFIX}" "${DEPS_BUILD_ROOT}/tvos-arm64/prefix")"
TVOS_SIM_ARM64_FW_DIR="$(make_slice_frameworks "tvos-sim-arm64" "${TVOS_SIM_ARM64_PREFIX}" "${DEPS_BUILD_ROOT}/tvos-sim-arm64/prefix")"
TVOS_SIM_X86_FW_DIR=""
if [[ -n "${TVOS_SIM_X86_PREFIX}" ]]; then
  TVOS_SIM_X86_FW_DIR="$(make_slice_frameworks "tvos-sim-x86_64" "${TVOS_SIM_X86_PREFIX}" "${DEPS_BUILD_ROOT}/tvos-sim-x86_64/prefix")"
fi

UNIVERSAL_DIR="${BUILD_ROOT}/frameworks/universal"
rm -rf "${UNIVERSAL_DIR}"
mkdir -p "${UNIVERSAL_DIR}/ios-simulator" "${UNIVERSAL_DIR}/tvos-simulator"

make_universal_for_target() {
  local out_root="$1"   # UNIVERSAL_DIR/ios-simulator
  local arm_root="$2"   # ios sim arm fw dir
  local x86_root="$3"   # ios sim x86 fw dir (may be empty)

  local n
  for n in "libass" "${FFMPEG_LIBS[@]}"; do
    make_universal_sim_framework \
      "${out_root}/${n}.framework" \
      "${arm_root}/${n}.framework" \
      "${x86_root:+${x86_root}/${n}.framework}" \
      "${n}"
  done
}

make_universal_for_target "${UNIVERSAL_DIR}/ios-simulator" "${IOS_SIM_ARM64_FW_DIR}" "${IOS_SIM_X86_FW_DIR}"
make_universal_for_target "${UNIVERSAL_DIR}/tvos-simulator" "${TVOS_SIM_ARM64_FW_DIR}" "${TVOS_SIM_X86_FW_DIR}"

create_xcframework_for_lib() {
  local n="$1"
  local out="${OUT_DIR}/${n}.xcframework"
  rm -rf "${out}"

  xcodebuild -create-xcframework \
    -framework "${IOS_DEVICE_FW_DIR}/${n}.framework" \
    -framework "${UNIVERSAL_DIR}/ios-simulator/${n}.framework" \
    -framework "${TVOS_DEVICE_FW_DIR}/${n}.framework" \
    -framework "${UNIVERSAL_DIR}/tvos-simulator/${n}.framework" \
    -output "${out}"
}

for n in "libass" "${FFMPEG_LIBS[@]}"; do
  create_xcframework_for_lib "${n}"
done

cat > "${OUT_DIR}/README.txt" <<EOF
FFmpeg dynamic xcframeworks built at:
  ${OUT_DIR}

Contains:
  libass.xcframework
  ${FFMPEG_LIBS[*]/%/.xcframework}

Build log:
  ${BUILD_LOG}
EOF

echo "" >&2
echo "Built dynamic xcframeworks under: ${OUT_DIR}" >&2
echo "Build log: ${BUILD_LOG}" >&2

