#!/usr/bin/env bash
# Install board-selected sleep recovery for full builds and image repacks.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
R=${1:?usage: install-pocket-evo-sleep.sh ROOTFS}
OVL="$ROOT/sm8550-overlay"
mkdir -p "$R/usr/lib/pocketevo" "$R/usr/lib/systemd/system/konkr-sleep.service.d"
for helper in pocket-evo-sleep pocket-evo-wifi-wake; do
  install -m755 "$OVL/usr/lib/pocketevo/$helper" "$R/usr/lib/pocketevo/$helper"
done
unit=usr/lib/systemd/system/konkr-sleep.service.d/50-pocket-evo.conf
install -m644 "$OVL/$unit" "$R/$unit"
