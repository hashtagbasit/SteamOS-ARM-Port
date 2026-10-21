#!/usr/bin/env bash
# Build on an ARM64 Ubuntu 24.04 host; OUT can be used as GAMESCOPE_BUILD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/external-and-mods/gamescope"
OUT="$(realpath -m "${OUT:?output directory required}")"
WORK="$(mktemp -d)"
# Pinned dependency sources for the vendored wlroots 0.20 API.
UPSTREAM_REF=aa289ea5977d8b21b92b0f246f0e8f0c225d180f

git init -q "$WORK/upstream"
git -C "$WORK/upstream" fetch -q --depth 1 https://github.com/ValveSoftware/gamescope.git "$UPSTREAM_REF"
git -C "$WORK/upstream" checkout -q FETCH_HEAD
git -C "$WORK/upstream" submodule update -q --init --depth 1 \
    subprojects/wlroots subprojects/libliftoff subprojects/vkroots subprojects/libdisplay-info
# The vendored WSI layer uses this vkroots API, not the newer compositor snapshot's API.
git -C "$WORK/upstream/subprojects/vkroots" fetch -q --depth 1 origin \
    5106d8a0df95de66cc58dc1ea37e69c99afc9540
git -C "$WORK/upstream/subprojects/vkroots" checkout -q FETCH_HEAD
mkdir "$WORK/src"
rsync -a --exclude=.git --exclude=subprojects/ "$SRC/" "$WORK/src/"
rsync -a --exclude=.git "$WORK/upstream/subprojects/" "$WORK/src/subprojects/"
dependency() {
    local name="$1" url="$2" revision="$3" provides="$4"
    printf '[wrap-git]\nurl = %s\nrevision = %s\ndepth = 1\n[provide]\ndependency_names = %s\n' \
        "$url" "$revision" "$provides" > "$WORK/src/subprojects/$name.wrap"
}
# Keep build headers within the API versions available on the handheld image.
dependency wayland https://gitlab.freedesktop.org/wayland/wayland.git \
    736d12ac67c20c60dc406dc49bb06be878501f86 wayland-client,wayland-server,wayland-scanner
dependency wayland-protocols https://gitlab.freedesktop.org/wayland/wayland-protocols.git \
    88223018d1b578d0d8869866da66d9608e05f928 wayland-protocols
dependency libdrm https://gitlab.freedesktop.org/mesa/drm.git \
    a8e5e10a873f67f557dc70e5407af4553f35edd9 libdrm
dependency libxkbcommon https://github.com/xkbcommon/libxkbcommon.git \
    b3465081878e80ca6c11fe35c81787ec374ec15a xkbcommon
dependency pixman https://gitlab.freedesktop.org/pixman/pixman.git \
    9cc163c9da0fb4da430641715313d95a6ec466d9 pixman-1

luajit "$WORK/src/tests/ayn.odin2.portal.lua" \
    "$WORK/src/scripts/00-gamescope/displays/ayn.odin2.portal.lua"
meson setup "$WORK/build" "$WORK/src" \
    --prefix=/usr/local --buildtype=release \
    -Dpipewire=enabled -Dinput_emulation=enabled -Dbenchmark=disabled \
    -Denable_openvr_support=false -Denable_gamescope_wsi_layer=true \
    -Dwayland:documentation=false -Dwayland:tests=false \
    -Dlibdrm:auto_features=disabled -Dlibdrm:tests=false \
    -Dlibxkbcommon:enable-tools=false -Dlibxkbcommon:enable-x11=false \
    -Dlibxkbcommon:enable-docs=false -Dlibxkbcommon:enable-xkbregistry=false \
    --force-fallback-for=wlroots,libliftoff,vkroots,wayland,wayland-protocols,libdrm,libxkbcommon,pixman
meson compile -C "$WORK/build" -j 2
meson test -C "$WORK/build" --print-errorlogs --suite gamescope
meson install -C "$WORK/build" --no-rebuild --destdir "$WORK/install"

for binary in gamescope gamescopectl gamescopereaper gamescopestream; do
    install -Dm755 "$WORK/build/src/$binary" "$OUT/src/$binary"
done
cp -a "$WORK/install/usr/local/share/gamescope/scripts" "$OUT/scripts"
install -Dm755 "$WORK/build/layer/libVkLayer_FROG_gamescope_wsi_aarch64.so" \
    "$OUT/layer/libVkLayer_FROG_gamescope_wsi_aarch64.so"
python3 - "$WORK/build/layer/VkLayer_FROG_gamescope_wsi.aarch64.json" "$OUT/layer" <<'PY'
import json, sys
from pathlib import Path
manifest = json.loads(Path(sys.argv[1]).read_text())
manifest["layer"]["library_path"] = "/usr/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so"
(Path(sys.argv[2]) / "VkLayer_FROG_gamescope_wsi.aarch64.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
