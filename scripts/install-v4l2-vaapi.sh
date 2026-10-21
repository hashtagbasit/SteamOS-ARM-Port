#!/usr/bin/env bash
# Hardware video decode for VA-API apps (Chromium/Electron, FFmpeg, mpv):
# msm_drv_video.so drives the video core (iris, venus) through V4L2;
# libgbm.so.1 adds NV12/P010 buffers Mesa's GBM can't make on Adreno. The hub
# copies both into a Flatpak's data folder when it starts one.
#   install-v4l2-vaapi.sh <rootfs>     (build: scripts/build-v4l2-vaapi.sh)
set -euo pipefail
R="${1:?usage: install-v4l2-vaapi.sh <rootfs>}"
OVL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/steamos-overlay"
VABUILD="${VAAPI_BUILD:-${WORKDIR:-/work}/v4l2-vaapi-build}"
if [[ -f "$VABUILD/msm_drv_video.so" && -f "$VABUILD/libgbm.so.1" ]]; then
  install -D -m0755 "$VABUILD/msm_drv_video.so" "$R/usr/lib/dri/msm_drv_video.so"
  install -D -m0755 "$VABUILD/msm_drv_video.so" "$R/usr/lib/steamos-arm/va/msm_drv_video.so"
  install -D -m0755 "$VABUILD/libgbm.so.1" "$R/usr/lib/steamos-arm/va/libgbm.so.1"
  # At login: keep the files current in the Flatpaks that use them and give
  # Firefox (not started by the hub) its override.
  U=usr/lib/systemd/user/steamos-arm-video-accel.service
  install -D -m0644 "$OVL/$U" "$R/$U"
  mkdir -p "$R/usr/lib/systemd/user/default.target.wants"
  ln -sfn ../steamos-arm-video-accel.service \
    "$R/usr/lib/systemd/user/default.target.wants/steamos-arm-video-accel.service"
  echo "VA-API: hardware video decoder ($VABUILD)"
else
  echo "WARN: no $VABUILD, video apps keep decoding on the CPU"
fi
