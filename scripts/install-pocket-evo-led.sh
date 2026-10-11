#!/usr/bin/env bash
# Shared by full overlay builds and the existing Pocket EVO test-image repack.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
R=${1:?usage: install-pocket-evo-led.sh ROOTFS}
OVL="$ROOT/sm8550-overlay"
install -D -m755 "$OVL/usr/lib/pocketevo/pocket_evo_led.py" "$R/usr/lib/pocketevo/pocket_evo_led.py"
# Remove the former location when reusing an existing rootfs.
rm -f "$R/usr/lib/konkr/pocket_evo_led.py"
for unit in pocket-evo-led.service pocket-evo-led-sleep.service; do
  install -D -m644 "$OVL/usr/lib/systemd/system/$unit" "$R/usr/lib/systemd/system/$unit"
done
for etc in "$R/etc" "$R/var/lib/overlays/etc/upper"; do
  [[ -d "$etc" ]] || continue
  mkdir -p "$etc/systemd/system/multi-user.target.wants" "$etc/systemd/system/sleep.target.wants"
  ln -sfn /usr/lib/systemd/system/pocket-evo-led.service "$etc/systemd/system/multi-user.target.wants/pocket-evo-led.service"
  ln -sfn /usr/lib/systemd/system/pocket-evo-led-sleep.service "$etc/systemd/system/sleep.target.wants/pocket-evo-led-sleep.service"
done
