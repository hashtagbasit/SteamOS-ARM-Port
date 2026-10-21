#!/bin/sh
# SteamOS Boot Hook for AYN Odin 3 (SM8750)
# Logging to both /dev/console and /flash/post-flash.log

LOG=/flash/post-flash.log
mkdir -p /flash 2>/dev/null

log() {
  echo "$*" > /dev/console 2>/dev/null
  echo "$*" >> "$LOG" 2>/dev/null
}

echo "" > /dev/console 2>/dev/null
log "============================================="
log "   SteamOS ARM — AYN Odin 3 (SM8750)        "
log "============================================="
log "Locating and mounting SteamOS system (root)..."
log "Uptime: $(cat /proc/uptime 2>/dev/null)"
log "Cmdline: $(cat /proc/cmdline 2>/dev/null)"

mkdir -p /sysroot

# The image build puts this card's root filesystem UUID here, so another
# install with a partition called "root" (UFS, a second card) can't get
# picked. LABEL=root and p2 are only the fallback for a hand-made card.
ROOT_UUID="@ROOT_UUID@"
ROOT_DEV=""

for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  log "Mount attempt $i/15..."
  case "$ROOT_UUID" in
    @*) ;;
    *) if mount -o rw "UUID=$ROOT_UUID" /sysroot 2>/dev/null; then
         ROOT_DEV="UUID=$ROOT_UUID"
         break
       fi
       usleep 500000
       continue ;;
  esac
  if mount -o rw LABEL=root /sysroot 2>/dev/null; then
    ROOT_DEV="LABEL=root"
    break
  fi
  for cand in /dev/disk/by-label/root /dev/mmcblk*p2 /dev/sda2; do
    if [ -b "$cand" ] && mount -o rw "$cand" /sysroot 2>/dev/null; then
      ROOT_DEV="$cand"
      break 2
    fi
  done
  usleep 500000
done

if [ -z "$ROOT_DEV" ] && mount -o rw LABEL=root /sysroot 2>/dev/null; then
  ROOT_DEV="LABEL=root"
  log "WARNING: UUID=$ROOT_UUID not found, using LABEL=root"
fi

if [ -z "$ROOT_DEV" ] || [ ! -f /sysroot/usr/lib/systemd/systemd ]; then
  log "ERROR: Could not mount SteamOS root partition!"
  log "Available block devices:"
  cat /proc/partitions >> "$LOG" 2>&1
  sync
  exit 1
fi

log "SteamOS root mounted from ${ROOT_DEV}."
log "Setting up /etc overlay..."

# Prepare sysroot directories
mkdir -p /sysroot/dev /sysroot/proc /sysroot/sys /sysroot/run /sysroot/boot

# Mount SteamOS /etc overlay if present
o=/sysroot/var/lib/overlays/etc
if [ -d "$o" ] && ! grep -q " /sysroot/etc " /proc/mounts 2>/dev/null; then
  mkdir -p "$o/upper" "$o/work"
  mount -t overlay overlay \
    -o "lowerdir=/sysroot/etc,upperdir=$o/upper,workdir=$o/work" /sysroot/etc 2>/dev/null && \
    log "Mounted /etc overlay successfully" || log "Failed to mount /etc overlay"
fi

log "Pivoting root to SteamOS systemd..."

# Move virtual filesystems into sysroot
mount --move /dev /sysroot/dev
mount --move /proc /sysroot/proc
mount --move /sys /sysroot/sys
mount --move /run /sysroot/run 2>/dev/null || true

# Unmount /flash so systemd's fstab can mount /boot cleanly
sync
umount /flash 2>/dev/null || true
umount /boot 2>/dev/null || true

# Hand over execution to SteamOS systemd
if [ -x /sysroot/usr/lib/systemd/systemd ]; then
  if [ -x /usr/bin/busybox ]; then
    exec /usr/bin/busybox switch_root /sysroot /usr/lib/systemd/systemd
  elif [ -x /bin/busybox ]; then
    exec /bin/busybox switch_root /sysroot /usr/lib/systemd/systemd
  else
    exec switch_root /sysroot /usr/lib/systemd/systemd
  fi
fi

exec /sbin/init
