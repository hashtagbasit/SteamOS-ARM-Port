#!/usr/bin/env bash
# Build a flashable SteamOS SM8750 image for the AYN Odin 3:
#   p1 vfat BOOT  — ABL KERNEL (Linux 7.2.0 + Odin 3 DTB)
#   p2 ext4 root  — SteamOS system (Turnip Adreno 830 + Gamescope)
#   p3 ext4 home  — User data, auto-expanded on first boot
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${ROOT}/versions.env" ]] && source "${ROOT}/versions.env"
SCRIPTS="${ROOT}/scripts"
WORKDIR="${STEAMOS_WORK:-${ROOT}/sm8750-work}"
R="${STEAMOS_ROOTFS:-${WORKDIR}/rootfs}"
MOD="${ROOT}/external-and-mods"
OVL="${ROOT}/steamos-overlay"
SM8750_OVL="${ROOT}/sm8750-overlay"
KOUT="${KERNEL_OUT:-${WORKDIR}/kernel-sm8750-release/7.2.0}"
IMG="${STEAMOS_SM8750_IMG:-${WORKDIR}/steamos-odin3.img}"
MNT="${WORKDIR}/.image-mnt"
LOOPDEV=""

BOOT_MIB="${BOOT_MIB:-512}"
AUTO_ROOT=0
if [[ -z "${ROOT_MIB:-}" ]]; then
  AUTO_ROOT=1
  ROOT_MIB=16384
fi
AUTO_HOME=0
if [[ -z "${HOME_MIB:-}" ]]; then
  AUTO_HOME=1
  HOME_MIB=1024
fi

SKIP_DOWNLOAD=0
SKIP_APPLY=0
IMAGE_ONLY=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

sudo_run() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return
  fi
  if sudo -n true 2>/dev/null; then
    sudo "$@"
    return
  fi
  printf 'steam\n' | sudo -S -p '' "$@"
}

usage() {
  cat <<EOF
Usage: $0 [options]

  --skip-download   Reuse existing official rootfs chunks
  --skip-apply      Do not re-run scripts/apply-overlays-sm8750.sh
  --image-only      Only pack the .img from the current rootfs
  --img PATH        Output image (default: ${IMG})

Env: BOOT_MIB ROOT_MIB HOME_MIB STEAMOS_SM8750_IMG STEAMOS_ROOTFS KERNEL_OUT
     SM8750_KERNEL=prebuilt|source (default prebuilt; source needs a native
     aarch64 host and enables tracefs -- see ensure_kernel() in this script)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-download) SKIP_DOWNLOAD=1 ;;
    --skip-apply) SKIP_APPLY=1 ;;
    --image-only) IMAGE_ONLY=1; SKIP_DOWNLOAD=1; SKIP_APPLY=1 ;;
    --img) IMG="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

STEAMOS_BUILD="${STEAMOS_BUILD:-20261002.6232440}"
STEAMOS_VERSION="${STEAMOS_VERSION:-0.5.3}"
STEAMOS_BUNDLE="${STEAMOS_BUNDLE:-deckard-${STEAMOS_BUILD}-${STEAMOS_VERSION}}"
STEAMOS_URL="${STEAMOS_URL:-https://steamdeck-images.steamos.cloud/vr/${STEAMOS_BUILD}}"

# SM8750_KERNEL=prebuilt: ROCKNIX binary release, no tracefs.
# SM8750_KERNEL=source: build via kernel-sm8750/build.sh or use staged build, has tracefs.
# Default: uses from-source/SteamOS kernel if staged in kernel-sm8750-src, else prebuilt.
ensure_kernel() {
  local ksrc_work="${SM8750_KERNEL_WORK:-${WORKDIR}/kernel-sm8750-src}"
  local ksrc_cur="${ksrc_work}/output/current"
  if [[ "${SM8750_KERNEL:-}" == source || ( -z "${SM8750_KERNEL:-}" && -L "$ksrc_cur" && -f "$(readlink -f "$ksrc_cur")/boot/KERNEL" ) ]]; then
    if [[ -L "$ksrc_cur" && -f "$(readlink -f "$ksrc_cur")/boot/KERNEL" ]]; then
      log "SM8750 from-source kernel found in ${ksrc_work}"
    else
      log "Building SM8750 kernel from source (kernel-sm8750/build.sh)"
      WORK="$ksrc_work" bash "${MOD}/kernel-sm8750/build.sh"
    fi
    KOUT="$(readlink -f "$ksrc_cur")"
    return 0
  fi
  if [[ -f "${KOUT}/boot/KERNEL" && -d "${KOUT}/modules/7.2.0" ]]; then
    log "SM8750 kernel already staged in ${KOUT}"
    return 0
  fi
  log "Staging SM8750 kernel from ROCKNIX release"
  "${MOD}/kernel-sm8750/extract-rocknix.sh" "${KOUT}"
}

ensure_official_rootfs() {
  if [[ -x "${R}/usr/bin/bash" ]]; then
    log "Official rootfs already extracted"
    return 0
  fi
  [[ "$SKIP_DOWNLOAD" -eq 1 ]] && die "rootfs missing and --skip-download set"
  command -v unsquashfs >/dev/null || die "unsquashfs missing (apt install squashfs-tools)"
  local dl="${WORKDIR}/steamos-${STEAMOS_BUILD}" img sha
  mkdir -p "${dl}"
  img="${dl}/rootfs.img"
  if [[ ! -s "${dl}/bundle/rootfs.img.caibx" ]]; then
    log "Fetching Valve RAUC bundle ${STEAMOS_BUNDLE}"
    curl -fL -o "${dl}/${STEAMOS_BUNDLE}.raucb" "${STEAMOS_URL}/${STEAMOS_BUNDLE}.raucb"
    rm -rf "${dl}/bundle"
    unsquashfs -q -d "${dl}/bundle" "${dl}/${STEAMOS_BUNDLE}.raucb"
  fi
  sha="$(sed -n '/^\[image.rootfs\]/,/^\[/{s/^sha256=//p}' "${dl}/bundle/manifest.raucm")"
  if [[ ! -s "${img}" || ! -f "${img}.ok" ]]; then
    log "Assembling official rootfs.img from casync chunks (sha256 ${sha})"
    python3 "${SCRIPTS}/extract_rootfs.py" \
      --caibx "${dl}/bundle/rootfs.img.caibx" --output "${img}" \
      --store "${STEAMOS_URL}/${STEAMOS_BUNDLE}.castr" \
      --store "https://steamdeck-images.steamos.cloud/vr/chunks.castr" \
      --expected-sha256 "${sha}"
    touch "${img}.ok"
  fi
  log "Unpacking rootfs.img → ${R}"
  mkdir -p "${WORKDIR}/.rootfs-ro" "${R}"
  sudo_run mount -o loop,ro "${img}" "${WORKDIR}/.rootfs-ro"
  sudo_run rsync -aHAX --filter="-x btrfs.*" --numeric-ids "${WORKDIR}/.rootfs-ro/" "${R}/"
  sudo_run umount "${WORKDIR}/.rootfs-ro"
  [[ -x "${R}/usr/bin/bash" ]] || die "unpacked rootfs has no /usr/bin/bash"
}

# Box64 runs Decky's x86-64 PluginLoader. Built inside the Frame rootfs for
# its glibc, with Oryon flags (SDORYON1, armv8.6-a): the 8 Gen 2 build uses
# armv9-a, which the 8 Elite's cores don't implement.
ensure_box64() {
  [[ "$SKIP_APPLY" -eq 1 ]] && return 0
  local mark="${R}/usr/local/share/box64-target"
  if [[ -x "${R}/usr/local/bin/box64" && "$(cat "$mark" 2>/dev/null)" == SDORYON1 ]]; then
    log "Box64 (SDORYON1) already in rootfs"
    return 0
  fi
  local box64_src="${BOX64_SRC:-${WORKDIR}/box64}"
  if [[ ! -d "${box64_src}/.git" && ! -f "${box64_src}/CMakeLists.txt" ]]; then
    log "Cloning ptitSeb/box64 into ${box64_src}"
    git clone --depth 1 https://github.com/ptitSeb/box64 "${box64_src}"
  fi
  log "Building Box64 (SDORYON1) inside the Frame rootfs"
  sudo_run env BOX64_TARGET=SDORYON1 BOX64_SRC="${box64_src}" \
    "${SCRIPTS}/build-box64-in-rootfs.sh" "${R}"
  sudo_run mkdir -p "${R}/usr/local/share"
  echo SDORYON1 | sudo_run tee "$mark" >/dev/null
}

ensure_steam_seed() {
  [[ "$SKIP_APPLY" -eq 1 ]] && return 0
  local seed="${WORKDIR}/steam-arm-seed"
  if [[ -n "${STEAM_ARM_SEED:-}" && -d "${STEAM_ARM_SEED}" ]]; then
    seed="${STEAM_ARM_SEED}"
  fi

  if "${SCRIPTS}/install-complete-steam-client.sh" --check "${seed}" 2>/dev/null; then
    log "Steam ARM seed ready at ${seed}"
    export STEAM_ARM_SEED="${seed}"
    return 0
  fi

  if [[ "$(uname -m)" == "aarch64" ]]; then
    log "No complete Steam seed found. Bootstrapping headlessly on aarch64..."
    if [[ -f /etc/resolv.conf ]]; then
      sudo_run cp -L /etc/resolv.conf "${R}/etc/resolv.conf" 2>/dev/null || true
    fi
    "${SCRIPTS}/bootstrap-steam-arm-seed.sh" "${R}" "${seed}" "${STEAM_ARM_CHANNEL:-steamdeck_publicbeta}"
    export STEAM_ARM_SEED="${seed}"
    return 0
  fi

  log "WARN: Not on aarch64 ($(uname -m)) and no complete seed available; skipping headless bootstrap"
}
apply_mods() {
  [[ "$SKIP_APPLY" -eq 1 ]] && { log "Skipping apply-overlays"; return 0; }
  [[ -x "${SCRIPTS}/apply-overlays-sm8750.sh" ]] || die "missing scripts/apply-overlays-sm8750.sh"
  log "Applying SM8750 Odin 3 kernel / Turnip Adreno 830 / overlays"
  local mesa="${MESA_STACK:-}"
  if [[ -z "${mesa}" && -d "${WORKDIR}/mesa-stack/aarch64" ]]; then
    mesa="${WORKDIR}/mesa-stack"
    log "Auto-detected Mesa stack at ${mesa}"
  fi
  sudo_run env KERNEL_OUT="${KOUT}" STEAMOS_ROOTFS="${R}" STEAMOS_WORK="${WORKDIR}" \
    MESA_STACK="${mesa}" ${STEAM_ARM_SEED:+STEAM_ARM_SEED="${STEAM_ARM_SEED}"} \
    ${GAMESCOPE_BUILD:+GAMESCOPE_BUILD="${GAMESCOPE_BUILD}"} \
    "${SCRIPTS}/apply-overlays-sm8750.sh"
}

repack_kernel_partuuid() {
  local src="$1" dest="$2" partuuid="$3"
  local cmdline
  # shellcheck source=external-and-mods/kernel-sm8750/cmdline.sh
  source "${MOD}/kernel-sm8750/cmdline.sh"
  cmdline="$(build_cmdline "${partuuid}")"
  local tmp="/tmp/kernel-repack-$$"
  python3 - "${src}" "${tmp}" "${cmdline}" <<'PY'
import sys
from pathlib import Path
src, dest, cmdline = sys.argv[1], sys.argv[2], sys.argv[3]
data = bytearray(Path(src).read_bytes())
if data[:8] != b"ANDROID!":
    raise SystemExit("not an ANDROID bootimg")
cmd = cmdline.encode("ascii")
if len(cmd) >= 512:
    raise SystemExit(f"cmdline too long ({len(cmd)})")
data[0x40:0x40 + 512] = cmd.ljust(512, b"\x00")
Path(dest).write_bytes(data)
PY
  sudo_run cp "${tmp}" "${dest}"
  rm -f "${tmp}"
  log "KERNEL cmdline: ${cmdline}"
}

restore_image_suid() {
  local dest="$1" p
  [[ -d "${dest}/usr/bin" ]] || return 0
  log "Restoring setuid root on pkexec/sudo in the image"
  for p in \
    usr/bin/pkexec usr/sbin/pkexec usr/bin/sudo usr/sbin/sudo \
    usr/lib/polkit-1/polkit-agent-helper-1 \
    usr/bin/su usr/bin/passwd usr/bin/newgrp usr/bin/chsh usr/bin/chfn \
    usr/bin/gpasswd usr/bin/unix_chkpwd usr/bin/mount usr/bin/umount
  do
    [[ -e "${dest}/${p}" ]] || continue
    sudo_run chown root:root "${dest}/${p}"
    sudo_run chmod 4755 "${dest}/${p}"
  done
  if [[ -e "${dest}/usr/lib/dbus-1.0/dbus-daemon-launch-helper" ]]; then
    # The dbus package ships it root:dbus 4750 (the bus daemon runs it as
    # dbus); root:root left only root able to start bus-activated services.
    # The group number comes from the image, not the build host.
    local dbus_gid
    dbus_gid="$(awk -F: '$1 == "dbus" {print $3}' "${dest}/etc/group")"
    sudo_run chown "root:${dbus_gid:-root}" "${dest}/usr/lib/dbus-1.0/dbus-daemon-launch-helper"
    sudo_run chmod 4750 "${dest}/usr/lib/dbus-1.0/dbus-daemon-launch-helper"
  fi
}

wait_loop_parts() {
  local dev="$1" i
  for i in $(seq 1 50); do
    [[ -b "${dev}p1" && -b "${dev}p2" && -b "${dev}p3" ]] && return 0
    sleep 0.1
  done
  die "loop partitions did not appear on ${dev}"
}

cleanup_image() {
  sync || true
  sudo_run umount "${MNT}/boot" 2>/dev/null || true
  sudo_run umount "${MNT}/home" 2>/dev/null || true
  sudo_run umount "${MNT}/root" 2>/dev/null || true
  if [[ -n "${LOOPDEV:-}" ]]; then
    sudo_run losetup -d "${LOOPDEV}" 2>/dev/null || true
    LOOPDEV=""
  fi
}

detach_img_loops() {
  local dev
  sudo_run umount "${MNT}/boot" 2>/dev/null || true
  sudo_run umount "${MNT}/home" 2>/dev/null || true
  sudo_run umount "${MNT}/root" 2>/dev/null || true
  while read -r dev; do
    [[ -n "${dev}" ]] || continue
    sudo_run losetup -d "${dev}" 2>/dev/null || true
  done < <(losetup -j "${IMG}" -O NAME -n 2>/dev/null || true)
}

build_image() {
  local total_mib root_uuid home_uuid disk_id
  local boot_dev root_dev home_dev
  command -v sfdisk >/dev/null || die "sfdisk missing"
  command -v mkfs.vfat >/dev/null || die "mkfs.vfat missing"
  command -v mkfs.ext4 >/dev/null || die "mkfs.ext4 missing"
  [[ -x "${R}/usr/bin/bash" ]] || die "rootfs not ready"
  [[ -f "${KOUT}/boot/KERNEL" ]] || die "missing ${KOUT}/boot/KERNEL"

  if [[ "${AUTO_ROOT}" -eq 1 ]]; then
    local used_mib
    used_mib="$(sudo_run du -sm \
      --exclude=home --exclude=boot --exclude=proc --exclude=sys \
      --exclude=dev --exclude=tmp --exclude=run --exclude='.image-mnt' \
      "${R}" | awk '{print $1}')"
    ROOT_MIB=$((used_mib + 1536 + used_mib / 100 + 128))
    log "root auto-size ${ROOT_MIB} MiB (rootfs ${used_mib} MiB, ~1.5 GiB free)"
  fi
  if [[ "${AUTO_HOME}" -eq 1 ]]; then
    local home_mib
    home_mib="$(sudo_run du -sm "${R}/home" 2>/dev/null | awk '{print $1}')"
    home_mib="${home_mib:-1}"
    HOME_MIB=$((home_mib + 4096))
    log "home auto-size ${HOME_MIB} MiB (payload ${home_mib} MiB; grows on first boot)"
  fi

  total_mib=$((BOOT_MIB + ROOT_MIB + HOME_MIB + 2))
  # Deterministic disk and filesystem UUIDs for predictable partition tables and fstab.
  # Can be overridden via environment variables DISK_ID, ROOT_UUID, HOME_UUID.
  disk_id="${DISK_ID:-${DEFAULT_DISK_ID:-53544541}}"
  root_uuid="${ROOT_UUID:-${DEFAULT_ROOT_UUID:-e8992e59-b131-41b3-a9d0-fa52e1e3b5e4}}"
  home_uuid="${HOME_UUID:-${DEFAULT_HOME_UUID:-4b2452c9-d2b4-4e78-9588-e0ce26d8ee1c}}"

  log "Creating ${IMG} (${total_mib} MiB sparse)"
  log "  p1 BOOT ${BOOT_MIB}M vfat"
  log "  p2 root ${ROOT_MIB}M ext4 UUID=${root_uuid}"
  log "  p3 home ${HOME_MIB}M ext4 UUID=${home_uuid} (grows on first boot)"

  detach_img_loops
  rm -f "${IMG}"
  truncate -s "${total_mib}M" "${IMG}"

  local boot_start=2048
  local boot_sectors=$((BOOT_MIB * 2048))
  local root_start=$((boot_start + boot_sectors))
  local root_sectors=$((ROOT_MIB * 2048))
  local home_start=$((root_start + root_sectors))
  local home_sectors=$((HOME_MIB * 2048))

  sudo_run sfdisk "${IMG}" <<EOF
label: dos
label-id: 0x${disk_id}
unit: sectors

${IMG}1 : start=${boot_start}, size=${boot_sectors}, type=c, bootable
${IMG}2 : start=${root_start}, size=${root_sectors}, type=83
${IMG}3 : start=${home_start}, size=${home_sectors}, type=83
EOF

  LOOPDEV="$(sudo_run losetup -Pf --show "${IMG}")"
  [[ -b "${LOOPDEV}" ]] || die "failed to attach loop device"
  log "Attached ${IMG} → ${LOOPDEV}"
  trap cleanup_image EXIT INT TERM

  wait_loop_parts "${LOOPDEV}"
  boot_dev="${LOOPDEV}p1"
  root_dev="${LOOPDEV}p2"
  home_dev="${LOOPDEV}p3"

  log "Formatting filesystems"
  # Fixed FAT serial so the cmdline can find this BOOT by UUID.
  local boot_serial="${disk_id:0:8}"
  local root_hash_seed="${ROOT_HASH_SEED:-${DEFAULT_ROOT_HASH_SEED:-a1b2c3d4-e5f6-7890-abcd-ef1234567890}}"
  local home_hash_seed="${HOME_HASH_SEED:-${DEFAULT_HOME_HASH_SEED:-b2c3d4e5-f6a7-8901-bcde-f12345678901}}"
  sudo_run mkfs.vfat -F 32 -n BOOT -i "${boot_serial}" "${boot_dev}"
  sudo_run mkfs.ext4 -q -F -L root -U "${root_uuid}" -E "hash_seed=${root_hash_seed}" -m 1 "${root_dev}"
  sudo_run mkfs.ext4 -q -F -L home -U "${home_uuid}" -E "hash_seed=${home_hash_seed}" -m 0 "${home_dev}"

  mkdir -p "${MNT}/boot" "${MNT}/root" "${MNT}/home"
  sudo_run mount "${boot_dev}" "${MNT}/boot"
  sudo_run mount "${root_dev}" "${MNT}/root"
  sudo_run mount "${home_dev}" "${MNT}/home"

  log "Writing p1 BOOT (repacked KERNEL with root=PARTUUID=${disk_id}-02)"
  sudo_run mkdir -p "${MNT}/boot/boot"
  BOOT_FS_UUID="$(tr a-f A-F <<<"${boot_serial:0:4}-${boot_serial:4:4}")" HOME_FS_UUID="${home_uuid}" \
    repack_kernel_partuuid "${KOUT}/boot/KERNEL" "${MNT}/boot/KERNEL" "${disk_id}-02"
  sudo_run cp "${MNT}/boot/KERNEL" "${MNT}/boot/boot/KERNEL"
  sudo_run bash -c "cd '${MNT}/boot' && md5sum KERNEL | tee KERNEL.md5 boot/KERNEL.md5 >/dev/null"
  if [[ -f "${MOD}/kernel-sm8750/post-flash.sh" ]]; then
    sed "s/@ROOT_UUID@/${root_uuid}/" "${MOD}/kernel-sm8750/post-flash.sh" \
      | sudo_run tee "${MNT}/boot/post-flash.sh" "${MNT}/boot/boot/post-flash.sh" >/dev/null
  fi
  sudo_run env STEAMOS_WORK="${STEAMOS_WORK:-/work}" bash "${ROOT}/scripts/stage-rocknix-abl.sh" "${MNT}/boot" sm8750
  # Lenovo tablet boot files (the image on a USB drive starts it there):
  # ELDEN_KERNEL_OUT is that tablet's kernel output.
  if [[ -n "${ELDEN_KERNEL_OUT:-}" ]]; then
    sudo_run env STEAMOS_WORK="${STEAMOS_WORK:-/work}" bash "${ROOT}/scripts/stage-tablet-boot.sh" "${MNT}/boot" elden "$ELDEN_KERNEL_OUT"
  fi

  log "Writing p2 root"
  sudo_run rsync -aHAX --numeric-ids \
    --exclude='.image-mnt' --exclude='/boot/KERNEL*' \
    --exclude='/home/*' \
    "${R}/" "${MNT}/root/"
  restore_image_suid "${MNT}/root"
  # Each new installation must generate its own D-Bus/network identity on first boot.
  sudo_run truncate -s 0 "${MNT}/root/etc/machine-id" 2>/dev/null || true

  log "Writing fstab for 3-partition layout"
  sudo_run tee "${MNT}/root/etc/fstab" >/dev/null <<EOF
# SteamOS Odin 3 (SM8750) — SD card layout
UUID=${root_uuid}  /      ext4  defaults,noatime                               0 1
PARTUUID=${disk_id}-01  /boot  vfat  ro,defaults,umask=0077,nofail            0 2
UUID=${home_uuid}  /home  ext4  defaults,noatime,commit=30,x-systemd.growfs   0 2
EOF

  log "Writing p3 home"
  if [[ -d "${R}/home/steamos" ]]; then
    sudo_run rsync -aHAX --numeric-ids "${R}/home/steamos/" "${MNT}/home/steamos/"
    sudo_run chown -R 1000:1000 "${MNT}/home/steamos" 2>/dev/null || true
  else
    sudo_run mkdir -p "${MNT}/home/steamos"
    sudo_run chown 1000:1000 "${MNT}/home/steamos" 2>/dev/null || true
  fi

  log "Syncing and unmounting"
  cleanup_image
  trap - EXIT INT TERM


  log "================================================================="
  log "SUCCESS: SteamOS ARM for AYN Odin 3 built:"
  log "Image: ${IMG} ($((total_mib)) MiB)"
  log "Flash to microSD with: sudo dd if=${IMG} of=/dev/sdX bs=4M status=progress"
  log "Boot instructions: Hold Volume Down -> Boot Mode: Linux -> START"
  log "================================================================="
}

mkdir -p "${WORKDIR}"
ensure_kernel
ensure_official_rootfs
ensure_steam_seed
ensure_box64
apply_mods
build_image
