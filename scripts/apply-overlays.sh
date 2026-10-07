#!/usr/bin/env bash
# Apply the handheld overlay onto the extracted SteamOS Frame rootfs.
# SM8650 port (KONKR Pocket FIT / AYANEO Pocket S2): the Frame is SM8650 /
# Adreno 750 itself, so Valve's Turnip + GPU firmware are kept as shipped.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR="${STEAMOS_WORK:-/work}"
R="${STEAMOS_ROOTFS:-${WORKDIR}/rootfs}"
MOD="${ROOT}/external-and-mods"
OVL="${ROOT}/steamos-overlay"
# KERNEL_OUT: one kernel output dir, or several separated by spaces (one per
# SoC). All their modules + firmware go into the rootfs, so one rootfs serves
# every SoC; the first one's KERNEL lands in /boot (the image builder puts the
# right KERNEL on each image's boot partition).
read -ra KOUTS <<<"${KERNEL_OUT:-${WORKDIR}/kernel-release/current}"
for i in "${!KOUTS[@]}"; do KOUTS[$i]="$(readlink -f "${KOUTS[$i]}")"; done
KOUT="${KOUTS[0]}"
KREL="$(basename "$KOUT")"
SM8650_OVL="${ROOT}/sm8650-overlay"
SM8550_OVL="${ROOT}/sm8550-overlay"
STOCK="${R}/opt/stock-steamos"
GSBUILD="${GAMESCOPE_BUILD:-${WORKDIR}/gamescope-build}"
# Optional Turnip override. Empty = keep the Frame's own (built for A750).
MESA_SO="${MESA_SO:-}"
LOG="${WORKDIR}/odin-apply.log"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*" | tee -a "$LOG"; }

[[ -d "$R/usr/bin" ]] || die "missing rootfs at $R"
for k in "${KOUTS[@]}"; do
  [[ -f "$k/boot/KERNEL" ]] || die "missing kernel $k"
  [[ -d "$k/modules/$(basename "$k")" ]] || die "missing modules $k/modules/$(basename "$k")"
done
[[ -x "$GSBUILD/src/gamescope" ]] || die "missing built gamescope"
[[ -z "$MESA_SO" || -f "$MESA_SO" ]] || die "missing Mesa $MESA_SO"

: >"$LOG"
log "== $(date -Iseconds) apply Odin mods into $R"

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
# Kernel
# ---------------------------------------------------------------------------
log "== kernel ${KOUTS[*]##*/}"
mkdir -p "$R/boot" "$R/usr/lib/modules" "$R/usr/lib/firmware" "$R/opt/steamos-sm8650"
if [[ -e "$R/boot/KERNEL" && ! -e "$STOCK/boot/KERNEL" ]]; then
  mkdir -p "$STOCK/boot"
  cp -a "$R/boot/KERNEL" "$STOCK/boot/KERNEL" 2>/dev/null || true
fi
cp -a "$KOUT/boot/KERNEL" "$R/boot/KERNEL"
cp -a "$KOUT/boot/KERNEL.md5" "$R/boot/KERNEL.md5"
chmod 0644 "$R/boot/KERNEL" "$R/boot/KERNEL.md5"

# Frame kernel modules are useless with these kernels; keep only ours.
keep=()
for k in "${KOUTS[@]}"; do keep+=(! -name "$(basename "$k")"); done
find "$R/usr/lib/modules" -mindepth 1 -maxdepth 1 "${keep[@]}" -exec rm -rf {} +
# Kernel info from older builds (flat layout, or kernels no longer shipped).
find "$R/opt/steamos-sm8650" -mindepth 1 -maxdepth 1 ! -name IMAGE.txt "${keep[@]}" -exec rm -rf {} +
for k in "${KOUTS[@]}"; do
  kr="$(basename "$k")"
  rm -rf "$R/usr/lib/modules/$kr"
  cp -a "$k/modules/$kr" "$R/usr/lib/modules/$kr"
  mkdir -p "$R/opt/steamos-sm8650/$kr"
  cp -a "$k/config-$kr" "$k/dtbs" "$R/opt/steamos-sm8650/$kr/" 2>/dev/null || true
done
# Merge firmware without wiping Frame blobs (Frame ships SM8650 GPU fw too;
# vendor-signed ADSP/CDSP/zap live under qcom/<soc>/<vendor>/...). Last kernel
# in KERNEL_OUT first, so the image's own kernel (the first) wins where they
# differ. Wi-Fi (WCN7850) never overwrites: the SoC sets only differ in
# regdb.bin, and the Pocket FIT has always run with the Frame's copy.
for ((i = ${#KOUTS[@]} - 1; i >= 0; i--)); do
  k="${KOUTS[$i]}"
  rsync -a --exclude=/ath12k/ "$k/firmware/" "$R/usr/lib/firmware/"
  if [[ -d "$k/firmware/ath12k" ]]; then
    rsync -a --ignore-existing "$k/firmware/ath12k/" "$R/usr/lib/firmware/ath12k/"
  fi
done
# Lenovo Legion Y700 Gen 3: its firmware and audio profile, when its kernel is
# one of this rootfs's (kernel-tb321fu).
for k in "${KOUTS[@]}"; do
  if [[ "$(basename "$k")" == *-tb321fu-steamos ]]; then
    "${SCRIPT_DIR}/install-tb321fu.sh" "$R" || die "TB321FU firmware/audio install failed"
  fi
done
# Frame supplies the exact upstream VPU33 firmware (SM8650) under its vendor
# name. Iris requests the upstream alias. Verify before creating that alias.
_vpu="$R/usr/lib/firmware/qcom/vpu/vpu33_4v.mbn"
if [[ -f "$_vpu" ]]; then
  [[ $(sha256sum "$_vpu" | awk '{print $1}') == 7b829fc1c8ce7cca836d10e898b99c5bcbd86e22073b690147168c9d0a5de378 ]] \
    || die "unexpected SM8650 decoder firmware; reverify against upstream"
  ln -sfn vpu33_4v.mbn "$R/usr/lib/firmware/qcom/vpu/vpu33_p4.mbn"
else
  die "missing SM8650 video decoder firmware"
fi

# ---------------------------------------------------------------------------
# gamescope
# ---------------------------------------------------------------------------
log "== gamescope (MSM + backlight)"
for b in gamescope gamescopectl gamescopereaper gamescopestream; do
  backup "$R/usr/bin/$b" "$STOCK/usr/bin/$b"
  install_file "$GSBUILD/src/$b" "$R/usr/bin/$b" 0755
  mkdir -p "$R/usr/local/bin"
  install_file "$GSBUILD/src/$b" "$R/usr/local/bin/$b" 0755
done
# CAP_SYS_NICE, as SteamOS ships it: without it gamescope never gets its
# realtime Vulkan queue, so its compositing waited behind the game on the GPU
# and missed vblanks (Pocket FIT at 120 Hz: ~5 a second with the performance
# overlay up, draw spikes of 8-13 ms in an 8.3 ms slot; with it ~1, 6.6 ms).
# A plain copy drops file capabilities, so set them after every install.
for gs in "$R/usr/bin/gamescope" "$R/usr/local/bin/gamescope"; do
  setcap cap_sys_nice=eip "$gs" || die "setcap on $gs failed"
done
if [[ -f "$GSBUILD/layer/libVkLayer_FROG_gamescope_wsi_aarch64.so" ]]; then
  backup "$R/usr/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so" \
    "$STOCK/usr/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so"
  install_file "$GSBUILD/layer/libVkLayer_FROG_gamescope_wsi_aarch64.so" \
    "$R/usr/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so" 0755
  mkdir -p "$R/usr/local/lib"
  install_file "$GSBUILD/layer/libVkLayer_FROG_gamescope_wsi_aarch64.so" \
    "$R/usr/local/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so" 0755
fi
if [[ -d "${MOD}/gamescope/scripts" ]]; then
  mkdir -p "$R/usr/share/gamescope" "$R/usr/local/share/gamescope"
  rm -rf "$R/usr/share/gamescope/scripts" "$R/usr/local/share/gamescope/scripts"
  cp -a "${MOD}/gamescope/scripts" "$R/usr/share/gamescope/scripts"
  cp -a "${MOD}/gamescope/scripts" "$R/usr/local/share/gamescope/scripts"
  if [[ -d "${MOD}/gamescope/looks" ]]; then
    rm -rf "$R/usr/share/gamescope/looks" "$R/usr/local/share/gamescope/looks"
    cp -a "${MOD}/gamescope/looks" "$R/usr/share/gamescope/looks"
    cp -a "${MOD}/gamescope/looks" "$R/usr/local/share/gamescope/looks"
  fi
fi
install_file "${MOD}/gamescope/scripts/udev/60-gamescope-backlight.rules" \
  "$R/usr/lib/udev/rules.d/60-gamescope-backlight.rules" 0644
# Also land in /lib if SteamOS uses it
mkdir -p "$R/lib/udev/rules.d"
install_file "${MOD}/gamescope/scripts/udev/60-gamescope-backlight.rules" \
  "$R/lib/udev/rules.d/60-gamescope-backlight.rules" 0644

backup "$R/usr/lib/steamos/gamescope-session" "$STOCK/usr/lib/steamos/gamescope-session"
install_file "$OVL/usr/lib/steamos/gamescope-session" \
  "$R/usr/lib/steamos/gamescope-session" 0755
install_file "$OVL/usr/lib/steamos/panel-modes" \
  "$R/usr/lib/steamos/panel-modes" 0755
install_file "$OVL/usr/lib/steamos/desktop-outputs" \
  "$R/usr/lib/steamos/desktop-outputs" 0755
# The fixed layout older images put in ~/.config; desktop-outputs replaces it.
install_file "$OVL/etc/xdg/kwinoutputconfig.json" \
  "$R/usr/share/steamos-arm/kwinoutputconfig.legacy.json" 0644
backup "$R/usr/lib/steamos/gamescope-onready" "$STOCK/usr/lib/steamos/gamescope-onready"
install_file "$OVL/usr/lib/steamos/gamescope-onready" \
  "$R/usr/lib/steamos/gamescope-onready" 0755
install_file "$OVL/usr/lib/steamos/sm8550-steam-focus" \
  "$R/usr/lib/steamos/sm8550-steam-focus" 0755
install_file "$OVL/usr/lib/steamos/odin-bin/steamvr" \
  "$R/usr/lib/steamos/odin-bin/steamvr" 0755
backup "$R/usr/bin/steamos-select-branch" "$STOCK/usr/bin/steamos-select-branch"
install_file "$OVL/usr/bin/steamos-select-branch" \
  "$R/usr/bin/steamos-select-branch" 0755
# Official Plasma is already in the image. Switch-to-desktop must clear
# Game Mode QT_QPA_PLATFORM=xcb or plasmashell dies and the screen stays black.
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
for tgt in plasma-core.target plasma-workspace.target plasma-workspace-wayland.target; do
  mkdir -p "$R/usr/lib/systemd/user/${tgt}.d"
  install_file "$OVL/usr/lib/systemd/user/${tgt}.d/99-odin.conf" \
    "$R/usr/lib/systemd/user/${tgt}.d/99-odin.conf" 0644
done
WAYLAND_DROPIN="$OVL/usr/lib/systemd/user/plasma-plasmashell.service.d/99-odin-wayland.conf"
for svc in plasma-plasmashell plasma-ksplash plasma-ksmserver \
  plasma-kcminit plasma-kcminit-phase1 plasma-kded6 plasma-kwin_wayland \
  plasma-gmenudbusmenuproxy plasma-xembedsniproxy plasma-kaccess \
  plasma-powerdevil plasma-polkit-agent plasma-kglobalaccel plasma-kscreen \
  plasma-xdg-desktop-portal-kde plasma-krunner plasma-kactivitymanagerd \
  plasma-dolphin plasma-ksystemstats plasma-restoresession plasma-baloorunner
do
  mkdir -p "$R/usr/lib/systemd/user/${svc}.service.d"
  install_file "$WAYLAND_DROPIN" \
    "$R/usr/lib/systemd/user/${svc}.service.d/99-odin-wayland.conf" 0644
done
rm -f "$R/usr/lib/steamos/sm8550-desktop-session"
install_file "$OVL/usr/bin/jupiter-initial-firmware-update" \
  "$R/usr/bin/jupiter-initial-firmware-update" 0755
install_file "$OVL/usr/bin/steamos-mandatory-update" \
  "$R/usr/bin/steamos-mandatory-update" 0755
# Steam Software Updates toast: official steamos-update → pkexec/atomupd → 127.
backup "$R/usr/bin/steamos-update" "$STOCK/usr/bin/steamos-update"
install_file "$OVL/usr/bin/steamos-update" \
  "$R/usr/bin/steamos-update" 0755
install_file "$OVL/usr/bin/steamos-polkit-helpers/steamos-update" \
  "$R/usr/bin/steamos-polkit-helpers/steamos-update" 0755
install_file "$OVL/usr/lib/steamos/sm8550-oobe-restart-steam" \
  "$R/usr/lib/steamos/sm8550-oobe-restart-steam" 0755
install_file "$OVL/usr/lib/systemd/system/sm8550-oobe-restart-steam.service" \
  "$R/usr/lib/systemd/system/sm8550-oobe-restart-steam.service" 0644
mkdir -p "$R/usr/lib/systemd/user/steam.service.d"
install_file "$OVL/usr/lib/systemd/user/steam.service.d/99-sm8550-bootstrap.conf" \
  "$R/usr/lib/systemd/user/steam.service.d/99-sm8550-bootstrap.conf" 0644
# Session vars (refresh slider, mangoapp) via a file: onready's import races Steam.
install_file "$OVL/usr/lib/systemd/user/steam.service.d/60-gamescope-env.conf" \
  "$R/usr/lib/systemd/user/steam.service.d/60-gamescope-env.conf" 0644
backup "$R/usr/bin/start-gamescope-session" "$STOCK/usr/bin/start-gamescope-session"
install_file "$OVL/usr/bin/start-gamescope-session" \
  "$R/usr/bin/start-gamescope-session" 0755
backup "$R/usr/share/deckard/RUNSTEAM.sh" "$STOCK/usr/share/deckard/RUNSTEAM.sh"
install_file "$OVL/usr/share/deckard/RUNSTEAM.sh" \
  "$R/usr/share/deckard/RUNSTEAM.sh" 0755
install_file "$OVL/usr/share/deckard/steam-health-check" \
  "$R/usr/share/deckard/steam-health-check" 0755
# Odin 2 has no dock. Missing /usr/bin/jupiter-dock-updater is exit 127
# and Steam shows "Error de actualización". --check must exit 7 (up to date).
log "== dock stub"
mkdir -p "$R/usr/bin/steamos-polkit-helpers"
install_file "$OVL/usr/bin/jupiter-dock-updater" \
  "$R/usr/bin/jupiter-dock-updater" 0755
install_file "$OVL/usr/bin/steamos-polkit-helpers/jupiter-dock-updater" \
  "$R/usr/bin/steamos-polkit-helpers/jupiter-dock-updater" 0755
# steam.service copies this into the user home on each start.
if [[ -d "$R/home/steamos/.local/share/Steam" ]]; then
  install_file "$OVL/usr/share/deckard/RUNSTEAM.sh" \
    "$R/home/steamos/.local/share/Steam/RUNSTEAM.sh" 0755
fi

mkdir -p "$R/usr/lib/systemd/user/gamescope-session.service.d"
mkdir -p "$R/usr/lib/systemd/user/gamescope-session.target.d"
mkdir -p "$R/usr/lib/systemd/user/steam.service.d"
install_file "$OVL/usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf" \
  "$R/usr/lib/systemd/user/gamescope-session.service.d/99-odin.conf" 0644
install_file "$OVL/usr/lib/systemd/user/gamescope-session.target.d/99-odin.conf" \
  "$R/usr/lib/systemd/user/gamescope-session.target.d/99-odin.conf" 0644
install_file "$OVL/usr/lib/systemd/user/steam.service.d/99-odin.conf" \
  "$R/usr/lib/systemd/user/steam.service.d/99-odin.conf" 0644
# Frame leftover: SteamVR must not start on a handheld (Wants= is additive).
mkdir -p "$R/etc/systemd/user" "$R/etc/systemd/system"
for u in steamvr.service steamvr-logs.service steamvr-proxmicmute.service \
         steamvr-v4l2cam.service steamvr-nested-desktop.service; do
  ln -sfn /dev/null "$R/etc/systemd/user/${u}"
done
for u in steamvr-program-ble.service steamvr-v4l2loopback.service \
         steamvr-set-kernel-thread-priorities.service \
         deckard-audio-setup.service \
         deckard-fan-control.service deckard-fpga.service \
         deckard-led-control.service deckard-typec-logger.service \
         set-wifi-mac-address.service iwd.service deckard-charger.service \
         deckard-power-monitor.service deckard-fpga-resume.service \
         deckard-boot-images.service \
         adbd.service adbd-post.service usb-gadget.service usb-gadget.target \
         usb-ncm-gadget@.service usb-ncm-dnsmasq@.service \
         steamos-boot.service efi.mount esp.mount systemd-repart.service; do
  # Frame USB-gadget/ADB/power-monitor: no such hardware here. They crash-loop
  # (1000+ restarts/night) and adbd-post polls ffs.adb/ready at 10 Hz forever,
  # which keeps the SoC out of deep idle and burned battery in standby.
  # steamos-boot (A/B slot bookkeeping) needs efi.mount, which waits for the
  # Deck's EFI partition (by-partsets/self/efi). There's none here, so every
  # boot sat on it for the full 90 s device timeout.
  # systemd-repart (Valve's repart.d/90-home.conf) adds a home partition to
  # the root disk's free space at boot. Our layouts already have /home and
  # steamos-sm8550-expand-home grows it; on internal UFS repart must never
  # touch the partition table.
  ln -sfn /dev/null "$R/etc/systemd/system/${u}"
done

# ---------------------------------------------------------------------------
# Audio UCM + Wi-Fi (wpa, not iwd) + BT power + gamescope Wayland session
# ---------------------------------------------------------------------------
log "== alsa UCM AYN-Odin2 + wifi/wpa + bluetooth + wayland session"
if [[ -d "$OVL/usr/share/alsa/ucm2" ]]; then
  mkdir -p "$R/usr/share/alsa/ucm2"
  cp -r --no-preserve=mode,ownership "$OVL/usr/share/alsa/ucm2/." "$R/usr/share/alsa/ucm2/"
  # root alsaucm cannot read 600 steam:steam UCM (speakers stay silent).
  chown -R root:root "$R/usr/share/alsa/ucm2/AYN" \
    "$R/usr/share/alsa/ucm2/codecs" "$R/usr/share/alsa/ucm2/lib" \
    "$R/usr/share/alsa/ucm2/conf.d/sm8550" 2>/dev/null || true
  find "$R/usr/share/alsa/ucm2/AYN" "$R/usr/share/alsa/ucm2/codecs" \
    "$R/usr/share/alsa/ucm2/lib" "$R/usr/share/alsa/ucm2/conf.d/sm8550" \
    -type d -exec chmod 0755 {} + 2>/dev/null || true
  find "$R/usr/share/alsa/ucm2/AYN" "$R/usr/share/alsa/ucm2/codecs" \
    "$R/usr/share/alsa/ucm2/lib" "$R/usr/share/alsa/ucm2/conf.d/sm8550" \
    -type f -exec chmod 0644 {} + 2>/dev/null || true
fi
# Frame steamclient reads VARIANT_ID=vr and Gamepad UI then throws.
for _osr in "$R/etc/os-release" "$R/usr/lib/os-release" \
  "$R/var/lib/overlays/etc/upper/os-release"; do
  [[ -f "$_osr" ]] || continue
  sed -i 's/^VARIANT_ID=.*/VARIANT_ID="steamdeck"/' "$_osr" || true
  grep -q '^VARIANT_ID=' "$_osr" || echo 'VARIANT_ID="steamdeck"' >> "$_osr"
done
unset _osr
# Dangling Frame VR audio plugins break Chromium/Steam streams.
for _so in \
  "$R/usr/lib/ladspa/vraudiocompositor.so" \
  "$R/usr/lib/ladspa/audiofilter.so" \
  "$R/usr/lib/ladspa/libphonon.so"
do
  if [[ -L "$_so" && ! -e "$_so" ]]; then
    rm -f "$_so"
  fi
done
unset _so
install_file "$OVL/usr/lib/NetworkManager/conf.d/40-sm8550-wifi.conf" \
  "$R/usr/lib/NetworkManager/conf.d/40-sm8550-wifi.conf" 0644
install_file "$OVL/usr/lib/modprobe.d/ath12k.conf" \
  "$R/usr/lib/modprobe.d/ath12k.conf" 0644
install_file "$OVL/usr/lib/systemd/network/99-sm8550-wlan0.link" \
  "$R/usr/lib/systemd/network/99-sm8550-wlan0.link" 0644
install_file "$OVL/usr/lib/steamos/sm8550-wifi-backend" \
  "$R/usr/lib/steamos/sm8550-wifi-backend" 0755
install_file "$OVL/usr/lib/systemd/system/sm8550-wifi-backend.service" \
  "$R/usr/lib/systemd/system/sm8550-wifi-backend.service" 0644
install_file "$OVL/usr/lib/systemd/system/sm8550-wifi-backend.path" \
  "$R/usr/lib/systemd/system/sm8550-wifi-backend.path" 0644
mkdir -p "$R/usr/lib/systemd/system/NetworkManager.service.d"
install_file "$OVL/usr/lib/systemd/system/NetworkManager.service.d/99-sm8550-wpa.conf" \
  "$R/usr/lib/systemd/system/NetworkManager.service.d/99-sm8550-wpa.conf" 0644
install_file "$OVL/usr/lib/steamos/sm8550-audio-setup" \
  "$R/usr/lib/steamos/sm8550-audio-setup" 0755
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
# Store plugins that break on the Steam client we ship, fixed where Decky
# installs them (SteamGridDB 1.7.1's footer glyph lookup for now).
install_file "$OVL/usr/lib/steamos-arm/decky-plugin-fixes" "$R/usr/lib/steamos-arm/decky-plugin-fixes" 0755
for u in steamos-arm-decky-plugin-fixes.service steamos-arm-decky-plugin-fixes.path; do
  install_file "$OVL/usr/lib/systemd/system/$u" "$R/usr/lib/systemd/system/$u" 0644
  ln -sfn "../$u" "$R/usr/lib/systemd/system/multi-user.target.wants/$u"
done
install_file "$OVL/usr/lib/udev/rules.d/70-steamos-arm-devcoredump.rules" \
  "$R/usr/lib/udev/rules.d/70-steamos-arm-devcoredump.rules" 0644
install_file "$OVL/usr/lib/steamos/sm8550-audio-pipewire" \
  "$R/usr/lib/steamos/sm8550-audio-pipewire" 0755
install_file "$OVL/usr/lib/steamos/sm8550-volume-keys" \
  "$R/usr/lib/steamos/sm8550-volume-keys" 0755
install_file "$OVL/usr/lib/systemd/system/sm8550-audio-setup.service" \
  "$R/usr/lib/systemd/system/sm8550-audio-setup.service" 0644
install_file "$OVL/usr/lib/systemd/user/sm8550-audio-pipewire.service" \
  "$R/usr/lib/systemd/user/sm8550-audio-pipewire.service" 0644
install_file "$OVL/usr/lib/systemd/user/sm8550-volume-keys.service" \
  "$R/usr/lib/systemd/user/sm8550-volume-keys.service" 0644
install_file "$OVL/usr/share/wireplumber/wireplumber.conf.d/51-sm8550-hifi-priority.conf" \
  "$R/usr/share/wireplumber/wireplumber.conf.d/51-sm8550-hifi-priority.conf" 0644
install_file "$OVL/usr/share/wireplumber/wireplumber.conf.d/52-sm8550-alsa.conf" \
  "$R/usr/share/wireplumber/wireplumber.conf.d/52-sm8550-alsa.conf" 0644
install_file "$OVL/usr/share/wireplumber/wireplumber.conf.d/56-first-boot-volume.conf" \
  "$R/usr/share/wireplumber/wireplumber.conf.d/56-first-boot-volume.conf" 0644
install_file "$OVL/etc/wireplumber/wireplumber.conf.d/52-sm8550-alsa.conf" \
  "$R/etc/wireplumber/wireplumber.conf.d/52-sm8550-alsa.conf" 0644
install_file "$OVL/usr/share/pipewire/pipewire.conf.d/99-sm8550-buffers.conf" \
  "$R/usr/share/pipewire/pipewire.conf.d/99-sm8550-buffers.conf" 0644
install_file "$OVL/usr/share/pipewire/pipewire-pulse.conf.d/99-sm8550-buffers.conf" \
  "$R/usr/share/pipewire/pipewire-pulse.conf.d/99-sm8550-buffers.conf" 0644
install_file "$OVL/usr/share/pipewire/pipewire-pulse.conf.d/60-games-keep-device-volume.conf" \
  "$R/usr/share/pipewire/pipewire-pulse.conf.d/60-games-keep-device-volume.conf" 0644
install_file "$OVL/usr/lib/udev/rules.d/90-sm8550-audio.rules" \
  "$R/usr/lib/udev/rules.d/90-sm8550-audio.rules" 0644
install_file "$OVL/etc/wireplumber/wireplumber.conf.d/99-sm8550-no-vr-spatial.conf" \
  "$R/etc/wireplumber/wireplumber.conf.d/99-sm8550-no-vr-spatial.conf" 0644
if [[ -f "$R/etc/wireplumber/wireplumber.conf.d/50-alsa-config.conf" ]]; then
  sed -i 's/api.acp.disable-pro-audio = true/api.acp.disable-pro-audio = false/' \
    "$R/etc/wireplumber/wireplumber.conf.d/50-alsa-config.conf" || true
  sed -i 's/node.force-quantum    = 480/node.force-quantum    = 512/' \
    "$R/etc/wireplumber/wireplumber.conf.d/50-alsa-config.conf" || true
  sed -i 's/api.alsa.period-size  = 256/api.alsa.period-size  = 1024/' \
    "$R/etc/wireplumber/wireplumber.conf.d/50-alsa-config.conf" || true
fi
# Frame spatializer is required= and its .so is a /run dangling symlink.
for _sp in 60-spatial-audio.conf 70-spatial-node-config.conf; do
  if [[ -f "$R/etc/wireplumber/wireplumber.conf.d/${_sp}" ]]; then
    mv -f "$R/etc/wireplumber/wireplumber.conf.d/${_sp}" \
      "$R/etc/wireplumber/wireplumber.conf.d/${_sp}.disabled" || true
  fi
done
unset _sp
install_file "$OVL/usr/lib/steamos/sm8550-patch-steamui" \
  "$R/usr/lib/steamos/sm8550-patch-steamui" 0755
install_file "$OVL/usr/lib/steamos/sm8550-bluetooth-setup" \
  "$R/usr/lib/steamos/sm8550-bluetooth-setup" 0755
install_file "$OVL/usr/lib/systemd/system/sm8550-bluetooth-setup.service" \
  "$R/usr/lib/systemd/system/sm8550-bluetooth-setup.service" 0644
# Steam writes this fragment to force iwd; pin wpa in /etc and the overlay upper.
for dest in \
  "$R/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf" \
  "$R/var/lib/overlays/etc/upper/NetworkManager/conf.d/99-valve-wifi-backend.conf"
do
  install_file "$OVL/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf" "$dest" 0644
done
mkdir -p "$R/etc/systemd/system/multi-user.target.wants" \
  "$R/etc/systemd/system/NetworkManager.service.wants" \
  "$R/etc/systemd/system/bluetooth.target.wants" \
  "$R/etc/systemd/system/sound.target.wants" \
  "$R/etc/systemd/user/default.target.wants"
ln -sfn /usr/lib/systemd/system/sm8550-wifi-backend.service \
  "$R/etc/systemd/system/multi-user.target.wants/sm8550-wifi-backend.service"
ln -sfn /usr/lib/systemd/system/sm8550-wifi-backend.service \
  "$R/etc/systemd/system/NetworkManager.service.wants/sm8550-wifi-backend.service"
ln -sfn /usr/lib/systemd/system/sm8550-wifi-backend.path \
  "$R/etc/systemd/system/multi-user.target.wants/sm8550-wifi-backend.path"
# Audio setup runs when the card appears (udev + sound.target), never from
# multi-user.target, which it used to hold back. Drop links older builds made.
rm -f "$R/etc/systemd/system/multi-user.target.wants/sm8550-audio-setup.service" \
  "$R/usr/lib/systemd/system/multi-user.target.wants/sm8550-audio-setup.service" \
  "$R/var/lib/overlays/etc/upper/systemd/system/multi-user.target.wants/sm8550-audio-setup.service"
mkdir -p "$R/usr/lib/systemd/system/sound.target.wants"
ln -sfn ../sm8550-audio-setup.service \
  "$R/usr/lib/systemd/system/sound.target.wants/sm8550-audio-setup.service"
ln -sfn /usr/lib/systemd/system/sm8550-audio-setup.service \
  "$R/etc/systemd/system/sound.target.wants/sm8550-audio-setup.service"
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
mkdir -p "$R/usr/lib/systemd/user/default.target.wants"
ln -sfn /usr/lib/systemd/user/sm8550-audio-pipewire.service \
  "$R/usr/lib/systemd/user/default.target.wants/sm8550-audio-pipewire.service"
ln -sfn /usr/lib/systemd/user/sm8550-volume-keys.service \
  "$R/usr/lib/systemd/user/default.target.wants/sm8550-volume-keys.service"
ln -sfn /usr/lib/systemd/user/sm8550-volume-keys.service \
  "$R/etc/systemd/user/default.target.wants/sm8550-volume-keys.service"
ln -sfn /usr/lib/systemd/system/sm8550-bluetooth-setup.service \
  "$R/etc/systemd/system/multi-user.target.wants/sm8550-bluetooth-setup.service"
ln -sfn /usr/lib/systemd/system/sm8550-bluetooth-setup.service \
  "$R/etc/systemd/system/bluetooth.target.wants/sm8550-bluetooth-setup.service"
install_file "$OVL/etc/systemd/journald.conf.d/99-sm8550-persist.conf" \
  "$R/etc/systemd/journald.conf.d/99-sm8550-persist.conf" 0644
# Leave the initramfs/fsck console text (modprobe + "root: clean").
# Do not unbind fbcon: on MSM the last console frame looks hung.
rm -f "$R/usr/lib/steamos/sm8550-hide-console" \
  "$R/usr/lib/systemd/system/sm8550-hide-console.service" \
  "$R/lib/systemd/system/sm8550-hide-console.service" \
  "$R/etc/systemd/system/graphical.target.wants/sm8550-hide-console.service" \
  "$R/etc/systemd/system/sysinit.target.wants/sm8550-hide-console.service" \
  "$R/etc/systemd/system/multi-user.target.wants/sm8550-hide-console.service" \
  "$R/usr/lib/systemd/system/graphical.target.wants/sm8550-hide-console.service" \
  "$R/usr/lib/systemd/system/sysinit.target.wants/sm8550-hide-console.service" \
  "$R/usr/lib/systemd/system/multi-user.target.wants/sm8550-hide-console.service"
# Debug dumps must not paint the panel.
rm -f "$R/etc/systemd/system/multi-user.target.wants/sm8550-boot-debug.service" \
      "$R/etc/systemd/system/graphical.target.wants/sm8550-boot-debug-late.service"
ln -sfn /usr/lib/systemd/user/sm8550-audio-pipewire.service \
  "$R/etc/systemd/user/default.target.wants/sm8550-audio-pipewire.service"
# Host enables these explicitly; socket-only leaves gamescope without a sink.
mkdir -p "$R/etc/systemd/user/default.target.wants" \
  "$R/etc/xdg/systemd/user/default.target.wants"
for u in pipewire.service pipewire-pulse.service; do
  if [[ -f "$R/usr/lib/systemd/user/${u}" ]]; then
    ln -sfn "/usr/lib/systemd/user/${u}" \
      "$R/etc/systemd/user/default.target.wants/${u}"
    ln -sfn "/usr/lib/systemd/user/${u}" \
      "$R/etc/xdg/systemd/user/default.target.wants/${u}"
  fi
done
if [[ -f "$R/usr/lib/systemd/system/wpa_supplicant.service" ]]; then
  ln -sfn /usr/lib/systemd/system/wpa_supplicant.service \
    "$R/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service"
  ln -sfn /usr/lib/systemd/system/wpa_supplicant.service \
    "$R/etc/systemd/system/NetworkManager.service.wants/wpa_supplicant.service"
fi
rm -f "$R/etc/systemd/system/multi-user.target.wants/iwd.service"
# Official Wayland Plasma, started via sm8550-startplasma (clears Game Mode xcb).
install_file "$OVL/usr/share/wayland-sessions/plasma.desktop" \
  "$R/usr/share/wayland-sessions/plasma.desktop" 0644
rm -f "$R/usr/lib/steamos/sm8550-desktop-session"
if [[ -d "$R/usr/share/steamos-manager/devices" ]]; then
  install_file "$OVL/usr/share/steamos-manager/devices/ayn-odin2.toml" \
    "$R/usr/share/steamos-manager/devices/ayn-odin2.toml" 0644
  install_file "$SM8650_OVL/usr/share/steamos-manager/devices/konkr-pocketfit.toml" \
    "$R/usr/share/steamos-manager/devices/konkr-pocketfit.toml" 0644
fi
# Steam "Switch to Desktop" listed only plasmax11. Hide Frame X11 sessions.
mkdir -p "$R/usr/share/steamos/hidden-xsessions"
for s in plasmax11.desktop openbox.desktop openbox-kde.desktop; do
  if [[ -f "$R/usr/share/xsessions/$s" ]]; then
    mv -f "$R/usr/share/xsessions/$s" "$R/usr/share/steamos/hidden-xsessions/$s"
  fi
done

# ---------------------------------------------------------------------------
# Native rsinput ±740, then InputPlumber deck-uhid + keyboard (OSK haptic).
# USB/Bluetooth HID is ignored in the composite so it is not grabbed.
# ---------------------------------------------------------------------------
log "== gamepad (rsinput ±740 + InputPlumber deck-uhid)"
install_file "$OVL/usr/lib/steamos/sm8550-fixpad" \
  "$R/usr/lib/steamos/sm8550-fixpad" 0755
install_file "$OVL/usr/lib/systemd/system/sm8550-fixpad.service" \
  "$R/usr/lib/systemd/system/sm8550-fixpad.service" 0644
mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/sm8550-fixpad.service \
  "$R/etc/systemd/system/multi-user.target.wants/sm8550-fixpad.service"
install_file "$OVL/usr/lib/udev/rules.d/70-sm8550-gamepad.rules" \
  "$R/usr/lib/udev/rules.d/70-sm8550-gamepad.rules" 0644
mkdir -p "$R/lib/udev/rules.d"
install_file "$OVL/usr/lib/udev/rules.d/70-sm8550-gamepad.rules" \
  "$R/lib/udev/rules.d/70-sm8550-gamepad.rules" 0644
install_file "$OVL/etc/sdl2/qcom-gamecontrollerdb.txt" \
  "$R/etc/sdl2/qcom-gamecontrollerdb.txt" 0644
install_file "$OVL/usr/lib/environment.d/60-sm8550-gamepad.conf" \
  "$R/usr/lib/environment.d/60-sm8550-gamepad.conf" 0644
install_file "$OVL/usr/lib/environment.d/62-steamos-arm-no-wsi-dialogs.conf" \
  "$R/usr/lib/environment.d/62-steamos-arm-no-wsi-dialogs.conf" 0644
install_file "$OVL/etc/profile.d/sm8550-gamepad.sh" \
  "$R/etc/profile.d/sm8550-gamepad.sh" 0644
"${SCRIPT_DIR}/install-inputplumber-sm8550.sh" "$R"
"${SCRIPT_DIR}/install-qcom-gyro-sm8550.sh" "$R"

# ---------------------------------------------------------------------------
# SM8650 device overlay: Pocket FIT pad (XInput → deck-uhid), APS2 UCM,
# steamos-manager device, dual-SoC audio setup.
# ---------------------------------------------------------------------------
log "== SM8650 overlay (KONKR Pocket FIT / AYANEO Pocket S2)"
# Speaker limiter for wireplumber.conf.d/55-konkr-speaker.conf.
if [[ ! -f "$R/usr/lib/lv2/dpl.lv2/dpl.so" ]]; then
  "${SCRIPT_DIR}/build-dpl-lv2-in-rootfs.sh" "$R"
fi
cp -r --no-preserve=mode,ownership "$SM8650_OVL/." "$R/"
chmod 0755 "$R/usr/lib/konkr/pocket-s2-controller"
chmod 0644 "$R/usr/lib/liblsfg-vk-layer-arm64.so" "$R/usr/lib/liblsfg-vk-layer-arm64.so.README"
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
# Audio: the Frame (also SM8650) hides the raw speaker node from every client
# so its VR speaker filter chain owns it; that chain is disabled here, which
# left the speakers unreachable. Drop the speaker from Valve's access rules.
ACCESS="$R/etc/wireplumber/wireplumber.conf.d/10-access.conf"
if [[ -f "$ACCESS" ]]; then
  cp -n "$ACCESS" "$R/etc/wireplumber/10-access.conf.frame-orig"
  sed -i '/node.name = "alsa_output.platform-sound.HiFi__Speaker__sink"/d' "$ACCESS"
fi
# Same as ayn_mcu: InputPlumber loads capability maps from /usr/share too.
mkdir -p "$R/usr/share/inputplumber/capability_maps"
cp -f "$SM8650_OVL"/etc/inputplumber/capability_maps.d/*.yaml "$R/usr/share/inputplumber/capability_maps/"
# InputPlumber ships its own Pocket FIT / Pocket S2 profiles (matched on the
# DT compatible). Ours cover the same pads with the Deck target, back buttons
# and the MCU keys; two matching profiles would fight over the same sources.
rm -f "$R/usr/share/inputplumber/devices/50-konkr_pocket_fit.yaml" \
  "$R/usr/share/inputplumber/devices/50-ayaneo_pocket_s2.yaml"
chown -R root:root "$R/usr/share/alsa/ucm2/Qualcomm/sm8650" "$R/usr/share/alsa/ucm2/conf.d/sm8650" \
  "$R/etc/inputplumber" 2>/dev/null || true
chmod 0755 "$R/usr/lib/steamos/sm8550-audio-setup" "$R/usr/lib/konkr/konkrd" \
  "$R/usr/bin/konkrctl" "$R/usr/bin/konkr-game" "$R/usr/lib/konkr/konkr-standby" \
  "$R/usr/lib/konkr/konkr-volume" "$R/usr/lib/konkr/konkr-sleep" \
  "$R/usr/lib/konkr/konkr-suspend" "$R/usr/lib/konkr/konkr-focusfix" \
  "$R/usr/bin/konkr-apk" "$R/usr/lib/konkr/apk-info" "$R/usr/lib/konkr/konkr-pd-kick" \
  "$R/usr/lib/NetworkManager/dispatcher.d/60-konkr-timesync"
# The copy above drops modes: keep every script in /usr/lib/konkr runnable
# (konkr-pd-kick was missed once and its service could not start).
for f in "$R/usr/lib/konkr/"*; do
  [ -f "$f" ] && head -c2 "$f" | grep -q '^#!' && chmod 0755 "$f"
done
# Game mode: re-activate the game after Quick Access / Steam menu closes.
mkdir -p "$R/usr/lib/systemd/user/gamescope-session.target.wants"
ln -sfn ../konkr-focusfix.service \
  "$R/usr/lib/systemd/user/gamescope-session.target.wants/konkr-focusfix.service"
# Android apps (konkr-apk + Lepton): .apk/.apkm/.xapk/.apks open in it, and
# ~/Android/Inbox auto-installs. /etc links vanish under the /etc overlay.
mkdir -p "$R/usr/lib/systemd/user/default.target.wants"
ln -sfn ../konkr-apk-inbox.path \
  "$R/usr/lib/systemd/user/default.target.wants/konkr-apk-inbox.path"
# First login adds a Google Play Store title.
ln -sfn ../konkr-android-setup.service \
  "$R/usr/lib/systemd/user/default.target.wants/konkr-android-setup.service"
# Lepton rootfs overlays: Play Store, keyboard, pad layout, framework fixes
# (external-and-mods/konkr-android; binaries are fetched/built, not in git).
KAPAY="${ROOT}/external-and-mods/konkr-android/payload"
if [[ -f "$KAPAY/common/system/product/priv-app/Phonesky/Phonesky.apk" ]]; then
  rm -rf "$R/usr/share/konkr-android"
  mkdir -p "$R/usr/share/konkr-android"
  # exFAT/macOS leave ._* AppleDouble files; a ._x.apk breaks PackageManager.
  rsync -a --no-owner --no-group --exclude '._*' --exclude '.DS_Store' "$KAPAY/" "$R/usr/share/konkr-android/"
  chown -R root:root "$R/usr/share/konkr-android"
  find "$R/usr/share/konkr-android" -type d -exec chmod 0755 {} +
  find "$R/usr/share/konkr-android" -type f -exec chmod 0644 {} +
  # Valve's prebaked dalvik-cache files are 0755; keep ours the same.
  find "$R/usr/share/konkr-android" -path '*/data/dalvik-cache/*' -type f -exec chmod 0755 {} +
else
  log "WARN: no konkr-android payload (external-and-mods/konkr-android/build-payload.sh); Android apps will lack the Play Store and fixes"
fi
chroot "$R" update-mime-database /usr/share/mime
chroot "$R" update-desktop-database -q /usr/share/applications
# Opt-in s2idle (konkrctl sleep s2idle): konkr-sleep.service prepares
# Wi-Fi/touch/audio/wake sources. Default sleep is konkr-standby.
mkdir -p "$R/usr/lib/systemd/system/sleep.target.wants"
ln -sfn ../konkr-sleep.service "$R/usr/lib/systemd/system/sleep.target.wants/konkr-sleep.service"
# SSH stays off, like on the Steam Deck: a public image should not listen on
# every user's network. /etc/ssh/sshd_config.d/10-konkr.conf (password login
# for steamos, root off) applies once a user runs `passwd` and
# `sudo systemctl enable --now sshd`. The build rootfs is reused, so drop a
# link left by earlier builds.
rm -f "$R/usr/lib/systemd/system/multi-user.target.wants/sshd.service" \
  "$R/etc/systemd/system/multi-user.target.wants/sshd.service" \
  "$R/var/lib/overlays/etc/upper/systemd/system/multi-user.target.wants/sshd.service"
# Discover: fetch the Flathub catalog (never downloaded on a fresh image).
mkdir -p "$R/usr/lib/systemd/system/timers.target.wants"
ln -sfn ../konkr-flatpak-appstream.timer \
  "$R/usr/lib/systemd/system/timers.target.wants/konkr-flatpak-appstream.timer"
# Speaker volume curve (user session). Vendor wants dir: /etc links written at
# runtime are not seen at boot on SteamOS (overlay mounted late).
mkdir -p "$R/usr/lib/systemd/user/default.target.wants"
ln -sfn ../konkr-volume.service "$R/usr/lib/systemd/user/default.target.wants/konkr-volume.service"
# konkrd: fan curve (ROCKNIX leaves the fan at 70/255), profiles, game-thread
# boost, extra buttons, LEDs. ExecCondition keeps it off non-KONKR devices.
mkdir -p "$R/etc/systemd/system/multi-user.target.wants" "$R/var/lib/konkrd"
ln -sfn /usr/lib/systemd/system/konkrd.service \
  "$R/etc/systemd/system/multi-user.target.wants/konkrd.service"
if [[ -d "$R/var/lib/overlays/etc/upper" ]]; then
  mkdir -p "$R/var/lib/overlays/etc/upper/systemd/system/multi-user.target.wants" \

  ln -sfn /usr/lib/systemd/system/konkrd.service \
    "$R/var/lib/overlays/etc/upper/systemd/system/multi-user.target.wants/konkrd.service"
  # MCU link is on by default (verified on the Pocket FIT: Quick Access and
  # Performance buttons, stick RGB). konkrctl mcu disable re-blacklists it.
  # The build rootfs is reused across builds, so drop a blacklist left by
  # testing `konkrctl mcu disable` — v1.0/v1.1 shipped with the buttons dead.
  rm -f "$R/etc/modprobe.d/konkr-mcu.conf" "$R/var/lib/overlays/etc/upper/modprobe.d/konkr-mcu.conf"
  cp -f "$SM8650_OVL/etc/konkrd.conf" "$R/var/lib/overlays/etc/upper/konkrd.conf"
  # The base image has its own powerdevilrc in the upper layer, which would
  # shadow ours (konkrd owns the power button, Plasma must not act on it).
  mkdir -p "$R/var/lib/overlays/etc/upper/xdg"
  cp -f "$SM8650_OVL/etc/xdg/powerdevilrc" "$R/var/lib/overlays/etc/upper/xdg/powerdevilrc"
  mkdir -p "$R/var/lib/overlays/etc/upper/systemd/coredump.conf.d"
  cp -f "$SM8650_OVL/etc/systemd/coredump.conf.d/10-konkr-sd.conf" \
    "$R/var/lib/overlays/etc/upper/systemd/coredump.conf.d/"
  cp -r "$SM8650_OVL/etc/inputplumber/." "$R/var/lib/overlays/etc/upper/inputplumber/" 2>/dev/null \
    || { mkdir -p "$R/var/lib/overlays/etc/upper/inputplumber"; cp -r "$SM8650_OVL/etc/inputplumber/." "$R/var/lib/overlays/etc/upper/inputplumber/"; }
  # cp keeps the source modes; a tree that went through the exFAT HDD has 0755
  # files (systemd warns about an executable coredump.conf) and 0700 dirs.
  chmod 0644 "$R/var/lib/overlays/etc/upper/konkrd.conf" \
    "$R/var/lib/overlays/etc/upper/xdg/powerdevilrc" \
    "$R/var/lib/overlays/etc/upper/systemd/coredump.conf.d/10-konkr-sd.conf"
  find "$R/var/lib/overlays/etc/upper/inputplumber" \
    \( -type d -exec chmod 0755 {} + \) -o \( -type f -exec chmod 0644 {} + \)
fi

# ---------------------------------------------------------------------------
# Bottom screen: second panel in Game Mode (AYN Thor, AYANEO Pocket DS). The
# Game Mode gamescope lends it through a DRM lease (gamescope-session) and
# bottom-screen.service runs a second gamescope with the dashboard on it.
# ---------------------------------------------------------------------------
log "== bottom screen (dual-screen dashboard)"
DS_OVL="${ROOT}/dualscreen-overlay"
cp -r --no-preserve=mode,ownership "$DS_OVL/." "$R/"
chmod 0755 "$R/usr/lib/steamos-arm" "$R/usr/lib/steamos-arm/bottom-screen" \
  "$R/usr/lib/steamos-arm/bottom-screen/qml" \
  "$R/usr/lib/steamos-arm/bottom-screen/qml/skins" "$R/usr/lib/steamos-arm/bottom-screen/qml/skins/"*/ \
  "$R/usr/lib/steamos-arm/bottom-screen/bottom-screen-session" \
  "$R/usr/lib/steamos-arm/bottom-screen/dashboard" \
  "$R/usr/lib/steamos-arm/bottom-screen/bottom-screen-desktop" \
  "$R/usr/lib/steamos-arm/bottom-screen/thor-backlightd"
chmod 0755 "$R/usr/share/steamos-arm" "$R/usr/share/steamos-arm/bottom-screen" "$R/usr/share/steamos-arm/features"
chmod 0644 "$R/usr/share/steamos-arm/features/"*
chmod 0644 "$R/usr/lib/steamos-arm/bottom-screen/qml/qmldir" \
  "$R/usr/lib/steamos-arm/bottom-screen/swipetype.py" \
  "$R/usr/share/steamos-arm/bottom-screen/"* \
  "$R/usr/lib/steamos-arm/bottom-screen/qml/"*.qml \
  "$R/usr/lib/steamos-arm/bottom-screen/qml/skins/README.md" \
  "$R/usr/lib/steamos-arm/bottom-screen/qml/skins/"*/* \
  "$R/usr/lib/systemd/user/bottom-screen.service" \
  "$R/usr/lib/systemd/system/bottom-screen-bootflag.service" \
  "$R/usr/lib/systemd/system/thor-backlightd.service" \
  "$R/usr/share/polkit-1/rules.d/60-steamos-arm-bottom-screen.rules" \
  "$R/etc/xdg/autostart/steamos-arm-bottom-screen.desktop"
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
ln -sfn ../bottom-screen-bootflag.service \
  "$R/usr/lib/systemd/system/multi-user.target.wants/bottom-screen-bootflag.service"
# Thor only (ConditionFirmware): Steam's brightness slider for both screens.
ln -sfn ../thor-backlightd.service \
  "$R/usr/lib/systemd/system/multi-user.target.wants/thor-backlightd.service"
# /etc is an overlay mounted after systemd reads units: enable under /usr.
mkdir -p "$R/usr/lib/systemd/user/gamescope-session.target.wants"
ln -sfn ../bottom-screen.service \
  "$R/usr/lib/systemd/user/gamescope-session.target.wants/bottom-screen.service"
# Lower Deck: the bottom screen from Quick Access. Bundled for every image;
# the boot service puts it in Decky only on a model in its "models" file.
LD_SRC="${ROOT}/external-and-mods/Decky/dualscreen/lower-deck"
LD_DST="$R/usr/share/steamos-odin/decky-plugins/lower-deck"
rm -rf "$LD_DST"; install -d -m0755 "$LD_DST/dist"
install -m0644 "$LD_SRC/plugin.json" "$LD_SRC/main.py" "$LD_SRC/package.json" "$LD_SRC/models" "$LD_DST/"
install -m0644 "$LD_SRC/dist/index.js" "$LD_DST/dist/"
install -D -m0644 "${ROOT}/steamos-overlay/usr/lib/systemd/system/steamos-arm-lower-deck.service" \
  "$R/usr/lib/systemd/system/steamos-arm-lower-deck.service"
ln -sfn ../steamos-arm-lower-deck.service \
  "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-lower-deck.service"

# ---------------------------------------------------------------------------
# SM8550 device overlay: AYANEO Pocket / Retroid Pocket pads (deck-uhid),
# Thor + AYANEO Pocket UCM, AYANEO volume keys. Applied on every image (it
# matches by DT model), so one rootfs serves both SoCs; only the kernel,
# modules and firmware differ per SoC.
# ---------------------------------------------------------------------------
log "== SM8550 overlay (AYN / AYANEO / Retroid)"
cp -r --no-preserve=mode,ownership "$SM8550_OVL/." "$R/"
cp -f "$SM8550_OVL"/etc/inputplumber/capability_maps.d/*.yaml "$R/usr/share/inputplumber/capability_maps/"
if [[ -d "$R/var/lib/overlays/etc/upper/inputplumber" ]]; then
  cp -r --no-preserve=mode,ownership "$SM8550_OVL/etc/inputplumber/." "$R/var/lib/overlays/etc/upper/inputplumber/"
fi
find "$R/usr/share/alsa/ucm2/AYN" "$R/usr/share/alsa/ucm2/AYANEO" "$R/usr/share/alsa/ucm2/conf.d/sm8550" \
  "$R/etc/inputplumber" "$R/var/lib/overlays/etc/upper/inputplumber" 2>/dev/null \
  \( -type d -exec chmod 0755 {} + \) -o \( -type f -exec chmod 0644 {} + \)
chmod 0644 "$R/usr/lib/udev/hwdb.d/10-ayaneo.hwdb"
# 8 Gen 2 image: Wi-Fi firmware from upstream linux-firmware (pinned tag and
# hashes). The Frame's WCN7850 board file only has the Frame's own 2 boards,
# so the 8 Gen 2 handhelds fell back to generic radio data; upstream has 67
# and newer firmware (WLAN.HMT.1.1.c7). regdb.bin stays as it is. The 8 Gen 3
# images keep the Frame's set, which is what the Pocket FIT was tuned on.
# Off by default since beta 8: with it the Odin 2 (7.0.14 kernel) found no
# networks at all. Beta 7's set (the Frame's files + ROCKNIX's board.bin)
# worked, so that's what ships; WIFI_FW_UPSTREAM=1 brings this back.
WIFI_FW_TAG=20260916
WIFI_FW_CACHE="${WORKDIR}/kernel-sm8550/cache/lfw-ath12k-${WIFI_FW_TAG}/WCN7850/hw2.0"
declare -A WIFI_FW_SHA=(
  [amss.bin]=43aadfd3df887f27de74020273aee484bac6a31dd53068f91baf2a9b094d6a68
  [m3.bin]=0e72f44df7defc269fe92dcea25d4d409046c04b77d41c510c52879b3dfc1055
  [board-2.bin]=1abee7132dbccb523cca44a8de4e8968aa7bf5a5fcc032c338f687f94ea5bf4e
  [Notice.txt]=515bf4c9d620a87458e4447fe01a0e9bc384d1c3e0037cc4c3d2037b1ff25525
)
WIFI_FW_DST="$R/usr/lib/firmware/ath12k/WCN7850/hw2.0"
if [[ "${SOC:-sm8650}" == sm8550 && "${WIFI_FW_UPSTREAM:-0}" == 1 ]]; then
  mkdir -p "$WIFI_FW_CACHE"
  for f in "${!WIFI_FW_SHA[@]}"; do
    if [[ ! -f "$WIFI_FW_CACHE/$f" ]] || ! echo "${WIFI_FW_SHA[$f]}  $WIFI_FW_CACHE/$f" | sha256sum -c --quiet 2>/dev/null; then
      curl -sfL -o "$WIFI_FW_CACHE/$f" \
        "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/ath12k/WCN7850/hw2.0/$f?h=${WIFI_FW_TAG}" \
        || die "Wi-Fi firmware download failed: $f"
    fi
    echo "${WIFI_FW_SHA[$f]}  $WIFI_FW_CACHE/$f" | sha256sum -c --quiet || die "Wi-Fi firmware hash mismatch: $f"
  done
  mkdir -p "$STOCK/wcn7850-frame"
  for f in amss.bin m3.bin board-2.bin; do
    [[ -f "$WIFI_FW_DST/$f" && ! -f "$STOCK/wcn7850-frame/$f" ]] && cp -a "$WIFI_FW_DST/$f" "$STOCK/wcn7850-frame/$f"
    install -m0644 "$WIFI_FW_CACHE/$f" "$WIFI_FW_DST/$f"
  done
  install -m0644 "$WIFI_FW_CACHE/Notice.txt" "$WIFI_FW_DST/Notice.txt"
  log "== Wi-Fi: upstream WCN7850 firmware ${WIFI_FW_TAG}"
elif [[ -d "$STOCK/wcn7850-frame" ]]; then
  # The rootfs had the upstream set from an earlier build: put the Frame's back.
  for f in amss.bin m3.bin board-2.bin; do
    [[ -f "$STOCK/wcn7850-frame/$f" ]] && install -m0644 "$STOCK/wcn7850-frame/$f" "$WIFI_FW_DST/$f"
  done
  rm -f "$WIFI_FW_DST/Notice.txt"
fi

# 8 Gen 2 image only (UFS, mic, CPU pins): sm8550-image-overlay.
# The rootfs is reused between builds, so an 8 Gen 3 build removes them again.
# zram, TEO and the backlight untag moved to steamos-overlay (every SoC);
# drop their old 8 Gen 2 names from a reused rootfs.
rm -f "$R/usr/lib/tmpfiles.d/sm8550-cpuidle-teo.conf" \
      "$R/usr/lib/systemd/zram-generator.conf.d/60-sm8550-zram.conf" \
      "$R/usr/lib/udev/rules.d/99-zz-sm8550-backlight-untag.rules"
for f in usr/lib/systemd/zram-generator.conf.d/60-steamos-arm-zram.conf \
         usr/lib/tmpfiles.d/steamos-arm-cpuidle-teo.conf \
         usr/lib/udev/rules.d/99-zz-steamos-arm-backlight-untag.rules; do
  install_file "$OVL/$f" "$R/$f" 0644
done
IMG_OVL="${ROOT}/sm8550-image-overlay"
mapfile -t _img_files < <(cd "$IMG_OVL" && find usr -type f)
if [[ "${SOC:-sm8650}" == sm8550 ]]; then
  log "== SM8550 image-only files (${#_img_files[@]})"
  for f in "${_img_files[@]}"; do install -D -m0644 "$IMG_OVL/$f" "$R/$f"; done
else
  for f in "${_img_files[@]}"; do rm -f "$R/$f"; done
fi
# Log collector behind the BOOT "debug" file, also for kernels that don't
# run our initramfs (it is the same script our initramfs installs).
install -D -m0755 "$MOD/kernel-common/initramfs/bootdebug" "$R/usr/lib/steamos-arm/bootdebug"
chmod 0644 "$R/usr/lib/systemd/system/steamos-arm-bootdebug-file.service"
if command -v systemd-hwdb >/dev/null; then
  systemd-hwdb update --root "$R" --usr
else
  chroot "$R" systemd-hwdb update --usr
fi

# ---------------------------------------------------------------------------
# MangoHud: keep SteamOS stock binaries. Host Ubuntu mangoapp needs GLIBC_2.43
# (SteamOS is 2.39) and crash-loops gamescopereaper / the session.
# Build from external-and-mods/MangoHud against SteamOS glibc before replacing.
# ---------------------------------------------------------------------------
log "== MangoHud (stock SteamOS — host Ubuntu mango needs GLIBC_2.43)"
for b in mangohud mangoapp mangohudctl; do
  if [[ -f "$STOCK/usr/bin/$b" ]]; then
    install_file "$STOCK/usr/bin/$b" "$R/usr/bin/$b" 0755
  fi
done
for lib in libMangoHud.so libMangoHud_opengl.so libMangoHud_shim.so libMangoHud-next.so; do
  if [[ -f "$STOCK/usr/lib/$lib" ]]; then
    install_file "$STOCK/usr/lib/$lib" "$R/usr/lib/$lib" 0755
  fi
done
# Wi-Fi back in under a second after sleep: the Frame's NetworkManager with
# Valve's resume scan patch (scripts/build-networkmanager-in-rootfs.sh).
NMBUILD="${NETWORKMANAGER_BUILD:-${WORKDIR}/networkmanager-build}"
NMVER="$(cat "$NMBUILD/VERSION" 2>/dev/null)"
if [[ -x "$NMBUILD/NetworkManager" && -d "$R/usr/lib/NetworkManager/$NMVER" ]]; then
  install_file "$NMBUILD/NetworkManager" "$R/usr/bin/NetworkManager" 0755
  install_file "$NMBUILD/libnm-device-plugin-wifi.so" "$R/usr/lib/NetworkManager/$NMVER/libnm-device-plugin-wifi.so" 0755
  log "NetworkManager: ours ($NMVER, fast resume)"
else
  log "WARN: no NetworkManager build for this rootfs, Wi-Fi takes ~9 s to come back after sleep"
fi
# Steam's performance overlay: our mangoapp (scripts/build-mangohud-in-rootfs.sh)
# reads GPU load, clock and VRAM on Adreno; stock shows the GPU at 0 %.
MHBUILD="${MANGOHUD_BUILD:-${WORKDIR}/mangohud-build}"
if [[ -x "$MHBUILD/mangoapp" ]]; then
  install_file "$MHBUILD/mangoapp" "$R/usr/bin/mangoapp" 0755
  log "mangoapp: ours ($MHBUILD)"
else
  log "WARN: no $MHBUILD/mangoapp, Steam's overlay keeps stock (GPU shows 0 %)"
fi

# Hardware video decode for VA-API apps (scripts/install-v4l2-vaapi.sh).
"${SCRIPT_DIR}/install-v4l2-vaapi.sh" "$R" | tee -a "$LOG"
# Hostname from the model, Desktop scale from the panel (scripts/install-device-defaults.sh).
"${SCRIPT_DIR}/install-device-defaults.sh" "$R" | tee -a "$LOG"

# ---------------------------------------------------------------------------
# lsfg-vk
# ---------------------------------------------------------------------------
log "== lsfg-vk 2.0 (unmodified ARM layer + Decky x86 runtime)"
# Reused roots must not register the old 1.x layer alongside version 2.
for prefix in "$R/usr" "$R/usr/local"; do
  rm -f "$prefix/lib/liblsfg-vk.so" "$prefix/lib/liblsfg-vk-arm64.so" \
    "$prefix/share/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json" \
    "$prefix/share/vulkan/implicit_layer.d/VkLayer_LS_frame_generation_arm64.json"
done
[[ -r "$R/usr/lib/liblsfg-vk-layer-arm64.so" ]] || die "missing LSFG v2 ARM layer"

# ---------------------------------------------------------------------------
# Mesa Turnip
# ---------------------------------------------------------------------------
# Pin the Frame's Turnip for mangoapp (zink must match its own Turnip; see
# /usr/lib/steamos-sm8650/bin/mangoapp). Taken before any override below.
log "== pin Frame Turnip for the Performance Overlay"
FRAME_TURNIP="$R/usr/lib/libvulkan_freedreno.so"
[[ -f "$STOCK/usr/lib/libvulkan_freedreno.so" ]] && FRAME_TURNIP="$STOCK/usr/lib/libvulkan_freedreno.so"
mkdir -p "$R/usr/lib/steamos-sm8650/frame-turnip" "$R/usr/share/steamos-sm8650"
install_file "$FRAME_TURNIP" "$R/usr/lib/steamos-sm8650/frame-turnip/libvulkan_freedreno.so" 0755
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
chmod 0755 "$R/usr/lib/steamos-sm8650/bin/mangoapp" 2>/dev/null || true

# 8 Gen 2 (Adreno 740): our own Mesa 26.2.3 stack with the A740 fixes
# (scripts/build-mesa.sh, external-and-mods/mesa/README.md) replaces Valve's
# whole Mesa, native and in the FEX guest tree. Valve's files go by their
# package file lists so nothing of the two builds mixes.
if [[ -n "${MESA_STACK:-}" ]]; then
  log "== Mesa: A740 stack from $MESA_STACK"
  for a in aarch64 x86_64 i386; do
    ls "$MESA_STACK/$a/usr/share/vulkan/icd.d/"freedreno_icd.*.json >/dev/null 2>&1 \
      || die "MESA_STACK has no $a build"
  done
  ANDROID_VENDOR="usr/share/guestos/android/vendor/lib64"
  [[ -f "$MESA_STACK/android/$ANDROID_VENDOR/hw/vulkan.freedreno.so" ]] \
    || die "MESA_STACK has no android build (Lepton)"
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
  GUEST="$R/usr/share/guestos/fex-mesa"
  cp -a "$MESA_STACK/aarch64/usr/lib/." "$R/usr/lib/"
  cp -a "$MESA_STACK/aarch64/usr/share/." "$R/usr/share/"
  cp -a "$MESA_STACK/x86_64/usr/lib/." "$GUEST/usr/lib/"
  cp -a "$MESA_STACK/x86_64/usr/share/." "$GUEST/usr/share/"
  cp -a "$MESA_STACK/i386/usr/lib32/." "$GUEST/usr/lib32/"
  cp -a "$MESA_STACK/i386/usr/share/vulkan/." "$GUEST/usr/share/vulkan/"
  # Lepton (Android apps): same files and names as Valve's Android Mesa.
  mkdir -p "$R/$ANDROID_VENDOR"
  cp -a "$MESA_STACK/android/$ANDROID_VENDOR/." "$R/$ANDROID_VENDOR/"
  chown -R root:root "$R/$ANDROID_VENDOR"
  chown -R root:root "$R/usr/lib/dri" "$GUEST/usr/lib/dri" "$GUEST/usr/lib32/dri"
  # mangoapp runs on the system Turnip (it matches our zink), no pin.
  rm -rf "$R/usr/lib/steamos-sm8650/frame-turnip" \
    "$R/usr/share/steamos-sm8650/frame-turnip_icd.aarch64.json"
  # Our 26.2.3 has no msm DRI driver and, unlike Valve's 26.3-devel, doesn't
  # fall back to zink on its own: Xwayland got "msm: driver missing", no GBM,
  # and Steam crash-looped behind a black screen (Odin 2 tester, beta 3).
  # environment.d reaches the whole user session (gamescope, Xwayland, Steam,
  # Plasma) and games, including FEX's x86 Mesa.
  mkdir -p "$R/usr/lib/environment.d"
  printf '# SM8550 image (our Mesa): GL goes through zink on Turnip, like the Frame.\nMESA_LOADER_DRIVER_OVERRIDE=zink\n' \
    >"$R/usr/lib/environment.d/60-sm8550-zink.conf"
  chmod 0644 "$R/usr/lib/environment.d/60-sm8550-zink.conf"
  for f in "$R/usr/lib/libgallium-"*.so "$GUEST/usr/lib/libgallium-"*.so \
           "$GUEST/usr/lib32/libgallium-"*.so "$R/$ANDROID_VENDOR/libgallium_dri.so"; do
    log "   ${f#$R}: $(grep -a -o -m1 'Mesa [0-9][0-9.]*' "$f" || echo '?')"
  done
elif [[ -n "$MESA_SO" ]]; then
  rm -f "$R/usr/lib/environment.d/60-sm8550-zink.conf"
  log "== Mesa override $MESA_SO"
  backup "$R/usr/lib/libvulkan_freedreno.so" "$STOCK/usr/lib/libvulkan_freedreno.so"
  install_file "$MESA_SO" "$R/usr/lib/libvulkan_freedreno.so" 0755
else
  rm -f "$R/usr/lib/environment.d/60-sm8550-zink.conf"
  log "== Mesa: keeping Frame Turnip (Adreno 750 = this SoC)"
fi

# ---------------------------------------------------------------------------
# User home (steamos uid 1000)
# ---------------------------------------------------------------------------
log "== home/steamos (Decky plugin + configs)"
if [[ -n "${STEAMOS_HOME:-}" ]]; then
  HOME_DST="$STEAMOS_HOME"
elif [[ -d /run/media/steam/home/steamos && "$R" == /run/media/steam/root ]]; then
  HOME_DST=/run/media/steam/home/steamos
else
  HOME_DST="$R/home/steamos"
fi
mkdir -p "$HOME_DST"
# Copy plugin tree (resolve lsfg .so symlink into a real file if needed)
# .local/lib/liblsfg-vk.so is a link to the SM8550 builder's host library;
# skip it (decky-lsfg-vk installs its own copy).
rsync -a --copy-links --exclude '.local/lib/liblsfg-vk.so' "${MOD}/Decky/Plug-ins/" "$HOME_DST/"
# Decky itself. Upstream left it to a first-boot installer in ARM-Manager
# that most people never found — no Decky, so no KONKR Control either.
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
mkdir -p "$HOME_DST/homebrew/services" "$HOME_DST/homebrew/settings" "$HOME_DST/homebrew/data" "$HOME_DST/homebrew/logs"
# ~/.cache must exist (user-owned, see chown below) before anything running
# as root with HOME=/home/steamos can create it root-owned.
mkdir -p "$HOME_DST/.cache"
install -m0755 "$DECKY_LOADER" "$HOME_DST/homebrew/services/PluginLoader"
printf '%s' "$DECKY_VERSION" >"$HOME_DST/homebrew/services/.loader.version"
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
ln -sfn ../plugin_loader.service "$R/usr/lib/systemd/system/multi-user.target.wants/plugin_loader.service"
# Updating Decky writes its own unit to /etc (runs the x86 binary without
# box64); this drop-in keeps box64 in front whatever unit file wins.
install_file "$OVL/usr/lib/systemd/system/plugin_loader.service.d/50-steamos-arm-box64.conf" \
  "$R/usr/lib/systemd/system/plugin_loader.service.d/50-steamos-arm-box64.conf" 0644
# Loadout: emulators, PC game stores and apps (engine + Decky plugin).
"${SCRIPT_DIR}/install-hub.sh" "$R" "$HOME_DST"
# Fix lsfg-vk home paths
if [[ -f "$HOME_DST/.config/lsfg-vk/conf.toml" ]]; then
  sed -i 's|/home/steam/|/home/steamos/|g' "$HOME_DST/.config/lsfg-vk/conf.toml"
fi
if [[ -f "$HOME_DST/.local/share/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json" ]]; then
  python3 - "$HOME_DST" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]) / ".local/share/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json"
txt = p.read_text()
txt = txt.replace("/home/steam/", "/home/steamos/")
p.write_text(txt)
PY
fi
rm -f "$HOME_DST/.local/lib/liblsfg-vk.so" \
  "$HOME_DST/.local/share/vulkan/implicit_layer.d/VkLayer_LS_frame_generation.json"
rm -f "$HOME_DST/LEEME-ODIN.txt" "$HOME_DST/README-ODIN.txt"

# Frame steam.tar.zst is an incomplete client (spinner, no package zips).
# Bake a complete ARM client (seed binaries from host if present), then
# strip login/account data so first boot is a clean Steam Deck login.
STEAM_HOME="$HOME_DST/.local/share/Steam"
log "== complete Steam ARM client"
mkdir -p "$STEAM_HOME"
if [[ -x "${SCRIPT_DIR}/install-complete-steam-client.sh" ]]; then
  "${SCRIPT_DIR}/install-complete-steam-client.sh" "$STEAM_HOME" \
    || die "complete Steam client installation failed"
fi
if [[ -x "$R/usr/lib/steamos/sm8550-patch-steamui" && -d "$STEAM_HOME/steamui" ]]; then
  "$R/usr/lib/steamos/sm8550-patch-steamui" "$STEAM_HOME/steamui" || true
fi
touch "$STEAM_HOME/.install-complete"
# Steam UI through ANGLE-Vulkan on Turnip instead of ANGLE -> GL -> zink
# (see konkrd ensure_webhelper_vulkan, which keeps it after client updates).
WH="$STEAM_HOME/steamrtarm64/steamwebhelper.sh"
if [[ -f "$WH" ]] && ! grep -q KONKR_CEF_FLAGS "$WH"; then
  python3 - "$WH" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); s = p.read_text()
old = 'exec taskset 0x7c $(pwd)/steamwebhelper "$@" &> ~/.steam/steam/logs/steamwebhelper.log'
new = ('KONKR_CEF_FLAGS="--use-gl=angle --use-angle=vulkan '
       '--enable-features=Vulkan,DefaultANGLEVulkan,VulkanFromANGLE"\n'
       'exec taskset 0x7c $(pwd)/steamwebhelper "$@" $KONKR_CEF_FLAGS &> ~/.steam/steam/logs/steamwebhelper.log')
if old in s:
    p.write_text(s.replace(old, new))
PY
fi
install_file "$OVL/usr/share/deckard/RUNSTEAM.sh" \
  "$STEAM_HOME/RUNSTEAM.sh" 0755
if [[ -d "$STEAM_HOME/linuxarm64" && -d "$STEAM_HOME/steamrtarm64" ]]; then
  for _lib in steamclient.so crashhandler.so steam-launch-wrapper; do
    if [[ -s "$STEAM_HOME/steamrtarm64/${_lib}" && ! -s "$STEAM_HOME/linuxarm64/${_lib}" ]]; then
      cp -f "$STEAM_HOME/steamrtarm64/${_lib}" "$STEAM_HOME/linuxarm64/${_lib}"
    fi
  done
  unset _lib
fi

# Desktop: only Return to Gaming Mode. Decky lives in ARM-Manager.
mkdir -p "$HOME_DST/Desktop" "$R/usr/share/applications" "$R/usr/share/icons/hicolor/scalable/apps"
rm -f "$HOME_DST/Desktop/Decky Loader.desktop" "$HOME_DST/Desktop/install-decky.desktop"

# ---------------------------------------------------------------------------
# Plasma extras + ARM-Manager + LSFG/Thor/Decky plugins
# ---------------------------------------------------------------------------
log "== plasma extras (holo kate/ark/networkmanager-qt/…)"
STEAMOS_HOME="$HOME_DST" "${SCRIPT_DIR}/install-plasma-extras.sh" "$R" \
  || log "WARN: plasma extras incomplete"
if [[ ! -f "$R/usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_kscreen.so" ]]; then
  log "== official Plasma kscreen 6.2.5 KCM"
  "${SCRIPT_DIR}/build-kscreen-6.2.5.sh" "$R" \
    || die "kscreen 6.2.5 is required (Display Configuration)"
fi
if [[ ! -f "$R/usr/lib/qt6/plugins/plasma/kcms/systemsettings_qwidgets/kcm_networkmanagement.so" ]]; then
  log "== KF6 NetworkManagerQt 6.14 (plasma-nm needs >= 6.5)"
  "${SCRIPT_DIR}/build-kf6-nm-qt-6.14.sh" "$R" \
    || die "networkmanager-qt 6.14 is required"
  log "== official Plasma plasma-nm 6.2.5 (Network Manager)"
  "${SCRIPT_DIR}/build-plasma-nm-6.2.5.sh" "$R" \
    || die "plasma-nm 6.2.5 is required (Network Manager)"
fi
if [[ ! -x "$R/usr/bin/plasma-keyboard" ]]; then
  log "== plasma-keyboard 0.1.0 (desktop touch keyboard)"
  "${SCRIPT_DIR}/build-plasma-keyboard.sh" "$R" \
    || die "plasma-keyboard is required (Desktop Mode touch keyboard)"
fi
# extras skip ALARM Gear (Qt_6.11). Build official 26.04.2 for Qt 6.8.
needs_gear_qt68() {
  local bin="$R/usr/bin/$1"
  [[ ! -x "$bin" ]] && return 0
  strings "$bin" 2>/dev/null | grep 'Qt_6\.11' >/dev/null
}
for _gear in ark kcalc filelight gwenview okular; do
  if needs_gear_qt68 "$_gear"; then
    log "== official ${_gear} 26.04.2 for Qt 6.8"
    "${SCRIPT_DIR}/build-kde-gear-26.04.2.sh" "$R" "$_gear" \
      || die "required desktop app ${_gear} build failed"
  fi
done
log "== vendor apps (UFS, MESA, Proton-ARM, Non-Steam, SRM)"
STEAMOS_HOME="$HOME_DST" "${SCRIPT_DIR}/install-vendor-apps.sh" "$R" \
  || die "required vendor apps (installer/updater) failed"
log "== system fixes (LSFG-VK, Thor, Decky plugins, Return icon)"
STEAMOS_HOME="$HOME_DST" "${SCRIPT_DIR}/install-system-fixes.sh" "$R" \
  || log "WARN: system fixes incomplete"

# ---------------------------------------------------------------------------
# Ownership / extras
# ---------------------------------------------------------------------------
log "== permissions"
chown -R 1000:1000 "$HOME_DST"
chmod 0755 "$HOME_DST"
# NetworkManager refuses plugins/scripts not owned by root (wifi/bt stay dead).
if [[ -d "$R/usr/lib/NetworkManager" ]]; then
  chown -R root:root "$R/usr/lib/NetworkManager" || true
  find "$R/usr/lib/NetworkManager" -type f -name '*.so' -exec chmod 0755 {} + || true
fi
if [[ -d "$R/etc/NetworkManager" ]]; then
  chown -R root:root "$R/etc/NetworkManager" || true
fi
if [[ -d "$R/var/lib/overlays/etc/upper/NetworkManager" ]]; then
  chown -R root:root "$R/var/lib/overlays/etc/upper/NetworkManager" || true
fi
# User session PipeWire.
if [[ -d "$HOME_DST" ]]; then
  mkdir -p "$HOME_DST/.config/systemd/user/default.target.wants"
  for u in pipewire.service pipewire-pulse.service sm8550-audio-pipewire.service sm8550-volume-keys.service; do
    src="/usr/lib/systemd/user/${u}"
    [[ -f "$R${src}" ]] || continue
    ln -sfn "$src" "$HOME_DST/.config/systemd/user/default.target.wants/${u}"
  done
  chown -hR 1000:1000 "$HOME_DST/.config"
fi
# SteamOS empty-password user stays as extracted (steamos:: in shadow)

# ldconfig cache is arch-specific; skip. Dynamic linker will still find /usr/lib.

# Empty mount points the bwrap builds (gamescope/box64) leave in the rootfs.
rmdir "$R/src/box64" "$R/src/gamescope" "$R/src/dpl" "$R/src" "$R/build-parent" 2>/dev/null || true

# Desktop Mode look: Frame's steamos-set-plasma-theme only picks the Deck
# theme on Jupiter/Galileo boards. com.valve.vapor.desktop has no splash,
# so Plasma shows its stock "KDE Plasma" one instead of the Steam logo.
if [[ -f "$R/etc/xdg/kdeglobals" ]]; then
  sed -i 's/^LookAndFeelPackage=.*/LookAndFeelPackage=com.valve.vapor.deck.desktop/' "$R/etc/xdg/kdeglobals"
fi

log "== source permissions"
# cp -a keeps the source tree's modes, and a copy that went through the
# exFAT HDD has 0700 dirs and 0600 files. gamescope runs as steamos: with an
# unreadable /usr/share/gamescope/scripts it never defines debug(), the
# KONKR display script aborts it and Game Mode is a black screen.
for d in usr/share usr/local/share usr/lib/konkr usr/lib/steamos etc/gamescope etc/inputplumber; do
  [[ -d "$R/$d" ]] || continue
  find "$R/$d" -xdev \( -path '*/guestos' -o -path '*/factory/root' \) -prune -o \
    -type d \( ! -perm -o=rx -o ! -perm -u=x \) -exec chmod u+rwx,go+rx {} + -o \
    -type f ! -perm -o=r -exec chmod go+r {} +
done
find "$R" -xdev -name '._*' -type f -delete 2>/dev/null || true
# Nothing under /usr or /etc belongs to a regular user. A tarball unpacked
# with its owner (uid 1001) made /usr unowned: polkit, D-Bus and sshd then
# ignore their files, and Discover, Decky and more break.
find "$R/usr" "$R/etc" -xdev \( -uid +999 -o -gid +999 \) -exec chown -h root:root {} + 2>/dev/null || true

log "== summary"
{
  echo "gamescope: $(file -b "$R/usr/bin/gamescope")"
  echo "KERNEL:    $(file -b "$R/boot/KERNEL")"
  echo "modules:   $R/usr/lib/modules/$KREL"
  echo "mesa:      $(ls -l "$R/usr/lib/libvulkan_freedreno.so")"
  echo "display-info.so.3: $(ls -l "$R/usr/lib/libdisplay-info.so.3" 2>/dev/null || echo missing)"
  echo "lsfg:      $(ls -l "$R/usr/local/lib/liblsfg-vk.so" 2>/dev/null || echo missing)"
  echo "fixpad:    $(ls -l "$R/usr/lib/steamos/sm8550-fixpad" 2>/dev/null || echo missing)"
  echo "inputplumber: $(ls -l "$R/usr/bin/inputplumber" 2>/dev/null || echo missing)"
  echo "deck-uhid: $(grep -A2 target_devices "$R/etc/inputplumber/devices.d/02-ayn-odin.yaml" 2>/dev/null || echo missing)"
  echo "home:      $(find "$HOME_DST" -maxdepth 3 -printf '%p\n' | head -40)"
} | tee -a "$LOG"

# Last: what this image installed, and which release it is, so updates
# know what they're changing and Steam knows what's current.
python3 "$ROOT/external-and-mods/konkr-update/konkr-update.py" record-inventory --root "$R" \
  --version "${STEAMOS_ARM_VERSION:-1.3.0}" --soc "${SOC:-sm8650}" | tee -a "$LOG"

log "OK"
