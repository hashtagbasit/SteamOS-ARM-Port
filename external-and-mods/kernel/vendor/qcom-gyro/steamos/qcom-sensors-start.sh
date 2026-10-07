#!/bin/bash
# Gyro sensors bring-up for the AYN Odin 2 / Portal: builds the hexagonrpcd tree, then runs the SensorsPD and RootPD listeners
# that bring up the ADSP sensor hub (QRTR service 400 = SSC).
# Needs the gyro kernel (fastrpc remote heap + qcom,fastrpc-adsp-sensors-pdr).
set -euo pipefail
GYRO="${QCOM_GYRO_DIR:-/usr/lib/qcom-gyro}"
P="${GYRO}"
SHARE="${GYRO}/share-qcom/sm8550/AYN"
S="${QCOM_GYRO_STATE:-/var/lib/qcom-gyro/state}"
R="${S}/root"

grep -qx 'ayn,thor' <(tr '\0' '\n' </proc/device-tree/compatible) &&
  { echo "Thor needs the Thor PD setup, not this script" >&2; exit 1; }

# The ADSP's sensor registry lives on the persist partition (stock Android).
mkdir -p "${S}/registry" "${R}/sensors" "${R}/dsp" "${R}/socinfo"
if [[ ! -s "${S}/registry/lsm6dsv_0_platform.config" ]]; then
  m="$(mktemp -d)"
  mount -t ext4 -o ro,noload /dev/disk/by-partlabel/persist "$m"
  cp -a "$m/sensors/registry/registry/." "${S}/registry/" || true
  umount "$m"; rmdir "$m"
fi
ln -snf "${SHARE}/thor/sensors/config" "${R}/sensors/config"
ln -snf "${SHARE}/odin2/sensors/sns_reg.conf" "${R}/sensors/sns_reg.conf"
ln -snf "${S}/registry" "${R}/sensors/registry"
v="$(sed -n 's/^version=//p' "${SHARE}/odin2/sensors/sns_reg.conf" | head -1)"
printf 'version=%s\0' "${v:-1}" >"${R}/sensors/sns_reg_version"
for f in soc_id revision machine family; do
  [[ -r /sys/devices/soc0/$f ]] && tr -d '\0' </sys/devices/soc0/$f >"${R}/socinfo/$f"
done
echo HDK >"${R}/socinfo/hw_platform"
for f in platform_subtype platform_subtype_id platform_version; do echo 0 >"${R}/socinfo/$f"; done
ln -snf "${SHARE}/thor/dsp/adsp" "${R}/dsp/adsp"

# Audio and sensors share the ADSP: wait for it to be up.
for _ in $(seq 60); do grep -q AYN /proc/asound/cards && break; sleep 1; done

"${P}/bin/hexagonrpcd" -f /dev/fastrpc-adsp -d adsp -s -R "${R}" &
sleep 1
exec "${P}/bin/hexagonrpcd" -f /dev/fastrpc-adsp -d adsp -R "${R}"
