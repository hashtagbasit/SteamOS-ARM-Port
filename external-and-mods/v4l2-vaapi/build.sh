#!/bin/bash
# Builds msm_drv_video.so (VA-API over the V4L2 video decoder) and the
# libgbm.so.1 NV12/P010 shim in a Debian bookworm container (glibc 2.36), so the
# same binaries load on the host and inside Flatpak runtimes.
#   OUT=<dir> ./build.sh        (default: ./out)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/out}"
CFLAGS="-O2 -g -fPIC -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden -D_GNU_SOURCE"
build() {
	mkdir -p "$OUT"
	gcc $CFLAGS -shared -o "$OUT/msm_drv_video.so" "$HERE"/src/*.c -lpthread -Wl,-z,defs -Wl,--as-needed
	OUT="$OUT" bash "$HERE/gbm-nv12/build.sh"
}
if [[ "${INSIDE:-}" == 1 ]]; then
	build
else
	mkdir -p "$OUT"
	docker run --rm -v "$HERE:/src/v4l2-vaapi:ro" -v "$(realpath "$OUT"):/out" debian:bookworm \
		bash -c 'apt-get update -qq >/dev/null && apt-get install -y -qq gcc libva-dev patchelf >/dev/null 2>&1 && \
			cp -r /src/v4l2-vaapi /tmp/b && INSIDE=1 OUT=/out bash /tmp/b/build.sh'
fi
echo "built $OUT/msm_drv_video.so $OUT/libgbm.so.1"
