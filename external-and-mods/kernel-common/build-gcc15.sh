#!/usr/bin/env bash
# Run build.sh inside a Fedora 43 container, which has GCC 15. Same
# arguments as build.sh, e.g. for the 8 Gen 2 test kernel on 7.2:
#   SM8550_RECIPE=7.2 bash external-and-mods/kernel-common/build-gcc15.sh sm8550
# The port tree, WORK and the ROCKNIX checkout all have to be under MOUNT
# (default /work), which is mounted at the same path in the container.
# On an x86_64 host it cross-compiles with Fedora's aarch64 GCC 15; BUSYBOX
# then has to be a static aarch64 busybox (it goes into the initramfs).
# DOCKER=podman works too.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_ROOT="$(cd "${HERE}/../.." && pwd)"
IMAGE="${IMAGE:-fedora:43}"
MOUNT="${MOUNT:-${PORT_ROOT}}"
BUSYBOX="${BUSYBOX:-/bin/busybox}"
DOCKER="${DOCKER:-docker}"

PKGS="file gcc gcc-c++ make bc bison flex python3 curl tar xz gzip cpio kmod patch perl rsync
      openssl-devel elfutils-libelf-devel dwarves diffutils findutils hostname which git busybox"
if [[ "$(uname -m)" != aarch64 ]]; then
  PKGS+=" gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu"
  export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi
env_args=()
for v in SM8550_RECIPE SM8650_RECIPE WORK ROCKNIX_DIR JOBS OUT_BASE LOCALVERSION DTBS_OVERRIDE INITRAMFS_HOTFIX CROSS_COMPILE FRAME_FW_DIR; do
  [[ -n "${!v:-}" ]] && env_args+=(-e "$v=${!v}")
done

mount_args=(-v "$MOUNT:$MOUNT")
if [[ -n "${WORK:-}" && -d "$WORK" && "$WORK" != "$MOUNT"* ]]; then
  mount_args+=(-v "$WORK:$WORK")
fi
if [[ -n "${ROCKNIX_DIR:-}" && -d "$ROCKNIX_DIR" && "$ROCKNIX_DIR" != "$MOUNT"* ]]; then
  mount_args+=(-v "$ROCKNIX_DIR:$ROCKNIX_DIR")
fi
if [[ -x "$BUSYBOX" ]]; then
  mount_args+=(-v "$BUSYBOX:/bin/busybox:ro")
fi

exec "$DOCKER" run --rm --security-opt label=disable "${mount_args[@]}" -w "$PWD" "${env_args[@]}" \
  "$IMAGE" bash -c "
    set -e
    dnf -q -y install $(echo $PKGS) >/dev/null
    git config --global --add safe.directory '*'
    ${CROSS_COMPILE:-}gcc --version | head -1
    exec bash '$HERE/build.sh' $*"
