#!/usr/bin/env bash
# Build the Adreno 740 Mesa stack for the 8 Gen 2 image (see
# external-and-mods/mesa/README.md): native aarch64 inside the Frame rootfs,
# x86_64 and i386 cross-compiled against the FEX guest tree the Frame ships.
#
#   sudo bash scripts/build-mesa.sh <frame-rootfs> [prepare|aarch64|x86_64|i386|android ...]
# (the architectures can build in parallel once "prepare" has run)
#
# Output: $MESA_WORK/out/<arch>/ (DESTDIR trees), installed by apply-overlays
# with MESA_STACK=$MESA_WORK/out.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
[[ -f "${ROOT}/versions.env" ]] && source "${ROOT}/versions.env"
R="$(cd "${1:?frame rootfs}" && pwd)"
shift
ARCHES=("${@:-aarch64 x86_64 i386}")
read -ra ARCHES <<<"${ARCHES[*]}"

: "${MESA_VERSION:?MESA_VERSION must be defined in versions.env or environment}"
: "${MESA_SHA256:?MESA_SHA256 must be defined in versions.env or environment}"
W="${MESA_WORK:-/work/mesa}"
G="$R/usr/share/guestos/fex-mesa"
PATCHES="${ROOT}/external-and-mods/mesa/patches"

# Cross builds run on the build host; Mesa 26.2 needs Meson >= 1.4 (Ubuntu
# 24.04 has 1.3): python3 -m venv $MESA_WORK/venv && pip install meson mako pyyaml
HOST_PY="${MESA_HOST_VENV:-$W/venv}/bin"
[[ -x "$HOST_PY/meson" ]] && export PATH="$HOST_PY:$PATH"

log() { printf '==> [mesa] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Same drivers as Valve's Frame Mesa: Turnip, zink as the only GL driver.
OPTS=(
  --buildtype=release -Db_ndebug=true --prefix=/usr
  -Dplatforms=x11,wayland
  -Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm
  -Dgallium-drivers=zink
  -Dglx=dri -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled
  -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled
  -Dxlib-lease=disabled -Dvideo-codecs= -Dtools= -Dbuild-tests=false
  -Dzstd=enabled -Dexpat=enabled -Dshader-cache=enabled
)

prepare_source() {
  mkdir -p "$W/cache"
  local tar="$W/cache/mesa-${MESA_VERSION}.tar.xz"
  if [[ ! -s "$tar" ]]; then
    curl -fL --retry 3 -o "$tar.part" "https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"
    mv "$tar.part" "$tar"
  fi
  echo "${MESA_SHA256}  $tar" | sha256sum -c - >/dev/null || die "mesa tarball checksum mismatch"
  local digest
  digest="$(cat "$PATCHES"/*.patch | sha256sum | cut -d' ' -f1)"
  if [[ -f "$W/src/.patched" && "$(cat "$W/src/.patched")" == "$digest" ]]; then
    log "source ready"
    return
  fi
  rm -rf "$W/src"; mkdir -p "$W/src"
  tar -C "$W/src" --strip-components=1 -xJf "$tar"
  local p
  for p in "$PATCHES"/*.patch; do
    log "patch $(basename "$p")"
    patch -d "$W/src" -p1 -N -s <"$p" || die "patch failed: $p"
  done
  echo "$digest" >"$W/src/.patched"
}

build_aarch64() {
  # Inside the Frame rootfs: its glibc, libdrm, wayland and xcb.
  local b="$W/build-aarch64" o="$W/out/aarch64"
  rm -rf "$b" "$o"; mkdir -p "$b" "$o"
  local -a bw=(bwrap --ro-bind "$R" / --bind "$W" /mnt --dev /dev --proc /proc
               --tmpfs /tmp --tmpfs /run --unshare-pid --die-with-parent
               --setenv PATH /usr/bin --chdir /mnt/src)
  log "aarch64: meson"
  "${bw[@]}" meson setup /mnt/build-aarch64 "${OPTS[@]}" --libdir=lib >"$W/aarch64.log" 2>&1 \
    || { tail -40 "$W/aarch64.log"; die "aarch64 meson failed"; }
  log "aarch64: ninja"
  "${bw[@]}" ninja -C /mnt/build-aarch64 >>"$W/aarch64.log" 2>&1 || { tail -40 "$W/aarch64.log"; die "aarch64 build failed"; }
  "${bw[@]}" env DESTDIR=/mnt/out/aarch64 ninja -C /mnt/build-aarch64 install >>"$W/aarch64.log" 2>&1 \
    || die "aarch64 install failed"
  log "aarch64: done ($o)"
}

# The guest tree ships libraries but almost no headers (Valve only needs it at
# runtime). Take the headers from the matching Arch x86_64 packages; lib32
# packages use the same headers. glibc headers come from the cross compiler.
GUEST_HEADER_PKGS=(
  "expat expat 2.7.1" "zlib zlib 1:1.3.1" "zstd zstd 1.5.7" "libdrm libdrm 2.4.133"
  "libxcb libxcb 1.17.0" "libx11 libx11 1.8.12" "libxshmfence libxshmfence 1.3.3"
  "libxxf86vm libxxf86vm 1.1.6" "libxext libxext 1.3.6" "wayland wayland 1.23.1"
  "xorgproto xorgproto 2024.1" "libxau libxau" "libxdmcp libxdmcp" "libxfixes libxfixes"
  "spirv-tools spirv-tools 1:1.4.328.1"   # = SPIRV-Tools 2025.3.x in the guest
  "systemd-libs systemd-libs 257" "libelf libelf 0.193" "libdisplay-info libdisplay-info 0.3.0"
  "libglvnd libglvnd 1.7.0" "libxml2 libxml2 2.14.5"
)
fetch_guest_headers() {
  local out="$W/guest-include" d="$W/cache/arch"
  [[ -f "$out/.done" ]] && return
  rm -rf "$out"; mkdir -p "$out" "$d"
  local e name pkg ver url file
  for e in "${GUEST_HEADER_PKGS[@]}"; do
    read -r name pkg ver <<<"$e"
    url="https://archive.archlinux.org/packages/${pkg:0:1}/${pkg}/"
    ver="${ver//:/%3A}"
    # header-only packages (xorgproto) are "any" instead of x86_64
    file="$( { curl -fsSL "$url" | grep -oE "href=\"${pkg}-${ver}[^\"]*-(x86_64|any)\.pkg\.tar\.(zst|xz)\"" \
            | sed 's/href="//;s/"$//' | tail -1; } || true)"
    [[ -n "$file" ]] || die "no Arch package for ${pkg} ${ver}"
    [[ -s "$d/$file" ]] || curl -fsSL -o "$d/$file" "$url$file"
    tar -C "$out" --wildcards -xf "$d/$file" 'usr/include/*' 2>/dev/null || true
    log "headers: $file"
  done
  touch "$out/.done"
}

# Cross builds against the guest tree, through a symlink sysroot so nothing
# is written into the Frame rootfs. i386 sees lib32 as lib and gets the glibc
# header the 64-bit tree leaves out; both get wayland-protocols (build-time
# XML only) from the Frame's native side.
make_sysroot() {
  local arch="$1" s="$W/sysroot-$1" libsrc
  [[ "$arch" == x86_64 ]] && libsrc="$G/usr/lib" || libsrc="$G/usr/lib32"
  rm -rf "$s"; mkdir -p "$s/usr/share/pkgconfig"
  ln -s "$libsrc" "$s/usr/lib"
  ln -s "$G/usr/lib32" "$s/usr/lib32"
  ln -s usr/lib "$s/lib"
  mkdir -p "$s/usr/include"
  cp -a "$W/guest-include/usr/include/." "$s/usr/include/"
  cp -a "$G/usr/include/." "$s/usr/include/"
  if [[ "$arch" == i386 ]]; then
    local stubs
    stubs="$(find /usr/i686-linux-gnu/include/gnu -name stubs-32.h 2>/dev/null | head -1)"
    [[ -n "$stubs" ]] || die "stubs-32.h not found (apt install libc6-dev-i386-cross)"
    mkdir -p "$s/usr/include/gnu"
    cp "$stubs" "$s/usr/include/gnu/stubs-32.h"
  fi
  cp -a "$G/usr/share/pkgconfig/." "$s/usr/share/pkgconfig/"
  cp "$R/usr/share/pkgconfig/wayland-protocols.pc" "$s/usr/share/pkgconfig/"
  ln -s "$R/usr/share/wayland-protocols" "$s/usr/share/wayland-protocols"
  echo "$s"
}

build_cross() {
  local arch="$1" triple cpu libdir
  case "$arch" in
    x86_64) triple=x86_64-linux-gnu; cpu=x86_64; libdir=lib ;;
    i386)   triple=i686-linux-gnu;   cpu=i686;   libdir=lib32 ;;
  esac
  local s b="$W/build-$arch" o="$W/out/$arch" x="$W/cross-$arch.txt"
  s="$(make_sysroot "$arch")"
  rm -rf "$b" "$o"; mkdir -p "$b" "$o"
  cat >"$x" <<EOF
[binaries]
c = ['${triple}-gcc', '--sysroot=${s}']
cpp = ['${triple}-g++', '--sysroot=${s}']
ar = '${triple}-ar'
strip = '${triple}-strip'
pkg-config = 'pkg-config'

[properties]
sys_root = '${s}'
pkg_config_libdir = ['${s}/usr/${libdir}/pkgconfig', '${s}/usr/share/pkgconfig']

[host_machine]
system = 'linux'
cpu_family = '$( [[ $arch == x86_64 ]] && echo x86_64 || echo x86 )'
cpu = '${cpu}'
endian = 'little'
EOF
  # Build-machine tools: Mesa wants wayland-scanner >= 1.23.1, Ubuntu 24.04 has
  # 1.22. The Frame's own (1.26, aarch64 like this build host) runs fine here
  # against the host's libexpat/libxml2 (don't point it at the Frame's libc).
  mkdir -p "$W/tools"
  # Meson's wayland module wants the scanner version to equal the target's
  # libwayland (the guest has 1.23.1); the code 1.26 generates only uses
  # calls libwayland has had for years, so report the guest version.
  local wlver
  wlver="$(sed -n 's/^Version: //p' "$s/usr/${libdir}/pkgconfig/wayland-client.pc")"
  cat >"$W/tools/wayland-scanner" <<EOF2
#!/bin/sh
if [ "\$1" = "--version" ]; then echo "wayland-scanner ${wlver}" >&2; exit 0; fi
exec "$R/usr/bin/wayland-scanner" "\$@"
EOF2
  chmod +x "$W/tools/wayland-scanner"
  "$W/tools/wayland-scanner" --version >/dev/null 2>&1 || die "Frame wayland-scanner does not run on this host"
  export PATH="$W/tools:$PATH"
  log "$arch: meson"
  # nofallback: no bundled subprojects (libarchive would only feed freedreno's
  # debug tools and wants OpenSSL headers the guest tree doesn't have).
  (cd "$W/src" && meson setup "$b" "${OPTS[@]}" --libdir="$libdir" --cross-file "$x" --wrap-mode=nofallback) >"$W/$arch.log" 2>&1 \
    || { tail -40 "$W/$arch.log"; die "$arch meson failed"; }
  log "$arch: ninja"
  ninja -C "$b" >>"$W/$arch.log" 2>&1 || { tail -40 "$W/$arch.log"; die "$arch build failed"; }
  DESTDIR="$o" ninja -C "$b" install >>"$W/$arch.log" 2>&1 || die "$arch install failed"
  log "$arch: done ($o)"
}

# Lepton (Android 11 container): same drivers as Valve's Android Mesa (Turnip,
# zink), bionic via the NDK sysroot. Google ships NDK compilers for x86 hosts
# only, so this uses the host's clang 18 with the r27c (clang 18) sysroot and
# runtime (the NDK's clang defaults: compiler-rt, libunwind, libc++, lld).
# Files land where Valve's do: usr/share/guestos/android/vendor/lib64.
: "${NDK_VERSION:?NDK_VERSION must be defined in versions.env or environment}"
: "${NDK_SHA1:?NDK_SHA1 must be defined in versions.env or environment}"
ANDROID_API=30
build_android() {
  local zip="$W/cache/android-ndk-${NDK_VERSION}-linux.zip" ndk="$W/android-ndk-${NDK_VERSION}"
  if [[ ! -s "$zip" ]]; then
    curl -fL --retry 3 -o "$zip.part" "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
    mv "$zip.part" "$zip"
  fi
  echo "${NDK_SHA1}  $zip" | sha1sum -c - >/dev/null || die "NDK checksum mismatch"
  [[ -d "$ndk" ]] || (cd "$W" && unzip -q "$zip")
  local tc="$ndk/toolchains/llvm/prebuilt/linux-x86_64"
  local rd sysroot="$tc/sysroot"
  rd="$(ls -d "$tc"/lib/clang/* | head -1)"
  command -v clang >/dev/null && command -v ld.lld >/dev/null || die "need clang + lld (apt install clang lld)"
  local ar strip
  ar="$(command -v llvm-ar || command -v llvm-ar-18)"; strip="$(command -v llvm-strip || command -v llvm-strip-18)"
  local b="$W/build-android" o="$W/out/android" x="$W/cross-android.txt"
  local v="$o/usr/share/guestos/android/vendor/lib64"
  rm -rf "$b" "$o"; mkdir -p "$b" "$v/hw" "$v/egl" "$W/android-no-pkgconfig"
  cat >"$x" <<CROSS
[binaries]
c = ['clang', '--target=aarch64-linux-android${ANDROID_API}', '--sysroot=${sysroot}', '-resource-dir=${rd}']
cpp = ['clang++', '--target=aarch64-linux-android${ANDROID_API}', '--sysroot=${sysroot}', '-resource-dir=${rd}', '-stdlib=libc++']
ar = '${ar}'
strip = '${strip}'
c_ld = 'lld'
cpp_ld = 'lld'
pkg-config = 'pkg-config'

[properties]
# nothing to find for bionic: libdrm comes from the bundled fallback
pkg_config_libdir = ['${W}/android-no-pkgconfig']

[built-in options]
# link-only flags stay out of the compiler command: Meson's feature checks
# treat "argument unused during compilation" as an error.
c_link_args = ['--rtlib=compiler-rt', '--unwindlib=libunwind', '-fuse-ld=lld']
cpp_args = ['-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables']
cpp_link_args = ['--rtlib=compiler-rt', '--unwindlib=libunwind', '-fuse-ld=lld', '-static-libstdc++']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSS
  log "android: meson"
  (cd "$W/src" && meson setup "$b" --cross-file "$x" --buildtype=release -Db_ndebug=true \
      -Dplatforms=android -Dplatform-sdk-version=${ANDROID_API} -Dandroid-stub=true \
      -Dandroid-libbacktrace=disabled -Dgallium-drivers=zink -Dvulkan-drivers=freedreno \
      -Dfreedreno-kmds=msm -Degl=enabled -Dgbm=enabled -Dgbm-backends-path=/vendor/lib64 \
      -Dllvm=disabled -Dzstd=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
      -Dtools= -Dbuild-tests=false -Dexpat=disabled \
      -Dallow-fallback-for=libdrm) >"$W/android.log" 2>&1 \
    || { tail -40 "$W/android.log"; die "android meson failed"; }
  log "android: ninja"
  ninja -C "$b" >>"$W/android.log" 2>&1 || { tail -40 "$W/android.log"; die "android build failed"; }
  # Android's loaders go by file name, not soname (same names as Valve's).
  install -m0755 "$b/src/freedreno/vulkan/libvulkan_freedreno.so" "$v/hw/vulkan.freedreno.so"
  install -m0755 "$b/src/gallium/targets/dri/libgallium_dri.so" "$v/libgallium_dri.so"
  install -m0755 "$b/src/gbm/libgbm_mesa.so" "$v/libgbm_mesa.so"
  if [[ -f "$b/src/gbm/backends/dri/dri_gbm.so" ]]; then
    install -m0755 "$b/src/gbm/backends/dri/dri_gbm.so" "$v/dri_gbm.so"
  fi
  install -m0755 "$b/src/egl/libEGL.so" "$v/egl/libEGL_mesa.so"
  install -m0755 "$b/src/mesa/glapi/es2api/libGLESv2.so" "$v/egl/libGLESv2_mesa.so"
  install -m0755 "$b/src/mesa/glapi/es1api/libGLESv1_CM.so" "$v/egl/libGLESv1_CM_mesa.so"
  log "android: done ($o)"
}

[[ -d "$G/usr/lib" ]] || die "no FEX guest tree in $R"
prepare_source
fetch_guest_headers
for a in "${ARCHES[@]}"; do
  case "$a" in
    prepare) ;;
    aarch64) build_aarch64 ;;
    x86_64|i386) build_cross "$a" ;;
    android) build_android ;;
    *) die "unknown arch $a" ;;
  esac
done
strings "$W/out/aarch64/usr/lib/libvulkan_freedreno.so" 2>/dev/null | grep -m1 "Mesa ${MESA_VERSION}" || true
