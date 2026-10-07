#!/usr/bin/env bash
# Install the AYN Odin 2 family gyro stack into a SteamOS rootfs:
# hexagonrpcd (ADSP sensor hub listeners), qcom-motion (SSC -> DSU :26760)
# and qcom-sdl-pad (motion-only DualSense that InputPlumber merges into the pad).
# Everything goes under /usr/lib/qcom-gyro; the units skip devices that
# aren't an Odin 2 / Mini / Portal. Needs the gyro kernel (fastrpc SensorsPD).
# The binaries are built from source by build-qcom-gyro-in-rootfs.sh (run here
# when the rootfs doesn't have them yet).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
R="${1:-${ROOT}/rootfs}"
SRC="${ROOT}/external-and-mods/kernel/vendor/qcom-gyro"
ST="${SRC}/steamos"
G="${R}/usr/lib/qcom-gyro"

log() { printf '==> [qcom-gyro] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "${R}/usr" ]] || die "not a rootfs: ${R}"
# Rebuild when the sources or the build script change.
stamp="$( (cat "${SCRIPT_DIR}/build-qcom-gyro-in-rootfs.sh"
  find "${SRC}/src" -type f -print0 | sort -z | xargs -0 cat) | sha256sum | cut -d' ' -f1)"
if [[ "$(cat "${G}/.build-stamp" 2>/dev/null)" != "${stamp}" ]]; then
  "${SCRIPT_DIR}/build-qcom-gyro-in-rootfs.sh" "${R}"
  printf '%s\n' "${stamp}" >"${G}/.build-stamp"
fi

log "Installing into ${G}"
rm -rf "${G}/share-qcom"
cp -r --no-preserve=mode,ownership "${SRC}/share-qcom" "${G}/"
install -m0755 "${ST}/qcom-sensors-start.sh" "${ST}/supported" "${G}/"

install -d -m0755 "${R}/usr/lib/systemd/system/multi-user.target.wants"
for u in qcom-sensors qcom-motion qcom-imu-pad; do
  install -m0644 "${ST}/${u}.service" "${R}/usr/lib/systemd/system/${u}.service"
  ln -sfn "../${u}.service" "${R}/usr/lib/systemd/system/multi-user.target.wants/${u}.service"
done
