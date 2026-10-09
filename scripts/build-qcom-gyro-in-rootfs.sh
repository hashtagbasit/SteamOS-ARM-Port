#!/usr/bin/env bash
# Build the AYN Odin 2 family / Thor gyro userspace from source inside the rootfs
# and install it to <rootfs>/usr/lib/qcom-gyro/{bin,lib}:
#   qrtr (qrtr-lookup, libqrtr)         BSD-3-Clause
#   libqrtr-glib, libqmi (libraries)    LGPL-2.1+
#   libssc (+ our patches)              GPL-3.0+
#   hexagonrpc (+ our patches, with sscregistrygen) GPL-3.0+
#   qcom-motion, qcom-sdl-pad           GPL-3.0+ AND Apache-2.0
# Build only: protoc-gen-c from protobuf-c 1.5.0, as SteamOS's protobuf-c
# package ships one linked against an abseil the rootfs no longer has.
# Sources and refs: external-and-mods/kernel/vendor/qcom-gyro/SOURCES.md.
# Licenses go to <rootfs>/usr/share/licenses/qcom-gyro/.
#
# Usage: build-qcom-gyro-in-rootfs.sh <rootfs>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
R="$(cd "${1:?rootfs}" && pwd)"
WORKDIR="${STEAMOS_WORK:-/work}"
SRCS="${WORKDIR}/qcom-gyro-src"
V="${ROOT}/external-and-mods/kernel/vendor/qcom-gyro/src"

# name url commit
REPOS=(
  "protobuf-c https://github.com/protobuf-c/protobuf-c.git 8c201f6e47a53feaab773922a743091eb6c8972a"
  "qrtr https://github.com/linux-msm/qrtr.git b51ffaf22707b6000ecfb894c5b750f3bb7843b2"
  "libqrtr-glib https://gitlab.freedesktop.org/mobile-broadband/libqrtr-glib.git 8991f0e93713ebf4da48ae4f23940ead42f64c8c"
  "libqmi https://gitlab.freedesktop.org/mobile-broadband/libqmi.git defb13dcab0adc7f44f6741807244507a14a30c5"
  "libssc https://codeberg.org/DylanVanAssche/libssc.git 3befde3ef215bdb78c4a48aa72c99cd458c2aed0"
  "hexagonrpc https://github.com/linux-msm/hexagonrpc.git dd9ac70c026e1bad93e8cffa3801255b8ceb551e"
)

log() { printf '==> [qcom-gyro] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v bwrap >/dev/null || die "bwrap required (apt install bubblewrap)"
for t in gcc g++ autoreconf libtool meson ninja pkg-config protoc-c python3; do
  [[ -x "$R/usr/bin/$t" ]] || die "rootfs needs $t"
done
for h in glib-2.0/glib.h json-c/json.h protobuf-c/protobuf-c.h zlib.h linux/qrtr.h; do
  [[ -f "$R/usr/include/$h" ]] || die "rootfs needs /usr/include/$h"
done

T="$R/t/qcom-gyro"
rm -rf "$T"; mkdir -p "$T/src"
for r in "${REPOS[@]}"; do
  set -- $r
  if [[ ! -d "$SRCS/$1/.git" ]]; then
    log "clone $1"
    git clone -q "$2" "$SRCS/$1"
  fi
  git -C "$SRCS/$1" cat-file -e "$3^{commit}" 2>/dev/null || git -C "$SRCS/$1" fetch -q origin
  git -C "$SRCS/$1" archive --prefix="$1/" "$3" | tar -x -C "$T/src"
done
for p in "$V"/libssc/*.patch; do patch -d "$T/src/libssc" -Np1 --quiet <"$p"; done
for p in "$V"/hexagonrpc/*.patch; do patch -d "$T/src/hexagonrpc" -Np1 --quiet <"$p"; done
cp -r "$V/batocera-qcom-motion/src" "$T/src/qcom-motion"
cp -r "$V/qcom-sdl-pad" "$T/src/qcom-sdl-pad"

log "build (aarch64, against the rootfs)"
bwrap --bind "$R" / --dev /dev --proc /proc --tmpfs /tmp \
  --unshare-pid --die-with-parent --chdir /t/qcom-gyro bash -euo pipefail -c '
P=/t/qcom-gyro/prefix
mkdir -p build
export PKG_CONFIG_PATH=$P/lib/pkgconfig LD_LIBRARY_PATH=$P/lib
m() { local n=$1; shift; mkdir -p build
  { meson setup "build/$n" "src/$n" --prefix=$P --libdir=lib --buildtype=release "$@" &&
    ninja -C "build/$n" install; } >"build/$n.log" 2>&1 || { tail -40 "build/$n.log"; exit 1; }; }
# autotools, not build-cmake: that one puts /usr/include first on the protoc
# path, where the protobuf-c.proto of the rootfs shadows the source copy.
(cd src/protobuf-c && ./autogen.sh && ./configure --disable-shared &&
  make -j"$(nproc)" protoc-c/protoc-gen-c) >build/protobuf-c.log 2>&1 ||
  { tail -40 build/protobuf-c.log; exit 1; }
export PATH=/t/qcom-gyro/src/protobuf-c/protoc-c:$PATH
m qrtr -Dqrtr-ns=disabled -Dsystemd-service=disabled
m libqrtr-glib -Dintrospection=false -Dgtk_doc=false
m libqmi -Dmbim_qmux=false -Dqrtr=true -Dudev=false -Dintrospection=false \
  -Dgtk_doc=false -Dman=false -Dbash_completion=false -Dfirmware_update=false \
  -Dmm_runtime_check=false -Drmnet=false
m libssc -Dtests=false -Dintrospection=false -Dauto_features=disabled
m hexagonrpc -Dhexagonrpcd_verbose=false
# Thor registry generator, built when json-c is found but not installed.
install -m0755 build/hexagonrpc/tools/sscregistrygen $P/bin/
CF="-O2 -std=c11 -Wall -Wextra -Werror"
gcc $CF src/qcom-motion/batocera-qcom-motion.c -o $P/bin/qcom-motion \
  $(pkg-config --cflags --libs libssc gio-2.0 zlib) -lm
gcc $CF src/qcom-sdl-pad/qcom-sdl-pad.c -o $P/bin/qcom-sdl-pad \
  $(pkg-config --cflags --libs glib-2.0 zlib) -lm
'

P="$T/prefix"
G="$R/usr/lib/qcom-gyro"
log "install into $G"
rm -rf "$G/bin" "$G/lib"
install -d -m0755 "$G/bin" "$G/lib"
install -m0755 "$P"/bin/{hexagonrpcd,sscregistrygen,qrtr-lookup,qcom-motion,qcom-sdl-pad} "$G/bin/"
for l in libqrtr libqrtr-glib libqmi-glib libssc libhexagonrpc; do
  cp -P "$P"/lib/"$l".so.* "$G/lib/"
done
L="$R/usr/share/licenses/qcom-gyro"
rm -rf "$L"
install -Dm0644 "$T/src/qrtr/LICENSE" "$L/qrtr/LICENSE"
cp -r "$T/src/libqrtr-glib/LICENSES" "$L/libqrtr-glib"
install -Dm0644 "$T/src/libqmi/COPYING.LIB" "$L/libqmi/COPYING.LIB"
install -Dm0644 "$T/src/libssc/LICENSE" "$L/libssc/LICENSE"
install -Dm0644 "$T/src/hexagonrpc/COPYING" "$L/hexagonrpc/COPYING"
install -d "$L/qcom-gyro-tools"
printf '%s\n' 'qcom-motion and qcom-sdl-pad: GPL-3.0-or-later AND Apache-2.0' \
  'Texts: /usr/share/licenses/spdx/GPL-3.0-or-later.txt, /usr/share/licenses/spdx/Apache-2.0.txt' \
  >"$L/qcom-gyro-tools/LICENSE"
chmod -R u=rwX,go=rX "$L"
rm -rf "$R/t/qcom-gyro"
rmdir "$R/t" 2>/dev/null || true
ls -l "$G/bin" "$G/lib"
