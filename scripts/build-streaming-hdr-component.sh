#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(realpath -m "${OUT:?output directory required}")"
WORK="${WORK:-$(mktemp -d)}"
SDL_REVISION=ab5541ec5d4377dcc20a701897437f07ba71566f
STEAM_SDL_SHA256=08eb7ba02ec862b062d9876f00ffd6deb58f5b1fc9f2325bcf90e6245586b2de
PROFILE="$ROOT/external-and-mods/gamescope/scripts/00-gamescope/displays/ayn.odin2.portal.lua"
PEAK="$(python3 - "$PROFILE" <<'PY'
from pathlib import Path
import re, sys
values = re.findall(r"^\s*max_content_light_level = ([0-9.]+),$", Path(sys.argv[1]).read_text(), re.M)
assert len(values) == 1 and 0 < float(values[0]) < 10000, "Invalid Portal peak luminance"
print(values[0])
PY
)"
mkdir -p "$WORK/src" "$OUT"
curl --fail --location --silent --show-error \
    "https://codeload.github.com/libsdl-org/SDL/tar.gz/$SDL_REVISION" -o "$WORK/sdl.tar.gz"
tar -xzf "$WORK/sdl.tar.gz" -C "$WORK/src" --strip-components=1
patch --batch --fuzz=0 -p1 -d "$WORK/src" < "$ROOT/external-and-mods/streaming-hdr/sdl.patch"
install -m644 "$ROOT/external-and-mods/streaming-hdr/portal_hdr.h" "$WORK/src/src/video/x11/portal_hdr.h"
python3 "$ROOT/scripts/test-sdl-hdr.py" "$WORK/src" "$PEAK"
cmake -S "$WORK/src" -B "$WORK/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_C_FLAGS=-DSTEAMOS_PORTAL_PEAK_NITS=${PEAK}f" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_X11=ON -DSDL_VULKAN=ON -DSDL_PULSEAUDIO=ON
cmake --build "$WORK/build" --parallel 4
readelf -h "$WORK/build/libSDL3.so.0" | grep -q 'Machine:.*X86-64'
install -m755 "$WORK/build/libSDL3.so.0" "$OUT/libSDL3.so.0"
install -m644 "$WORK/src/LICENSE.txt" "$OUT/LICENSE.txt"
python3 - "$OUT" "$SDL_REVISION" "$STEAM_SDL_SHA256" <<'PY'
import hashlib, json, sys
from pathlib import Path
out = Path(sys.argv[1])
manifest = {"sdl_revision": sys.argv[2], "steam_sdl_sha256": sys.argv[3],
            "libSDL3_sha256": hashlib.sha256((out / "libSDL3.so.0").read_bytes()).hexdigest()}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
