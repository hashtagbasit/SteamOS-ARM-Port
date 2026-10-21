#!/usr/bin/env bash
# Headless Steam ARM seed bootstrapper for aarch64.
#
# Runs Steam in a headless Xvfb container using the upstream extracted
# SteamOS rootfs via bubblewrap (bwrap). This lets the native ARM64 Steam
# bootstrapper download the latest official client packages from Valve's CDN,
# unpack them, and generate a complete, sanitized steam-arm-seed.
#
# Usage:
#   bootstrap-steam-arm-seed.sh <ROOTFS_DIR> <OUTPUT_DIR> [CHANNEL]
#
set -euo pipefail

ROOTFS="${1:?Usage: $0 <ROOTFS_DIR> <OUTPUT_DIR> [CHANNEL]}"
OUTPUT_DIR="${2:?Usage: $0 <ROOTFS_DIR> <OUTPUT_DIR> [CHANNEL]}"
CHANNEL="${3:-${STEAM_ARM_CHANNEL:-steamdeck_publicbeta}}"

HERE="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"

log() { printf '==> [steam-seed-bootstrap] %s\n' "$*"; }
die() { printf 'ERROR: [steam-seed-bootstrap] %s\n' "$*" >&2; exit 1; }

# Architecture validation
ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" ]]; then
  if ! command -v qemu-aarch64-static >/dev/null 2>&1 && [ ! -f /proc/sys/fs/binfmt_misc/aarch64 ]; then
    die "Host architecture is ${ARCH}. Headless bootstrap requires aarch64 (or qemu-user-static with binfmt_misc)."
  fi
fi

[[ -d "${ROOTFS}" ]] || die "Rootfs directory not found: ${ROOTFS}"
[[ -f "${ROOTFS}/usr/lib/steam/steam.tar.zst" ]] || die "Missing ${ROOTFS}/usr/lib/steam/steam.tar.zst"
[[ -x "${ROOTFS}/usr/bin/Xvfb" ]] || die "Missing ${ROOTFS}/usr/bin/Xvfb in rootfs"

command -v bwrap >/dev/null 2>&1 || die "bwrap (bubblewrap) is required. Install with: sudo apt-get install -y bubblewrap"

# Check if target already has a complete Steam client
if "${HERE}/install-complete-steam-client.sh" --check "${OUTPUT_DIR}" 2>/dev/null; then
  log "Target directory already contains a complete Steam client: ${OUTPUT_DIR}"
  exit 0
fi

log "Preparing bootstrap staging directory at ${OUTPUT_DIR} (channel: ${CHANNEL})"
mkdir -p "${OUTPUT_DIR}/logs" "${OUTPUT_DIR}/package"

# Unpack baseline Steam archive from rootfs if steam binary is not present
if [[ ! -x "${OUTPUT_DIR}/steamrtarm64/steam" ]]; then
  log "Extracting upstream steam.tar.zst into ${OUTPUT_DIR}..."
  tar -xf "${ROOTFS}/usr/lib/steam/steam.tar.zst" --zstd -C "${OUTPUT_DIR}"
fi

# Ensure package/ directory and beta channel configuration
echo "${CHANNEL}" > "${OUTPUT_DIR}/package/beta"

# Ensure host permissions so container user (uid 1000) can read/write
chmod -R u+rwX "${OUTPUT_DIR}"

# Ensure /etc/resolv.conf exists in rootfs so bwrap can mount or use it
if [[ -f /etc/resolv.conf && ! -f "${ROOTFS}/etc/resolv.conf" ]]; then
  if [[ -w "${ROOTFS}/etc" ]]; then
    cp -L /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp -L /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
  fi
fi

# Write runner script to be executed inside bwrap
RUNNER_SCRIPT="${OUTPUT_DIR}/.bootstrap-runner.sh"
cat <<'EOF' > "${RUNNER_SCRIPT}"
#!/bin/bash
set -euo pipefail

CHANNEL="$1"
STEAM_DIR="/home/steamos/.local/share/Steam"
cd "${STEAM_DIR}"
mkdir -p "${STEAM_DIR}/logs"

# Set up ~/.steam directory and symlinks expected by Steam binary
mkdir -p /home/steamos/.steam
ln -sfn "${STEAM_DIR}" /home/steamos/.steam/steam
ln -sfn "${STEAM_DIR}" /home/steamos/.steam/root
mkdir -p "${STEAM_DIR}/linux32" "${STEAM_DIR}/linux64" "${STEAM_DIR}/steamrtarm64" "${STEAM_DIR}/ubuntu12_32" "${STEAM_DIR}/ubuntu12_64"
ln -sfn "${STEAM_DIR}/linux32" /home/steamos/.steam/sdk32
ln -sfn "${STEAM_DIR}/linux64" /home/steamos/.steam/sdk64
ln -sfn "${STEAM_DIR}/steamrtarm64" /home/steamos/.steam/sdkarm64
ln -sfn "${STEAM_DIR}/steamrtarm64" /home/steamos/.steam/binarm64
ln -sfn "${STEAM_DIR}/ubuntu12_32" /home/steamos/.steam/bin32
ln -sfn "${STEAM_DIR}/ubuntu12_64" /home/steamos/.steam/bin64

echo "==> [container] Starting Xvfb on display :99..."
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
/usr/bin/Xvfb :99 -screen 0 1280x800x24 -nolisten tcp -ac >"${STEAM_DIR}/logs/xvfb.log" 2>&1 &
XVFB_PID=$!

XVFB_READY=0
for i in $(seq 1 50); do
  if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "==> [container] ERROR: Xvfb process died unexpectedly!"
    cat "${STEAM_DIR}/logs/xvfb.log" 2>/dev/null || true
    exit 1
  fi
  if [ -S /tmp/.X11-unix/X99 ]; then
    XVFB_READY=1
    break
  fi
  sleep 0.2
done

if [ "$XVFB_READY" -ne 1 ]; then
  echo "==> [container] ERROR: Xvfb display socket /tmp/.X11-unix/X99 not ready after 10s!"
  cat "${STEAM_DIR}/logs/xvfb.log" 2>/dev/null || true
  exit 1
fi

export DISPLAY=:99

cleanup() {
  echo "==> [container] Cleaning up background processes..."
  kill -TERM "$XVFB_PID" 2>/dev/null || true
  wait "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> [container] Launching Steam bootstrap (channel: ${CHANNEL})..."
# Pass -no-child-update-ui to avoid OpenGL requirement during update
./steamrtarm64/steam -steamdeck -clientbeta "${CHANNEL}" -no-child-update-ui -exitsteam >"${STEAM_DIR}/logs/steam_bootstrap.log" 2>&1 &
STEAM_PID=$!

INSTALLED_GLOB="${STEAM_DIR}/package/steam_client_*_linuxarm64.installed"

MAX_WAIT_SECONDS=300
ELAPSED=0
SUCCESS=0

while [ "$ELAPSED" -lt "$MAX_WAIT_SECONDS" ]; do
  if compgen -G "$INSTALLED_GLOB" >/dev/null; then
    echo "==> [container] Detected installed manifest!"
    SUCCESS=1
    sleep 5
    break
  fi

  if ! kill -0 "$STEAM_PID" 2>/dev/null; then
    wait "$STEAM_PID" || true
    if compgen -G "$INSTALLED_GLOB" >/dev/null; then
      echo "==> [container] Steam finished update and exited!"
      SUCCESS=1
      break
    fi
    echo "==> [container] Steam process exited before manifest was written."
    break
  fi

  sleep 3
  ELAPSED=$((ELAPSED + 3))
  if [ $((ELAPSED % 15)) -eq 0 ]; then
    echo "==> [container] Bootstrapping in progress... (${ELAPSED}s / ${MAX_WAIT_SECONDS}s)"
    if [ -f "${STEAM_DIR}/logs/steam_bootstrap.log" ]; then
      tail -n 5 "${STEAM_DIR}/logs/steam_bootstrap.log" | sed 's/^/    /' 2>/dev/null || true
    fi
  fi
done

if kill -0 "$STEAM_PID" 2>/dev/null; then
  echo "==> [container] Stopping Steam..."
  kill -TERM "$STEAM_PID" 2>/dev/null || true
  sleep 2
  kill -KILL "$STEAM_PID" 2>/dev/null || true
fi

if [ "$SUCCESS" -ne 1 ]; then
  echo "==> [container] ERROR: Bootstrap did not complete within ${MAX_WAIT_SECONDS}s"
  if [ -f "${STEAM_DIR}/logs/xvfb.log" ]; then
    echo "=== xvfb.log ==="
    cat "${STEAM_DIR}/logs/xvfb.log"
  fi
  if [ -f "${STEAM_DIR}/logs/steam_bootstrap.log" ]; then
    echo "=== steam_bootstrap.log ==="
    cat "${STEAM_DIR}/logs/steam_bootstrap.log"
  fi
  if [ -f "${STEAM_DIR}/logs/bootstrap_log.txt" ]; then
    echo "=== bootstrap_log.txt ==="
    cat "${STEAM_DIR}/logs/bootstrap_log.txt"
  fi
  exit 1
fi

echo "==> [container] Bootstrap completed successfully!"
exit 0
EOF
chmod +x "${RUNNER_SCRIPT}"

log "Running Steam bootstrap inside Bubblewrap sandbox..."
BWRAP_ARGS=(
  bwrap
  --ro-bind "${ROOTFS}" /
  --dev /dev
  --proc /proc
  --tmpfs /tmp
  --tmpfs /run
  --tmpfs /home
  --dir /home/steamos
  --dir /home/steamos/.local
  --dir /home/steamos/.local/share
  --bind "${OUTPUT_DIR}" /home/steamos/.local/share/Steam
  --share-net
  --uid 1000 --gid 1000
  --setenv HOME /home/steamos
  --setenv USER steamos
  --setenv PATH /usr/local/bin:/usr/bin:/bin
  --chdir /home/steamos/.local/share/Steam
)

# Bind host resolv.conf if destination exists in rootfs
if [[ -f /etc/resolv.conf && -f "${ROOTFS}/etc/resolv.conf" ]]; then
  BWRAP_ARGS+=(--ro-bind /etc/resolv.conf /etc/resolv.conf)
fi

"${BWRAP_ARGS[@]}" /bin/bash /home/steamos/.local/share/Steam/.bootstrap-runner.sh "${CHANNEL}"

rm -f "${OUTPUT_DIR}/.bootstrap-runner.sh"

log "Sanitizing bootstrapped client data..."
"${HERE}/install-complete-steam-client.sh" --sanitize "${OUTPUT_DIR}"

if ! "${HERE}/install-complete-steam-client.sh" --check "${OUTPUT_DIR}"; then
  die "Seed verification failed after bootstrap in ${OUTPUT_DIR}"
fi

log "Steam ARM seed successfully bootstrapped at ${OUTPUT_DIR} ($(du -sh "${OUTPUT_DIR}" | awk '{print $1}'))"
