#!/usr/bin/env bash
#
# Build static libass dependency chain for Apple platforms (iOS + tvOS).
# Output per target:
#   build/{target}/prefix/{include,lib,lib/pkgconfig/*.pc}
#
# Build order (per target):
#   freetype2 -> fribidi -> harfbuzz -> libass
#
# Requirements:
# - Static libs only
# - CoreText backend (no fontconfig)
#
# Usage:
#   ./scripts/build-deps.sh                 # builds all targets used by ffmpeg script
#   TARGETS="ios-arm64 tvos-arm64" ./scripts/build-deps.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build}"

# Normalize paths early so subsequent pushd's don't break relative references.
mkdir -p "${BUILD_ROOT}"
BUILD_ROOT="$(cd "${BUILD_ROOT}" && pwd)"

SRC_CACHE="${SRC_CACHE:-${BUILD_ROOT}/_deps-src}"
WORK_ROOT="${WORK_ROOT:-${BUILD_ROOT}/_deps-work}"

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
MIN_IOS="${MIN_IOS:-13.0}"
MIN_TVOS="${MIN_TVOS:-13.0}"
SKIP_SIM_X86="${SKIP_SIM_X86:-0}"
# When enabled, build libass as a shared library (dylib) while keeping
# freetype/fribidi/harfbuzz static to minimize runtime-embedded dylib count.
DEPS_LIBASS_DYNAMIC="${DEPS_LIBASS_DYNAMIC:-0}"

die() { echo "error: $*" >&2; exit 1; }

command -v xcrun >/dev/null || die "xcrun not found"
command -v curl >/dev/null || die "curl not found"
command -v tar >/dev/null || die "tar not found"
command -v make >/dev/null || die "make not found"
command -v pkg-config >/dev/null || die "pkg-config not found (install via Homebrew: brew install pkg-config)"
command -v meson >/dev/null || die "meson not found (install via Homebrew: brew install meson)"
command -v ninja >/dev/null || die "ninja not found (install via Homebrew: brew install ninja)"

FREETYPE_VER="${FREETYPE_VER:-2.14.3}"
FRIBIDI_VER="${FRIBIDI_VER:-1.0.16}"
HARFBUZZ_VER="${HARFBUZZ_VER:-13.2.1}"

FREETYPE_URL="${FREETYPE_URL:-https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VER}.tar.xz}"
FRIBIDI_URL="${FRIBIDI_URL:-https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VER}/fribidi-${FRIBIDI_VER}.tar.xz}"
HARFBUZZ_URL="${HARFBUZZ_URL:-https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VER}/harfbuzz-${HARFBUZZ_VER}.tar.xz}"

LIBASS_SRC="${LIBASS_SRC:-${REPO_ROOT}/libass}"
[[ -d "${LIBASS_SRC}" ]] || die "libass source folder not found: ${LIBASS_SRC}"

mkdir -p "${SRC_CACHE}" "${WORK_ROOT}"

pkg_config_env_for_prefix() {
  local prefix="$1"
  echo "PKG_CONFIG_DIR=" \
       "PKG_CONFIG_LIBDIR=${prefix}/lib/pkgconfig" \
       "PKG_CONFIG_PATH=${prefix}/lib/pkgconfig"
}

fetch_and_extract() {
  local url="$1"
  local out_dir="$2"
  local archive="${SRC_CACHE}/$(basename "${url}")"
  if [[ ! -f "${archive}" ]]; then
    echo "Downloading $(basename "${url}")" >&2
    curl -L --fail --retry 3 --retry-delay 1 -o "${archive}" "${url}"
  fi
  rm -rf "${out_dir}"
  mkdir -p "${out_dir}"
  tar -xf "${archive}" -C "${out_dir}" --strip-components=1
}

target_vars() {
  local target="$1"
  case "${target}" in
    ios-arm64)
      SDK=iphoneos; ARCH=arm64; MIN_CFLAGS="-miphoneos-version-min=${MIN_IOS}"; MIN_LDFLAGS="${MIN_CFLAGS}" ;;
    ios-sim-arm64)
      SDK=iphonesimulator; ARCH=arm64; MIN_CFLAGS="-mios-simulator-version-min=${MIN_IOS}"; MIN_LDFLAGS="${MIN_CFLAGS}" ;;
    ios-sim-x86_64)
      SDK=iphonesimulator; ARCH=x86_64; MIN_CFLAGS="-mios-simulator-version-min=${MIN_IOS}"; MIN_LDFLAGS="${MIN_CFLAGS}" ;;
    tvos-arm64)
      SDK=appletvos; ARCH=arm64; MIN_CFLAGS="-mtvos-version-min=${MIN_TVOS}"; MIN_LDFLAGS="${MIN_CFLAGS}" ;;
    tvos-sim-arm64)
      SDK=appletvsimulator; ARCH=arm64; MIN_CFLAGS="-mtvos-simulator-version-min=${MIN_TVOS}"; MIN_LDFLAGS="${MIN_CFLAGS}" ;;
    tvos-sim-x86_64)
      SDK=appletvsimulator; ARCH=x86_64; MIN_CFLAGS="-mtvos-simulator-version-min=${MIN_TVOS}"; MIN_LDFLAGS="${MIN_CFLAGS}" ;;
    *)
      die "unknown target: ${target}"
      ;;
  esac

  SYSROOT="$(xcrun --sdk "${SDK}" --show-sdk-path)"
  CC="$(xcrun --sdk "${SDK}" --find clang)"
  CXX="$(xcrun --sdk "${SDK}" --find clang++)"
  AR="$(xcrun --sdk "${SDK}" --find ar)"
  RANLIB_REAL="$(xcrun --sdk "${SDK}" --find ranlib)"
  STRIP="$(xcrun --sdk "${SDK}" --find strip)"

  if [[ "${ARCH}" == "arm64" ]]; then
    HOST_TRIPLE="aarch64-apple-darwin"
    MESON_CPU_FAMILY="aarch64"
    MESON_CPU="arm64"
  else
    HOST_TRIPLE="x86_64-apple-darwin"
    MESON_CPU_FAMILY="x86_64"
    MESON_CPU="x86_64"
  fi

  CFLAGS="-arch ${ARCH} -isysroot ${SYSROOT} ${MIN_CFLAGS}"
  CPPFLAGS="${CFLAGS}"
  LDFLAGS="-arch ${ARCH} -isysroot ${SYSROOT} ${MIN_LDFLAGS}"

  PREFIX="${BUILD_ROOT}/${target}/prefix"
  TARGET_WORK="${WORK_ROOT}/${target}"
  mkdir -p "${PREFIX}" "${TARGET_WORK}"

  # Meson sometimes calls `ranlib -c` when creating static archives.
  # Apple's `ranlib` does not accept `-c`, so we shim it out.
  RANLIB_SHIM="${TARGET_WORK}/ranlib-shim.sh"
  cat > "${RANLIB_SHIM}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
args=()
for a in "\$@"; do
  [[ "\$a" == "-c" ]] && continue
  args+=("\$a")
done
exec "${RANLIB_REAL}" "\${args[@]}"
EOF
  chmod +x "${RANLIB_SHIM}"
  RANLIB="${RANLIB_SHIM}"
}

write_meson_cross_file() {
  local target="$1"
  local cross_file="$2"
  local default_library="${3:-static}"

  # Turn a shell string of flags into a Meson array of quoted tokens.
  # Example: "-arch arm64 -isysroot /SDK" -> "'-arch', 'arm64', '-isysroot', '/SDK'"
  flags_to_meson_array() {
    local s="$1"
    local out=""
    local tok
    # shellcheck disable=SC2206
    local parts=(${s})
    for tok in "${parts[@]}"; do
      [[ -n "${out}" ]] && out+=", "
      out+="'${tok//\'/\\\'}'"
    done
    printf '%s' "${out}"
  }

  local c_args_array c_link_args_array
  c_args_array="$(flags_to_meson_array "${CFLAGS}")"
  c_link_args_array="$(flags_to_meson_array "${LDFLAGS}")"

  cat > "${cross_file}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
ranlib = '${RANLIB}'
strip = '${STRIP}'
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
cpu_family = '${MESON_CPU_FAMILY}'
cpu = '${MESON_CPU}'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = [${c_args_array}]
c_link_args = [${c_link_args_array}]
cpp_args = [${c_args_array}]
cpp_link_args = [${c_link_args_array}]
default_library = '${default_library}'
EOF
}

build_freetype() {
  local target="$1"
  local src_dir="${TARGET_WORK}/freetype-src"
  local build_dir="${TARGET_WORK}/freetype-build"
  fetch_and_extract "${FREETYPE_URL}" "${src_dir}"
  rm -rf "${build_dir}"
  mkdir -p "${build_dir}"

  pushd "${build_dir}" >/dev/null
  env \
    CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" \
    CFLAGS="${CFLAGS}" CPPFLAGS="${CPPFLAGS}" LDFLAGS="${LDFLAGS}" \
    "${src_dir}/configure" \
      --host="${HOST_TRIPLE}" \
      --prefix="${PREFIX}" \
      --enable-static \
      --disable-shared \
      --without-harfbuzz \
      --without-bzip2 \
      --without-brotli \
      --without-png \
      --without-zlib
  make -j"${JOBS}"
  make install
  popd >/dev/null
}

build_fribidi() {
  local target="$1"
  local src_dir="${TARGET_WORK}/fribidi-src"
  local build_dir="${TARGET_WORK}/fribidi-build"
  fetch_and_extract "${FRIBIDI_URL}" "${src_dir}"
  rm -rf "${build_dir}"
  mkdir -p "${build_dir}"

  pushd "${build_dir}" >/dev/null
  local pc_env
  pc_env="$(pkg_config_env_for_prefix "${PREFIX}")"
  env \
    CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" \
    CFLAGS="${CFLAGS}" CPPFLAGS="${CPPFLAGS}" LDFLAGS="${LDFLAGS}" \
    ${pc_env} \
    "${src_dir}/configure" \
      --host="${HOST_TRIPLE}" \
      --prefix="${PREFIX}" \
      --enable-static \
      --disable-shared
  make -j"${JOBS}"
  make install
  popd >/dev/null
}

build_harfbuzz() {
  local target="$1"
  local src_dir="${TARGET_WORK}/harfbuzz-src"
  local build_dir="${TARGET_WORK}/harfbuzz-build"
  local cross="${TARGET_WORK}/meson-${target}.ini"
  fetch_and_extract "${HARFBUZZ_URL}" "${src_dir}"
  write_meson_cross_file "${target}" "${cross}" "static"
  rm -rf "${build_dir}"

  local pc_env
  pc_env="$(pkg_config_env_for_prefix "${PREFIX}")"
  env ${pc_env} \
    meson setup "${build_dir}" "${src_dir}" \
      --cross-file "${cross}" \
      --prefix "${PREFIX}" \
      -Dtests=disabled \
      -Ddocs=disabled \
      -Dbenchmark=disabled \
      -Dutilities=disabled \
      -Dsubset=disabled \
      -Draster=disabled \
      -Dvector=disabled \
      -Dzlib=disabled \
      -Dpng=disabled \
      -Dglib=disabled \
      -Dgobject=disabled \
      -Dcairo=disabled \
      -Dchafa=disabled \
      -Dicu=disabled
  meson compile -C "${build_dir}" -j "${JOBS}"
  meson install -C "${build_dir}"
}

build_libass() {
  local target="$1"
  local build_dir="${TARGET_WORK}/libass-build"
  local cross="${TARGET_WORK}/meson-${target}.ini"
  if [[ "${DEPS_LIBASS_DYNAMIC}" == "1" ]]; then
    write_meson_cross_file "${target}" "${cross}" "shared"
  else
    write_meson_cross_file "${target}" "${cross}" "static"
  fi
  rm -rf "${build_dir}"

  local pc_env
  pc_env="$(pkg_config_env_for_prefix "${PREFIX}")"
  env ${pc_env} \
    meson setup "${build_dir}" "${LIBASS_SRC}" \
      --cross-file "${cross}" \
      --prefix "${PREFIX}" \
      -Dfontconfig=disabled \
      -Dcoretext=enabled \
      -Dlibunibreak=disabled \
      -Dtest=disabled \
      -Dcompare=disabled \
      -Dprofile=disabled \
      -Dfuzz=disabled \
      -Dcheckasm=disabled
  meson compile -C "${build_dir}" -j "${JOBS}"
  meson install -C "${build_dir}"

  [[ -f "${PREFIX}/lib/pkgconfig/libass.pc" ]] || die "${target}: missing libass.pc under ${PREFIX}/lib/pkgconfig"

  # Sanity: ensure pkg-config resolves to our prefix and static libs.
  # shellcheck disable=SC2086
  local libs cflags
  libs="$(env ${pc_env} pkg-config --libs --static libass 2>/dev/null || true)"
  # shellcheck disable=SC2086
  cflags="$(env ${pc_env} pkg-config --cflags libass 2>/dev/null || true)"
  if echo "${libs} ${cflags}" | grep -Eq '(/usr/local|/opt/homebrew|/usr/lib( |$))'; then
    echo "error: ${target}: libass pkg-config output contains host paths:" >&2
    echo "  cflags: ${cflags}" >&2
    echo "  libs:   ${libs}" >&2
    exit 1
  fi
}

build_target() {
  local target="$1"
  echo "" >&2
  echo "== deps: ${target} ==" >&2
  target_vars "${target}"
  build_freetype "${target}"
  build_fribidi "${target}"
  build_harfbuzz "${target}"
  build_libass "${target}"
}

DEFAULT_TARGETS=(ios-arm64 ios-sim-arm64 ios-sim-x86_64 tvos-arm64 tvos-sim-arm64 tvos-sim-x86_64)
TARGETS="${TARGETS:-${DEFAULT_TARGETS[*]}}"

if [[ "${SKIP_SIM_X86}" == "1" ]]; then
  TARGETS="${TARGETS//ios-sim-x86_64/}"
  TARGETS="${TARGETS//tvos-sim-x86_64/}"
fi

for t in ${TARGETS}; do
  [[ -z "${t}" ]] && continue
  build_target "${t}"
done

echo "" >&2
echo "Deps build complete under: ${BUILD_ROOT}/<target>/prefix" >&2
