#!/bin/bash
# Gyro sensors bring-up for the AYN Odin 2 / Mini / Portal and Thor: builds the
# hexagonrpcd tree, then runs the SensorsPD and RootPD listeners that bring up
# the ADSP sensor hub (QRTR service 400 = SSC).
# Needs the gyro kernel (fastrpc remote heap + qcom,fastrpc-adsp-sensors-pdr).
set -euo pipefail
GYRO="${QCOM_GYRO_DIR:-/usr/lib/qcom-gyro}"
P="${GYRO}"
SHARE="${GYRO}/share-qcom/sm8550/AYN"
S="${QCOM_GYRO_STATE:-/var/lib/qcom-gyro/state}"
R="${S}/root"
REG="${S}/registry"

# The registry gets this unit's learned calibration: only ever create it,
# never replace one that is already there.
mkdir -p "${REG}" "${R}/sensors" "${R}/dsp" "${R}/socinfo"
if grep -qx 'ayn,thor' <(tr '\0' '\n' </proc/device-tree/compatible); then
  # Thor (SH5001): no registry on persist, generate it from the stock
  # sensor config for the Kailua HDK profile.
  REG_CONF="${SHARE}/thor/sensors/sns_reg.conf"
  if [[ ! -s "${REG}/sh5001_0_platform.config" ]]; then
    soc="$(tr -d '\0\r\n ' </sys/devices/soc0/soc_id 2>/dev/null || true)"
    t="$(mktemp -d "${S}/registry.new.XXXXXX")"
    "${P}/bin/sscregistrygen" -p HDK -s "${soc:-603}" "${SHARE}/thor/sensors/config" "$t"
    [[ -s "$t/sh5001_0_platform.config" && -s "$t/sh5001_0_platform.orient" ]] ||
      { rm -rf "$t"; echo "sscregistrygen made no SH5001 profile" >&2; exit 1; }
    cp -a "$t/." "${REG}/"; rm -rf "$t"
  fi
else
  # Odin 2 family (LSM6DSV): the ADSP's sensor registry lives on the
  # persist partition (stock Android).
  REG_CONF="${SHARE}/odin2/sensors/sns_reg.conf"
  if [[ ! -s "${REG}/lsm6dsv_0_platform.config" ]]; then
    m="$(mktemp -d)"
    mount -t ext4 -o ro,noload /dev/disk/by-partlabel/persist "$m"
    cp -a "$m/sensors/registry/registry/." "${REG}/" || true
    umount "$m"; rmdir "$m"
  fi
fi
ln -snf "${SHARE}/thor/sensors/config" "${R}/sensors/config"
ln -snf "${REG_CONF}" "${R}/sensors/sns_reg.conf"
ln -snf "${REG}" "${R}/sensors/registry"
v="$(sed -n 's/^version=//p' "${REG_CONF}" | head -1)"
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
