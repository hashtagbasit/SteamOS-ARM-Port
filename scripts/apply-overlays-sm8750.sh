#!/usr/bin/env bash
# Apply the AYN Odin 3 (SM8750) handheld overlay onto the extracted SteamOS Frame rootfs.
# Mesa: ships Freedreno / Turnip Adreno 830 Vulkan driver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR="${STEAMOS_WORK:-${ROOT}/sm8750-work}"
R="${STEAMOS_ROOTFS:-${WORKDIR}/rootfs}"
MOD="${ROOT}/external-and-mods"
OVL="${ROOT}/steamos-overlay"
SM8750_OVL="${ROOT}/sm8750-overlay"
# KREL from KOUT's dir name (as apply-overlays.sh does), not hardcoded: the
# from-source kernel self-reports "7.2.0-sm8750-steamos", not "7.2.0".
KOUT="$(readlink -f "${KERNEL_OUT:-${WORKDIR}/kernel-sm8750-release/7.2.0}")"
KREL="$(basename "$KOUT")"
STOCK="${R}/opt/stock-steamos"
MESA_SO="${SM8750_MESA_SO:-${SM8750_OVL}/usr/lib/libvulkan_freedreno.so}"
if [[ -z "${MESA_STACK:-}" && -d "${WORKDIR}/mesa-stack/aarch64" ]]; then
  MESA_STACK="${WORKDIR}/mesa-stack"
fi
LOG="${WORKDIR}/odin3-apply.log"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*" | tee -a "$LOG"; }

[[ -d "$R/usr/bin" ]] || die "missing rootfs at $R"
[[ -f "$KOUT/boot/KERNEL" ]] || die "missing kernel at $KOUT/boot/KERNEL"
[[ -d "$KOUT/modules/$KREL" ]] || die "missing modules at $KOUT/modules/$KREL"
[[ -d "$KOUT/firmware" ]] || die "missing firmware at $KOUT/firmware"

: >"$LOG"
log "== $(date -Iseconds) apply Odin 3 mods into $R"

backup() {
  local src="$1" dest="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$dest")"
  if [[ ! -e "$dest" ]]; then
    cp -a "$src" "$dest"
  fi
}

install_file() {
  local src="$1" dest="$2" mode="${3:-}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
  [[ -n "$mode" ]] && chmod "$mode" "$dest"
}

# ---------------------------------------------------------------------------
# 1. Kernel, Modules & Firmware
# ---------------------------------------------------------------------------
log "== staging kernel ${KREL}"
mkdir -p "$R/boot" "$R/usr/lib/modules" "$R/usr/lib/firmware" "$R/opt/steamos-sm8750"
if [[ -e "$R/boot/KERNEL" && ! -e "$STOCK/boot/KERNEL" ]]; then
  mkdir -p "$STOCK/boot"
  cp -a "$R/boot/KERNEL" "$STOCK/boot/KERNEL" 2>/dev/null || true
fi
cp -a "$KOUT/boot/KERNEL" "$R/boot/KERNEL"
cp -a "$KOUT/boot/KERNEL.md5" "$R/boot/KERNEL.md5"
chmod 0644 "$R/boot/KERNEL" "$R/boot/KERNEL.md5"

# Clean out old Frame modules and install SM8750 modules
# EXTRA_KERNEL_OUT: more kernels whose modules this rootfs carries (the
# Lenovo Legion Y700 Gen 4 has its own kernel on the same system).
read -ra EXTRA_KOUTS <<<"${EXTRA_KERNEL_OUT:-}"
keep=(! -name "$KREL")
for k in "${EXTRA_KOUTS[@]}"; do keep+=(! -name "$(basename "$(readlink -f "$k")")"); done
find "$R/usr/lib/modules" -mindepth 1 -maxdepth 1 "${keep[@]}" -exec rm -rf {} + 2>/dev/null || true
cp -a "$KOUT/modules/$KREL" "$R/usr/lib/modules/$KREL"
for k in "${EXTRA_KOUTS[@]}"; do
  k="$(readlink -f "$k")"; kr="$(basename "$k")"
  [[ -d "$k/modules/$kr" ]] || die "missing modules at $k/modules/$kr"
  rm -rf "$R/usr/lib/modules/$kr"
  cp -a "$k/modules/$kr" "$R/usr/lib/modules/$kr"
  mkdir -p "$R/opt/steamos-sm8750/$kr"
  cp -a "$k/config-$kr" "$k/dtbs" "$R/opt/steamos-sm8750/$kr/" 2>/dev/null || true
  if [[ "$kr" == *-elden-steamos ]]; then
    log "== Lenovo Legion Y700 Gen 4 (${kr})"
    "${ROOT}/scripts/install-elden.sh" "$R" || die "elden install failed"
    install_file "$OVL/usr/lib/steamos-arm/tablet-firmware" "$R/usr/lib/steamos-arm/tablet-firmware" 0755
    install_file "$OVL/usr/lib/steamos-arm/tablet-firmware-boot" "$R/usr/lib/steamos-arm/tablet-firmware-boot" 0755
    install_file "$OVL/usr/lib/systemd/system/steamos-arm-tablet-firmware.service" \
      "$R/usr/lib/systemd/system/steamos-arm-tablet-firmware.service" 0644
    mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
    ln -sfn ../steamos-arm-tablet-firmware.service \
      "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tablet-firmware.service"
  fi
done

# Internal storage installer (ufs-install): the Odin 3 and Pocket FIT Elite
# from the SD card, the Legion Y700 Gen 4 from a USB drive.
ONLY_UFS=1 STEAMOS_HOME="$R/home/steamos" "${ROOT}/scripts/install-vendor-apps.sh" "$R" \
  || die "installer install failed"

# Merge SM8750 firmware
cp -a "$KOUT/firmware/." "$R/usr/lib/firmware/"

# ---------------------------------------------------------------------------
# 2. Gamescope (SM8750 aarch64 build)
# ---------------------------------------------------------------------------
log "== gamescope binaries"
# Our gamescope (same build as the 8 Gen 2/3 images, GAMESCOPE_BUILD) when
# given: it has GAMESCOPE_FAKE_OUTPUT_MM, without which Steam saw the Odin 3's
# real (small, portrait) panel size and made the UI far too big. It also has
# --force-composition-rotation, which the Odin 3 session uses.
GSBUILD="${GAMESCOPE_BUILD:-}"
if [[ -n "$GSBUILD" ]]; then
  [[ -x "$GSBUILD/src/gamescope" ]] || die "no built gamescope in $GSBUILD"
  grep -aq "force-composition-rotation" "$GSBUILD/src/gamescope" \
    || die "$GSBUILD gamescope has no --force-composition-rotation"
  for b in gamescope gamescopectl gamescopereaper gamescopestream; do
    backup "$R/usr/bin/$b" "$STOCK/usr/bin/$b"
    install_file "$GSBUILD/src/$b" "$R/usr/bin/$b" 0755
    install_file "$GSBUILD/src/$b" "$R/usr/local/bin/$b" 0755
  done
  if [[ -f "$GSBUILD/layer/libVkLayer_FROG_gamescope_wsi_aarch64.so" ]]; then
    install_file "$GSBUILD/layer/libVkLayer_FROG_gamescope_wsi_aarch64.so" \
      "$R/usr/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so" 0755
  fi
fi
for b in gamescope gamescopectl gamescopereaper gamescopestream; do
  if [[ -z "$GSBUILD" && -f "$SM8750_OVL/usr/bin/$b" ]]; then
    backup "$R/usr/bin/$b" "$STOCK/usr/bin/$b"
    install_file "$SM8750_OVL/usr/bin/$b" "$R/usr/bin/$b" 0755
    install_file "$SM8750_OVL/usr/bin/$b" "$R/usr/local/bin/$b" 0755
  fi
done

if [[ -d "${MOD}/gamescope/scripts" ]]; then
  mkdir -p "$R/usr/share/gamescope" "$R/usr/local/share/gamescope"
  cp -a "${MOD}/gamescope/scripts" "$R/usr/share/gamescope/"
  cp -a "${MOD}/gamescope/scripts" "$R/usr/local/share/gamescope/"
fi

# ---------------------------------------------------------------------------
# 3. Base SteamOS Overlay (Session, Desktop, Services)
# ---------------------------------------------------------------------------
log "== base steamos overlay"
backup "$R/usr/lib/steamos/gamescope-session" "$STOCK/usr/lib/steamos/gamescope-session"
install_file "$OVL/usr/lib/steamos/gamescope-session" \
  "$R/usr/lib/steamos/gamescope-session" 0755
install_file "$OVL/usr/lib/steamos/panel-modes" \
  "$R/usr/lib/steamos/panel-modes" 0755
install_file "$OVL/usr/lib/steamos/desktop-outputs" \
  "$R/usr/lib/steamos/desktop-outputs" 0755
backup "$R/usr/lib/steamos/gamescope-onready" "$STOCK/usr/lib/steamos/gamescope-onready"
install_file "$OVL/usr/lib/steamos/gamescope-onready" \
  "$R/usr/lib/steamos/gamescope-onready" 0755
install_file "$OVL/usr/lib/steamos/sm8550-steam-focus" \
  "$R/usr/lib/steamos/sm8550-steam-focus" 0755
# Game Mode: bring a game back when Quick Access / the Steam menu closes
# (games that minimise themselves came back black or frozen).
install_file "${ROOT}/sm8650-overlay/usr/lib/konkr/konkr-focusfix" "$R/usr/lib/konkr/konkr-focusfix" 0755
install_file "${ROOT}/sm8650-overlay/usr/lib/systemd/user/konkr-focusfix.service" \
  "$R/usr/lib/systemd/user/konkr-focusfix.service" 0644
mkdir -p "$R/usr/lib/systemd/user/gamescope-session.target.wants"
ln -sfn ../konkr-focusfix.service \
  "$R/usr/lib/systemd/user/gamescope-session.target.wants/konkr-focusfix.service"
install_file "$OVL/usr/lib/steamos/sm8550-volume-keys" \
  "$R/usr/lib/steamos/sm8550-volume-keys" 0755
install_file "$OVL/usr/lib/steamos/odin-bin/steamvr" \
  "$R/usr/lib/steamos/odin-bin/steamvr" 0755
backup "$R/usr/bin/steamos-select-branch" "$STOCK/usr/bin/steamos-select-branch"
install_file "$OVL/usr/bin/steamos-select-branch" \
  "$R/usr/bin/steamos-select-branch" 0755

# Desktop Plasma
install_file "$OVL/usr/lib/environment.d/62-steamos-arm-no-wsi-dialogs.conf" \
  "$R/usr/lib/environment.d/62-steamos-arm-no-wsi-dialogs.conf" 0644
install_file "$OVL/usr/lib/steamos/sm8550-prepare-plasma" \
  "$R/usr/lib/steamos/sm8550-prepare-plasma" 0755
install_file "$OVL/usr/lib/steamos/sm8550-startplasma" \
  "$R/usr/lib/steamos/sm8550-startplasma" 0755
backup "$R/usr/bin/steamos-session-select" "$STOCK/usr/bin/steamos-session-select"
install_file "$OVL/usr/bin/steamos-session-select" \
  "$R/usr/bin/steamos-session-select" 0755
backup "$R/usr/share/wayland-sessions/plasma.desktop" \
  "$STOCK/usr/share/wayland-sessions/plasma.desktop"
install_file "$OVL/usr/share/wayland-sessions/plasma.desktop" \
  "$R/usr/share/wayland-sessions/plasma.desktop" 0644
install_file "$OVL/usr/lib/systemd/user/sm8550-plasma-env.service" \
  "$R/usr/lib/systemd/user/sm8550-plasma-env.service" 0644

# System update hooks, same as the 8 Gen 2/3 images: this image has no A/B
# partitions or RAUC payload, so Valve's steamos-update failed with "Update
# error" in Steam (Odin 3 tester). Ours reports up to date.
backup "$R/usr/bin/steamos-update" "$STOCK/usr/bin/steamos-update"
install_file "$OVL/usr/bin/steamos-update" "$R/usr/bin/steamos-update" 0755
install_file "$OVL/usr/bin/steamos-polkit-helpers/steamos-update" \
  "$R/usr/bin/steamos-polkit-helpers/steamos-update" 0755
install_file "$OVL/usr/bin/jupiter-initial-firmware-update" "$R/usr/bin/jupiter-initial-firmware-update" 0755
install_file "$OVL/usr/bin/steamos-mandatory-update" "$R/usr/bin/steamos-mandatory-update" 0755

# Clean handheld RUNSTEAM.sh (handheld flags only, no VR headset flags)
backup "$R/usr/share/deckard/RUNSTEAM.sh" "$STOCK/usr/share/deckard/RUNSTEAM.sh"
install_file "$OVL/usr/share/deckard/RUNSTEAM.sh" \
  "$R/usr/share/deckard/RUNSTEAM.sh" 0755

# Systemd user drop-ins (includes 99-odin.conf with TimeoutStartSec=600, BindsTo gamescope, etc.)
if [[ -d "$OVL/usr/lib/systemd/user" ]]; then
  mkdir -p "$R/usr/lib/systemd/user"
  cp -a "$OVL/usr/lib/systemd/user/." "$R/usr/lib/systemd/user/"
fi

# Expand home partition service on first boot
install_file "$OVL/usr/lib/steamos/steamos-sm8550-expand-home" \
  "$R/usr/lib/steamos/steamos-sm8550-expand-home" 0755
install_file "$OVL/usr/lib/systemd/system/steamos-sm8550-expand-home.service" \
  "$R/usr/lib/systemd/system/steamos-sm8550-expand-home.service" 0644
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/steamos-sm8550-expand-home.service \
  "$R/etc/systemd/system/multi-user.target.wants/steamos-sm8550-expand-home.service"

# VR crash services cleanup (disable Valve Headset daemons)
for svc in \
  vrcompositor.service vrserver.service steamos-headset-adb.service \
  steamos-headset-adb.path steamos-headset-usb-gadget.service \
  steamos-headset-usb-gadget.path deckard-factory-recovery.service \
  steamos-headset-fpga-config.service steamos-power-monitor.service \
  deckard-boot-images.service deckard-fan-control.service \
  deckard-fpga.service deckard-led-control.service \
  deckard-typec-logger.service dsp_service.service \
  iris-driver-rebind.service steamvr-program-ble.service \
  steamvr-set-kernel-thread-priorities.service \
  steamvr-v4l2loopback.service deckard-charger.service \
  deckard-power-monitor.service adbd.service adbd-pre.service \
  adbd-post.service usb-gadget.target usb-gadget.service \
  usb-gadget-init.service 'usb-ncm-gadget@.service' \
  'usb-ncm-dnsmasq@.service' 'usb-ncm-gadget@usb0.service' \
  'usb-ncm-dnsmasq@usb0.service'
do
  rm -f "$R/etc/systemd/system/multi-user.target.wants/${svc}" \
        "$R/etc/systemd/system/default.target.wants/${svc}" \
        "$R/etc/systemd/user/default.target.wants/${svc}" 2>/dev/null || true
  mkdir -p "$R/etc/systemd/system"
  ln -sfn /dev/null "$R/etc/systemd/system/${svc}"
done

# Set boot target to graphical.target (SDDM autologin into Gamescope)
mkdir -p "$R/etc/systemd/system"
ln -sfn /usr/lib/systemd/system/graphical.target "$R/etc/systemd/system/default.target"

# User-level service masking (steamvr: no SteamVR hardware on Odin 3).
# steamos-manager needs tracefs; mask it only if the staged kernel's own
# saved .config says it doesn't have it (only install_output() writes one,
# so prebuilt/unknown kernels default to masked).
mkdir -p "$R/etc/systemd/user"
for usvc in steamvr.service steamvr-proxmicmute.service steamvr-v4l2cam.service \
            sm8550-audio-pipewire.service; do
  ln -sfn /dev/null "$R/etc/systemd/user/${usvc}"
done
KERNEL_HAS_TRACEFS=0
KCFG="$(ls "$KOUT"/config-* 2>/dev/null | head -1 || true)"
[[ -n "$KCFG" ]] && grep -q '^CONFIG_FTRACE=y' "$KCFG" && KERNEL_HAS_TRACEFS=1
if [[ "$KERNEL_HAS_TRACEFS" == 1 ]]; then
  log "== steamos-manager: enabled (kernel has CONFIG_FTRACE=y)"
  # Actively unmask, not just "don't mask": $R can be a rootfs reused from an
  # earlier build (e.g. a prior prebuilt-kernel run) that already masked it.
  rm -f "$R/etc/systemd/user/steamos-manager.service" \
    "$R/etc/systemd/user/steamos-manager-session-cleanup.service"
else
  log "== steamos-manager: masked (no tracefs in this kernel)"
  for usvc in steamos-manager.service steamos-manager-session-cleanup.service; do
    ln -sfn /dev/null "$R/etc/systemd/user/${usvc}"
  done
fi
rm -f "$R/etc/systemd/user/wireplumber.service" "$R/etc/systemd/user/sm8550-volume-keys.service" 2>/dev/null || true

# Volume keys daemon for Odin 3 (handles gpio-keys VOLUP and pmic_resin VOLDOWN)
mkdir -p "$R/usr/lib/systemd/user/default.target.wants" "$R/etc/systemd/user/default.target.wants"
ln -sfn /usr/lib/systemd/user/sm8550-volume-keys.service \
  "$R/usr/lib/systemd/user/default.target.wants/sm8550-volume-keys.service"
ln -sfn /usr/lib/systemd/user/sm8550-volume-keys.service \
  "$R/etc/systemd/user/default.target.wants/sm8550-volume-keys.service"

# Disable steamos-log-submitter to prevent coredump storm on errors
mkdir -p "$R/etc/systemd/system"
ln -sfn /dev/null "$R/etc/systemd/system/steamos-log-submitter.service"

# User 'steamos' in seat group (GID 974) for seatd / DRM master
if grep -q '^seat:' "$R/etc/group" 2>/dev/null; then
  sed -i '/^seat:/ s/$/,steamos/; s/:,/:/' "$R/etc/group"
else
  echo "seat:x:974:steamos" >> "$R/etc/group"
fi

# Passwordless sudo for steamos user
mkdir -p "$R/etc/sudoers.d"
echo 'steamos ALL=(ALL) NOPASSWD: ALL' > "$R/etc/sudoers.d/99-steamos-nopasswd"
chmod 0440 "$R/etc/sudoers.d/99-steamos-nopasswd"

# Low-latency SSH (disable reverse DNS lookup timeout) and enable sshd
mkdir -p "$R/etc/ssh/sshd_config.d"
echo "UseDNS no" > "$R/etc/ssh/sshd_config.d/99-odin-dns.conf"
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/sshd.service "$R/etc/systemd/system/multi-user.target.wants/sshd.service"

# Disable core dump loops from crashing VR audio plugins
mkdir -p "$R/etc/sysctl.d"
echo "kernel.core_pattern = |/bin/false" > "$R/etc/sysctl.d/99-disable-coredump.conf"
cat <<'SYSCTL' >"$R/etc/sysctl.d/99-sm8750-io.conf"
# SD card writeback tuning: batch dirty page flushes to eliminate random I/O stalls
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
SYSCTL

# Clean up Deckard VR headset WirePlumber configs and SteamVR dependency
# Stock Deckard VR configs (40-mic-processing, 60-spatial-audio, etc.) crash WirePlumber with SIGSEGV
# because the VR multi-mic beamforming array and spatializer hardware do not exist on Odin 3.
# Removing them lets WirePlumber use standard ALSA UCM device discovery in /usr/share/wireplumber/.
rm -f "$R/usr/lib/systemd/user/wireplumber.service.d/wireplumber-steamvr.conf" 2>/dev/null || true
if [[ -d "$R/etc/wireplumber/wireplumber.conf.d" ]]; then
  rm -rf "$R/etc/wireplumber/wireplumber.conf.d"
  mkdir -p "$R/etc/wireplumber/wireplumber.conf.d"
fi

# Enable persistent journal logging and boot debug
mkdir -p "$R/var/log/journal" "$R/etc/systemd/journald.conf.d"
chmod 2755 "$R/var/log/journal" 2>/dev/null || true
cat <<'JRNL' >"$R/etc/systemd/journald.conf.d/99-persist.conf"
[Journal]
Storage=persistent
SyncIntervalSec=5s
JRNL

# ---------------------------------------------------------------------------
# 4. Turnip / Mesa Driver (Adreno 830)
# ---------------------------------------------------------------------------
if [[ -f "$MESA_SO" ]]; then
  log "== Turnip Adreno 830 Vulkan driver ($MESA_SO)"
  backup "$R/usr/lib/libvulkan_freedreno.so" "$STOCK/usr/lib/libvulkan_freedreno.so"
  install_file "$MESA_SO" "$R/usr/lib/libvulkan_freedreno.so" 0755
fi
if [[ -f "$SM8750_OVL/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json" ]]; then
  install_file "$SM8750_OVL/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json" \
    "$R/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json" 0644
fi

# ---------------------------------------------------------------------------
# 4b. Pin Turnip for the Performance Overlay (mangoapp)
# ---------------------------------------------------------------------------
# Same mechanism as the SM8650 image's gamescope-session: mangoapp (zink)
# must run on the Turnip it was built against, or it crashes. Without this
# wrapper gamescope-session disables the overlay entirely -- nothing
# installed it for sm8750 before, so it silently did nothing. MESA_STACK
# below removes the pin again when it replaces zink+Turnip together (then
# no pin is needed).
log "== pin Turnip for the Performance Overlay"
TURNIP_FOR_MANGOAPP="$R/usr/lib/libvulkan_freedreno.so"
[[ -f "$STOCK/usr/lib/libvulkan_freedreno.so" ]] && TURNIP_FOR_MANGOAPP="$STOCK/usr/lib/libvulkan_freedreno.so"
mkdir -p "$R/usr/lib/steamos-sm8650/frame-turnip" "$R/usr/share/steamos-sm8650"
install_file "$TURNIP_FOR_MANGOAPP" \
  "$R/usr/lib/steamos-sm8650/frame-turnip/libvulkan_freedreno.so" 0755
cat >"$R/usr/share/steamos-sm8650/frame-turnip_icd.aarch64.json" <<'JSON'
{
    "ICD": {
        "api_version": "1.4.362",
        "library_arch": "64",
        "library_path": "/usr/lib/steamos-sm8650/frame-turnip/libvulkan_freedreno.so"
    },
    "file_format_version": "1.0.1"
}
JSON
install_file "${ROOT}/sm8650-overlay/usr/lib/steamos-sm8650/bin/mangoapp" \
  "$R/usr/lib/steamos-sm8650/bin/mangoapp" 0755
# Our mangoapp (GPU load, clock and VRAM on Adreno; stock shows 0 %), built
# by scripts/build-mangohud-in-rootfs.sh in the same rootfs.
MHBUILD="${MANGOHUD_BUILD:-${WORKDIR:-/work}/mangohud-build}"
if [[ -x "$MHBUILD/mangoapp" ]]; then
  install_file "$MHBUILD/mangoapp" "$R/usr/bin/mangoapp" 0755
else
  log "WARN: no $MHBUILD/mangoapp, the overlay keeps stock (GPU shows 0 %)"
fi
# Hardware video decode for VA-API apps (scripts/install-v4l2-vaapi.sh).
"${SCRIPT_DIR}/install-v4l2-vaapi.sh" "$R" | tee -a "$LOG"
# Hostname from the model, Desktop scale from the panel (scripts/install-device-defaults.sh).
"${SCRIPT_DIR}/install-device-defaults.sh" "$R" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# 5. Odin 3 Overlay (InputPlumber, Display, Audio, Device Manager)
# ---------------------------------------------------------------------------
log "== SM8750 Odin 3 overlay"
if [[ -x "${SCRIPT_DIR}/install-inputplumber-sm8550.sh" ]]; then
  "${SCRIPT_DIR}/install-inputplumber-sm8550.sh" "$R"
  rm -f "$R/usr/lib/systemd/system/inputplumber.service.d/99-sm8550.conf" \
        "$R/etc/inputplumber/devices.d/02-ayn-odin.yaml" 2>/dev/null || true
fi
cp -r --no-preserve=mode,ownership "$SM8750_OVL/." "$R/"
chmod 0755 "$R/usr/lib/steamos/sm8750-audio-setup" 2>/dev/null || true

# 60-odin3-gamescope.conf ships GAMESCOPE_MANGOAPP=0 (mangoapp used to shut
# the Odin 3 down -- same tracefs issue as steamos-manager). Enable only
# when this kernel has it; confirmed stable on real hardware.
if [[ "$KERNEL_HAS_TRACEFS" == 1 ]]; then
  log "== Performance Overlay (mangoapp): enabling (kernel has tracefs)"
  sed -i 's/^GAMESCOPE_MANGOAPP=0$/GAMESCOPE_MANGOAPP=1/' \
    "$R/usr/lib/environment.d/60-odin3-gamescope.conf"
fi

# Our own Mesa (scripts/build-mesa.sh, MESA_STACK=/work/mesa/out): the same
# 26.2.3 stack as the 8 Gen 2 image, with the Adreno 830 ids added (patches/
# 0003). Replaces Valve's whole Mesa natively, in the FEX guest and for
# Lepton, so Turnip and zink always match. Goes after the overlay copy above,
# which may carry a standalone Turnip .so.
if [[ -n "${MESA_STACK:-}" ]]; then
  log "== Mesa: our stack from $MESA_STACK"
  for a in aarch64 x86_64 i386; do
    ls "$MESA_STACK/$a/usr/share/vulkan/icd.d/"freedreno_icd.*.json >/dev/null 2>&1 \
      || die "MESA_STACK has no $a build"
  done
  grep -aq "Adreno (TM) 830" "$MESA_STACK/aarch64/usr/lib/libvulkan_freedreno.so" \
    || die "MESA_STACK Turnip doesn't know the Adreno 830"
  ANDROID_VENDOR="usr/share/guestos/android/vendor/lib64"
  PDB="$R/usr/lib/holo/pacmandb/local"
  for pkg in deckard-mesa-linux-aarch64 deckard-mesa-linux-x86_64 deckard-mesa-android-aarch64; do
    list="$(ls -d "$PDB/${pkg}"-[0-9]*/files 2>/dev/null | head -1)"
    [[ -n "$list" ]] || continue
    grep -v -e '^%' -e '/$' "$list" | grep -E '(\.so[.0-9]*|\.json)$' \
      | grep -v -e 'VkLayer_MESA_vram_report_limit' -e 'graphics_provider.json' \
      | while read -r f; do
          [[ -e "$R/$f" || -L "$R/$f" ]] || continue
          mkdir -p "$STOCK/$(dirname "$f")"
          [[ -e "$STOCK/$f" ]] || cp -a "$R/$f" "$STOCK/$f"
          rm -f "$R/$f"
        done
  done
  rm -f "$R/usr/lib/libvulkan_freedreno.so"
  GUEST="$R/usr/share/guestos/fex-mesa"
  cp -a "$MESA_STACK/aarch64/usr/lib/." "$R/usr/lib/"
  cp -a "$MESA_STACK/aarch64/usr/share/." "$R/usr/share/"
  cp -a "$MESA_STACK/x86_64/usr/lib/." "$GUEST/usr/lib/"
  cp -a "$MESA_STACK/x86_64/usr/share/." "$GUEST/usr/share/"
  cp -a "$MESA_STACK/i386/usr/lib32/." "$GUEST/usr/lib32/"
  cp -a "$MESA_STACK/i386/usr/share/vulkan/." "$GUEST/usr/share/vulkan/"
  # Our zink and Turnip now come as a matched pair, so mangoapp needs no pin
  # to the Frame's Turnip (which only knows some Odin 3 GPU IDs): drop it and
  # the wrapper leaves the system Turnip alone.
  rm -f "$R/usr/share/steamos-sm8650/frame-turnip_icd.aarch64.json"
  rm -rf "$R/usr/lib/steamos-sm8650/frame-turnip"
  if [[ -f "$MESA_STACK/android/$ANDROID_VENDOR/hw/vulkan.freedreno.so" ]]; then
    mkdir -p "$R/$ANDROID_VENDOR"
    cp -a "$MESA_STACK/android/$ANDROID_VENDOR/." "$R/$ANDROID_VENDOR/"
    chown -R root:root "$R/$ANDROID_VENDOR"
  fi
  chown -R root:root "$R/usr/lib/dri" "$GUEST/usr/lib/dri" "$GUEST/usr/lib32/dri"
  # mangoapp uses the system Turnip, no pin to the Frame's.
  rm -rf "$R/usr/lib/steamos-sm8650/frame-turnip" \
    "$R/usr/share/steamos-sm8650/frame-turnip_icd.aarch64.json"
  # No msm DRI driver in our build and no automatic zink fallback: GL goes
  # through zink for the whole session, same as the 8 Gen 2 image.
  mkdir -p "$R/usr/lib/environment.d"
  printf '# Our Mesa: GL goes through zink on Turnip, like the Frame.\nMESA_LOADER_DRIVER_OVERRIDE=zink\n' \
    >"$R/usr/lib/environment.d/60-sm8750-zink.conf"
  chmod 0644 "$R/usr/lib/environment.d/60-sm8750-zink.conf"
  for f in "$R/usr/lib/libvulkan_freedreno.so" "$R/usr/lib/libgallium-"*.so; do
    log "   ${f#$R}: $(grep -a -o -m1 'Mesa [0-9][0-9.]*' "$f" || echo '?')"
  done
else
  rm -f "$R/usr/lib/environment.d/60-sm8750-zink.conf"
fi

# Boot logs to BOOT/debug-logs when BOOT has an empty "debug" file, same
# collector as the 8 Gen 2/3 images. /boot is mounted read-only here, so
# switch it to read-write first.
install -D -m0755 "$MOD/kernel-common/initramfs/bootdebug" "$R/usr/lib/steamos-arm/bootdebug"
install -D -m0644 "${ROOT}/sm8550-overlay/usr/lib/systemd/system/steamos-arm-bootdebug-file.service" \
  "$R/usr/lib/systemd/system/steamos-arm-bootdebug-file.service"
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants" "$R/usr/lib/systemd/system/steamos-arm-bootdebug-file.service.d"
ln -sfn ../steamos-arm-bootdebug-file.service \
  "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-bootdebug-file.service"
printf '[Service]\nExecStartPre=-/bin/mount -o remount,rw /boot\n' \
  >"$R/usr/lib/systemd/system/steamos-arm-bootdebug-file.service.d/10-odin3-boot-rw.conf"

install_file "$OVL/usr/share/pipewire/pipewire-pulse.conf.d/60-games-keep-device-volume.conf" \
  "$R/usr/share/pipewire/pipewire-pulse.conf.d/60-games-keep-device-volume.conf" 0644
# Same audio buffer floor as the other chips: games asking for tiny buffers
# made the DSP path underrun (crackles).
install_file "$OVL/usr/share/pipewire/pipewire.conf.d/99-sm8550-buffers.conf" \
  "$R/usr/share/pipewire/pipewire.conf.d/99-sm8550-buffers.conf" 0644
install_file "$OVL/usr/share/pipewire/pipewire-pulse.conf.d/99-sm8550-buffers.conf" \
  "$R/usr/share/pipewire/pipewire-pulse.conf.d/99-sm8550-buffers.conf" 0644

# Shared tuning from the 8 Gen 3 overlay (the 8 Gen 2 image gets it with the
# whole overlay): ntsync usable by Proton, BFQ and read-ahead for the microSD,
# dirty limits that keep a Steam install from freezing the UI, and realtime
# audio threads that don't pin the CPU clock.
install_file "${ROOT}/sm8650-overlay/usr/lib/udev/rules.d/60-konkr-performance.rules" \
  "$R/usr/lib/udev/rules.d/60-konkr-performance.rules" 0644
install_file "${ROOT}/sm8650-overlay/usr/lib/modules-load.d/ntsync.conf" \
  "$R/usr/lib/modules-load.d/ntsync.conf" 0644
install_file "${ROOT}/sm8650-overlay/usr/lib/sysctl.d/60-konkr-io.conf" \
  "$R/usr/lib/sysctl.d/60-konkr-io.conf" 0644
install_file "${ROOT}/sm8650-overlay/usr/lib/sysctl.d/21-konkr-sched-rt.conf" \
  "$R/usr/lib/sysctl.d/21-konkr-sched-rt.conf" 0644

# Audio setup service
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
cat <<'UNIT' >"$R/etc/systemd/system/sm8750-audio-setup.service"
[Unit]
Description=AYN Odin 3 Audio Setup
After=sound.target

[Service]
Type=oneshot
ExecStart=/usr/lib/steamos/sm8750-audio-setup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sfn /etc/systemd/system/sm8750-audio-setup.service \
  "$R/etc/systemd/system/multi-user.target.wants/sm8750-audio-setup.service"

# Odin 3 platform & fan control daemon (fan curves, thermal protection, profiles)
mkdir -p "$R/var/lib/odin3" "$R/run/odin3"
chmod 0755 "$R/usr/lib/odin3/odin3d" "$R/usr/bin/odin3ctl" 2>/dev/null || true
chmod 0644 "$R/etc/odin3.conf" "$R/usr/lib/systemd/system/odin3d.service" 2>/dev/null || true
ln -sfn /usr/lib/systemd/system/odin3d.service \
  "$R/etc/systemd/system/multi-user.target.wants/odin3d.service"

# Steam (Frame client) launches every game with
# VK_INSTANCE_LAYERS=VK_LAYER_VALVE_rpo:VK_LAYER_VALVE_fdm_injection: the
# headset's renderpass optimizer (rewrites shaders, tuned for the Frame's
# Adreno 750) and eye-tracked foveation (FDM). A handheld has no headset,
# so drop both layers; the loader then just warns that they're missing.
mkdir -p "$R/usr/share/vulkan/explicit_layer.d.frame"
for _l in VkLayer_VALVE_rpo.json VkLayer_VALVE_fdm_injection.json; do
  if [[ -f "$R/usr/share/vulkan/explicit_layer.d/$_l" ]]; then
    mv -f "$R/usr/share/vulkan/explicit_layer.d/$_l" "$R/usr/share/vulkan/explicit_layer.d.frame/"
  fi
done
# Permissions
find "$R/usr/share/alsa/ucm2/AYN/Odin3" "$R/usr/share/alsa/ucm2/KONKR" "$R/usr/share/alsa/ucm2/conf.d/sm8750" \
  -type d -exec chmod 0755 {} + 2>/dev/null || true
find "$R/usr/share/alsa/ucm2/AYN/Odin3" "$R/usr/share/alsa/ucm2/KONKR" "$R/usr/share/alsa/ucm2/conf.d/sm8750" \
  -type f -exec chmod 0644 {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. User Home / Decky Loader
# ---------------------------------------------------------------------------
log "== home/steamos setup"
HOME_DST="${STEAMOS_HOME:-$R/home/steamos}"
mkdir -p "$HOME_DST/.cache" "$HOME_DST/.config" "$HOME_DST/homebrew/services"

# v3.2.9's bundled Python is missing http.server, socketserver and
# configparser, so plugin backends that import them die at startup
# (SteamGridDB). Fixed in v3.2.10 (decky-loader #968/#970).
DECKY_VERSION=v3.2.10-pre1
DECKY_LOADER="${MOD}/Decky/loader/PluginLoader-${DECKY_VERSION}"
if [[ ! -s "$DECKY_LOADER" ]]; then
  mkdir -p "${DECKY_LOADER%/*}"
  curl -fL -o "$DECKY_LOADER.part" \
    "https://github.com/SteamDeckHomebrew/decky-loader/releases/download/${DECKY_VERSION}/PluginLoader" &&
    mv "$DECKY_LOADER.part" "$DECKY_LOADER"
fi
[[ -s "$DECKY_LOADER" ]] || die "Decky loader ${DECKY_VERSION} missing and download failed"
# Decky's PluginLoader is x86-64, so the unit runs it through box64
# (make-steamos-sm8750.sh builds it into the rootfs). Beta 2 only had the
# wants link, pointing at a unit that was never installed: no Decky, so no
# Handheld Control either.
[[ -x "$R/usr/local/bin/box64" ]] || die "box64 missing from the rootfs (Decky needs it)"
mkdir -p "$HOME_DST/homebrew/settings" "$HOME_DST/homebrew/data" "$HOME_DST/homebrew/logs"
install -m0755 "$DECKY_LOADER" "$HOME_DST/homebrew/services/PluginLoader"
printf '%s' "$DECKY_VERSION" >"$HOME_DST/homebrew/services/.loader.version"
install_file "${ROOT}/sm8650-overlay/usr/lib/systemd/system/plugin_loader.service" \
  "$R/usr/lib/systemd/system/plugin_loader.service" 0644
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
ln -sfn ../plugin_loader.service "$R/usr/lib/systemd/system/multi-user.target.wants/plugin_loader.service"
# Updating Decky writes its own unit to /etc (runs the x86 binary without
# box64); this drop-in keeps box64 in front whatever unit file wins.
install_file "$OVL/usr/lib/systemd/system/plugin_loader.service.d/50-steamos-arm-box64.conf" \
  "$R/usr/lib/systemd/system/plugin_loader.service.d/50-steamos-arm-box64.conf" 0644
# Handheld Control: profiles, fan and stick lighting in Quick Access (talks
# to odin3d here, konkrd on the other images).
HC_SRC="${MOD}/Decky/sm8650/konkr-control"
HC_DST="$HOME_DST/homebrew/plugins/konkr-control"
rm -rf "$HC_DST"; mkdir -p "$HC_DST/dist"
install -m0644 "$HC_SRC/plugin.json" "$HC_SRC/main.py" "$HC_DST/"
[[ -f "$HC_SRC/package.json" ]] && install -m0644 "$HC_SRC/package.json" "$HC_DST/"
install -m0644 "$HC_SRC/dist/index.js" "$HC_DST/dist/"
# Lossless Scaling frame generation, the same as the 8 Gen 3 / 8 Gen 2 images:
# the lsfg-vk 2.0 ARM64 layer (registered as an implicit Vulkan layer, off
# until the plugin turns it on for a game) and its Decky plugin, which starts
# new profiles in performance mode.
log "== lsfg-vk 2.0 (ARM layer + Decky plugin)"
for prefix in "$R/usr" "$R/usr/local"; do
  rm -f "$prefix/lib/liblsfg-vk.so" "$prefix/lib/liblsfg-vk-arm64.so" \
    "$prefix/share/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json" \
    "$prefix/share/vulkan/implicit_layer.d/VkLayer_LS_frame_generation_arm64.json"
done
install_file "${ROOT}/sm8650-overlay/usr/lib/liblsfg-vk-layer-arm64.so" "$R/usr/lib/liblsfg-vk-layer-arm64.so" 0644
install_file "${ROOT}/sm8650-overlay/usr/lib/liblsfg-vk-layer-arm64.so.README" "$R/usr/lib/liblsfg-vk-layer-arm64.so.README" 0644
install_file "${ROOT}/sm8650-overlay/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation_arm64.json" \
  "$R/usr/share/vulkan/implicit_layer.d/VkLayer_LSFGVK_frame_generation_arm64.json" 0644
mkdir -p "$R/usr/share/licenses"
cp -r --no-preserve=mode,ownership "${ROOT}/sm8650-overlay/usr/share/licenses/lsfg-vk" "$R/usr/share/licenses/"
rsync -a --copy-links --exclude '.local/lib/liblsfg-vk.so' "${MOD}/Decky/Plug-ins/" "$HOME_DST/"
rm -f "$HOME_DST/.local/lib/liblsfg-vk.so" \
  "$HOME_DST/.local/share/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json"
[[ -f "$HOME_DST/.config/lsfg-vk/conf.toml" ]] && sed -i 's|/home/steam/|/home/steamos/|g' "$HOME_DST/.config/lsfg-vk/conf.toml"
# Decky starts the plugin's helpers; without this they outlive a stop and
# hold up shutdown.
install_file "$OVL/usr/share/steamos-odin/plugin_loader.service.d/fast-stop.conf" \
  "$R/usr/lib/systemd/system/plugin_loader.service.d/fast-stop.conf" 0644
[[ -r "$R/usr/lib/liblsfg-vk-layer-arm64.so" && -f "$HOME_DST/homebrew/plugins/decky-lsfg-vk/plugin.json" ]] \
  || die "lsfg-vk missing from the 8 Elite image"
chown -R 1000:1000 "$HOME_DST/homebrew"
# Loadout: emulators, PC game stores and apps (engine + Decky plugin).
"${SCRIPT_DIR}/install-hub.sh" "$R" "$HOME_DST"

# GPU/GMU hang dumps kept past the kernel's five minutes (debug-logs copies them).
install_file "$OVL/usr/lib/steamos-arm/save-devcoredump" "$R/usr/lib/steamos-arm/save-devcoredump" 0755
# Charging/discharge time for Steam (the Frame's charger daemon is masked).
install_file "$OVL/usr/lib/steamos-arm/vpower" "$R/usr/lib/steamos-arm/vpower" 0755
# Keep the system's own drive and internal storage out of Steam's storage
# settings (it offered to format the microSD card the system runs from).
install_file "$OVL/usr/lib/steamos-arm/is-system-disk" "$R/usr/lib/steamos-arm/is-system-disk" 0755
install_file "$OVL/usr/lib/udev/rules.d/98-steamos-arm-system-disk.rules" \
  "$R/usr/lib/udev/rules.d/98-steamos-arm-system-disk.rules" 0644
# Wi-Fi back quickly after s2idle (one-channel scan, then retries).
install_file "$OVL/usr/lib/steamos-arm/steamos-arm-wifi-wake" "$R/usr/lib/steamos-arm/steamos-arm-wifi-wake" 0755
# ...run around each s2idle sleep by systemd-sleep here (konkr-sleep on the
# other images).
install_file "$SM8750_OVL/usr/lib/systemd/system-sleep/steamos-arm-wifi-wake" \
  "$R/usr/lib/systemd/system-sleep/steamos-arm-wifi-wake" 0755
install_file "$OVL/usr/lib/systemd/system/steamos-arm-vpower.service" \
  "$R/usr/lib/systemd/system/steamos-arm-vpower.service" 0644
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
ln -sfn ../steamos-arm-vpower.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-vpower.service"
# Desktop Mode: restart the portal if it came up before the Desktop's
# environment (Steam's right-stick mouse needs its KDE back end).
install_file "$OVL/usr/lib/steamos-arm/desktop-portal-fix" "$R/usr/lib/steamos-arm/desktop-portal-fix" 0755
install_file "$OVL/etc/xdg/autostart/steamos-arm-desktop-portal-fix.desktop" \
  "$R/etc/xdg/autostart/steamos-arm-desktop-portal-fix.desktop" 0644
# Updates through Steam's own update button: the agent, the root service
# that stages an update, the polkit rule letting the user start only that,
# and the key update packages are signed with.
install_file "$OVL/usr/lib/steamos-arm/update-agent" "$R/usr/lib/steamos-arm/update-agent" 0755
install_file "$OVL/usr/lib/systemd/system/steamos-arm-update.service" \
  "$R/usr/lib/systemd/system/steamos-arm-update.service" 0644
install_file "$OVL/usr/lib/systemd/user/steamos-manager-session-cleanup.service.d/10-steamos-arm-timeout.conf" \
  "$R/usr/lib/systemd/user/steamos-manager-session-cleanup.service.d/10-steamos-arm-timeout.conf" 0644
install_file "$OVL/usr/lib/systemd/system/user@.service.d/20-steamos-arm-io.conf" \
  "$R/usr/lib/systemd/system/user@.service.d/20-steamos-arm-io.conf" 0644
install_file "$OVL/usr/lib/systemd/system/steamos-arm-update-cleanup.service" \
  "$R/usr/lib/systemd/system/steamos-arm-update-cleanup.service" 0644
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
ln -sfn ../steamos-arm-update-cleanup.service \
  "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-update-cleanup.service"
install_file "$OVL/usr/share/polkit-1/rules.d/60-steamos-arm-update.rules" \
  "$R/usr/share/polkit-1/rules.d/60-steamos-arm-update.rules" 0644
install_file "$OVL/usr/share/steamos-arm/update/signing.pub" \
  "$R/usr/share/steamos-arm/update/signing.pub" 0644
# The updater itself (the other images get it with the vendor apps).
install -d -m0755 "$R/usr/share/konkr-update"
install -m0644 "$ROOT/external-and-mods/konkr-update/konkr-update.py" "$R/usr/share/konkr-update/konkr-update.py"
# Store plugins that break on the Steam client we ship, fixed where Decky
# installs them (SteamGridDB 1.7.1's footer glyph lookup for now).
install_file "$OVL/usr/lib/steamos-arm/decky-plugin-fixes" "$R/usr/lib/steamos-arm/decky-plugin-fixes" 0755
for u in steamos-arm-decky-plugin-fixes.service steamos-arm-decky-plugin-fixes.path; do
  install_file "$OVL/usr/lib/systemd/system/$u" "$R/usr/lib/systemd/system/$u" 0644
  ln -sfn "../$u" "$R/usr/lib/systemd/system/multi-user.target.wants/$u"
done
install_file "$OVL/usr/lib/udev/rules.d/70-steamos-arm-devcoredump.rules" \
  "$R/usr/lib/udev/rules.d/70-steamos-arm-devcoredump.rules" 0644

# Return to Gaming Mode on the desktop, as on the 8 Gen 2 / 8 Gen 3 images.
# This image never had it, so Desktop Mode had no way back but a restart.
# Desktop Mode touch keyboard (GitHub #36): the same plasma-keyboard the
# other images build, and KWin told to show it for a tapped text field.
if [[ ! -x "$R/usr/bin/plasma-keyboard" ]]; then
  log "== plasma-keyboard 0.1.0 (desktop touch keyboard)"
  "${SCRIPT_DIR}/build-plasma-keyboard.sh" "$R" \
    || die "plasma-keyboard is required (Desktop Mode touch keyboard)"
fi
# The touch keyboard draws itself in software: through zink its Vulkan
# swapchain asked for explicit sync on a panel surface KWin had just replaced,
# KWin dropped the connection and the keyboard was gone for the session.
sed -i 's|^Exec=plasma-keyboard$|Exec=env QT_QUICK_BACKEND=software plasma-keyboard|' \
  "$R/usr/share/applications/org.kde.plasma.keyboard.desktop"
grep -q '^Exec=env QT_QUICK_BACKEND=software plasma-keyboard$' \
  "$R/usr/share/applications/org.kde.plasma.keyboard.desktop" || die "touch keyboard Exec not set"
KWIN_IM='/usr/share/applications/org.kde.plasma.keyboard.desktop'
if ! grep -q '^\[Wayland\]' "$R/etc/xdg/kwinrc" 2>/dev/null; then
  mkdir -p "$R/etc/xdg"
  printf '\n[Wayland]\nInputMethod[$e]=%s\nVirtualKeyboardEnabled=true\n' "$KWIN_IM" >>"$R/etc/xdg/kwinrc"
fi

log "== Return to Gaming Mode desktop icon"
install_file "$OVL/etc/skel/Desktop/Return.desktop" "$R/etc/skel/Desktop/Return.desktop" 0644
install_file "$OVL/etc/xdg/plasma-workspace/env/set-return-icon.sh" \
  "$R/etc/xdg/plasma-workspace/env/set-return-icon.sh" 0755
install_file "$OVL/usr/share/icons/hicolor/scalable/apps/steamos-gamemode.svg" \
  "$R/usr/share/icons/hicolor/scalable/apps/steamos-gamemode.svg" 0644
install_file "$OVL/etc/skel/Desktop/Return.desktop" "$R/usr/share/applications/steamos-gamemode.desktop" 0644
install_file "$OVL/etc/skel/Desktop/Return.desktop" "$HOME_DST/Desktop/Return.desktop" 0755
chown -R 1000:1000 "$HOME_DST/Desktop"

# Complete Steam ARM client in the image, same as the 8 Gen 2 / 8 Gen 3 builds.
# Otherwise first boot unpacks ~2.5 GB of Steam on the SD card behind a black
# screen and a 10 min service timeout. No complete client = no image.
STEAM_HOME="$HOME_DST/.local/share/Steam"
log "== complete Steam ARM client"
mkdir -p "$STEAM_HOME"
"${SCRIPT_DIR}/install-complete-steam-client.sh" "$STEAM_HOME" \
  || die "complete Steam client installation failed"
[[ -x "$STEAM_HOME/steamrtarm64/steam" && -s "$STEAM_HOME/steamrtarm64/steamui.so" ]] \
  || die "Steam client in $STEAM_HOME is incomplete"
if [[ -x "$R/usr/lib/steamos/sm8550-patch-steamui" && -d "$STEAM_HOME/steamui" ]]; then
  "$R/usr/lib/steamos/sm8550-patch-steamui" "$STEAM_HOME/steamui" || true
fi
touch "$STEAM_HOME/.install-complete"

# Seed Odin 3 default controller mapping and UI scale factor into config.vdf
mkdir -p "$STEAM_HOME/config"
cat <<'VDF' >"$STEAM_HOME/config/config.vdf"
"InstallConfigStore"
{
	"SDL_GamepadBind"		"03000000202000000130000001000000,AYN Odin3 Gamepad,crc:95bb,platform:Linux,a:b0,b:b1,x:b3,y:b2,dpleft:b13,dpright:b14,dpup:b11,dpdown:b12,leftx:a0,lefty:a1,leftstick:b9,rightx:a3,righty:a4,rightstick:b10,leftshoulder:b4,lefttrigger:a2,rightshoulder:b5,righttrigger:a5,back:b6,start:b7,guide:b8,misc1:b15,steam:2,"
	"UI"
	{
		"display"
		{
			"Current"
			{
				"MinScaleFactor"		"0.711512446403503418"
				"MaxScaleFactor"		"3.40971922874450684"
				"IsExternalDisplay"		"1"
				"name"		"External: gamescope 6\"|||Windowed"
				"AutoScaleFactor"		"2.80762958526611328"
				"ScaleFactor"		"2.38840627670288086"
			}
			"External: gamescope 6\"|||Windowed"
			{
				"ScaleFactor"		"2.38840627670288086"
			}
		}
	}
	"SteamOS"
	{
		"WifiForceWPASupplicant"		"1"
	}
}
VDF

install_file "$OVL/usr/share/deckard/RUNSTEAM.sh" "$STEAM_HOME/RUNSTEAM.sh" 0755
if [[ -d "$STEAM_HOME/linuxarm64" && -d "$STEAM_HOME/steamrtarm64" ]]; then
  for _lib in steamclient.so crashhandler.so steam-launch-wrapper; do
    if [[ -s "$STEAM_HOME/steamrtarm64/${_lib}" && ! -s "$STEAM_HOME/linuxarm64/${_lib}" ]]; then
      cp -f "$STEAM_HOME/steamrtarm64/${_lib}" "$STEAM_HOME/linuxarm64/${_lib}"
    fi
  done
  unset _lib
fi

# Desktop theme
if [[ -f "$R/etc/xdg/kdeglobals" ]]; then
  sed -i 's/^LookAndFeelPackage=.*/LookAndFeelPackage=com.valve.vapor.deck.desktop/' "$R/etc/xdg/kdeglobals"
fi

# The whole home belongs to the user, as in apply-overlays.sh: ~/.cache and
# ~/.config are made above as root when the base has none, and the hub and
# Steam steps also write here as root. A root-owned ~/.config breaks Decky
# plugins, lsfg-vk's conf.toml and KDE settings.
chown -hR 1000:1000 "$HOME_DST"
chmod 0755 "$HOME_DST"

# Ensure correct root and user permissions across /usr and /etc
find "$R/usr" "$R/etc" -xdev \( -uid +999 -o -gid +999 \) -exec chown -h root:root {} + 2>/dev/null || true

# Source permissions, same as apply-overlays.sh: a copy that went through
# the exFAT HDD has 0700 dirs and 0700/0600 files. gamescope runs as steamos
# and aborts on any display script it can't read; three came in as 0700
# (legiongo2, onexplayer f1, zotac zone) and kept Game Mode black on the Odin 3.
for d in usr/share usr/local/share usr/lib/steamos usr/lib/systemd/user usr/lib/environment.d \
         etc/gamescope etc/inputplumber etc/sdl2; do
  [[ -d "$R/$d" ]] || continue
  find "$R/$d" -xdev \( -path '*/guestos' -o -path '*/factory/root' \) -prune -o \
    -type d \( ! -perm -o=rx -o ! -perm -u=x \) -exec chmod u+rwx,go+rx {} + -o \
    -type f ! -perm -o=r -exec chmod go+r {} +
done
bad="$(find "$R/usr/share/gamescope" "$R/etc/gamescope" -xdev -type f ! -perm -o=r 2>/dev/null | head -3)"
[[ -z "$bad" ]] || die "gamescope scripts not readable: $bad"

# macOS AppleDouble files (._name) from copying the tree through a Mac.
# gamescope runs every .lua in its script folders, and ._inspect.lua made it
# abort on start, over and over: the Odin 3 test 1/2 black screen.
find "$R" -xdev -name '._*' -type f -delete 2>/dev/null || true
[[ -z "$(find "$R" -xdev -name '._*' -type f -print -quit 2>/dev/null)" ]] || die "._ files left in $R"

# Last: what this image installed, and which release it is (see apply-overlays.sh).
python3 "$ROOT/external-and-mods/konkr-update/konkr-update.py" record-inventory --root "$R" \
  --version "${STEAMOS_ARM_VERSION:-1.3.0}" --soc sm8750 | tee -a "$LOG"

log "== SM8750 overlays successfully applied"
