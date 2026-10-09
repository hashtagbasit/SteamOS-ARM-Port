# Gyro userspace sources

Built from source by `scripts/build-qcom-gyro-in-rootfs.sh` inside the SteamOS
rootfs and installed to `/usr/lib/qcom-gyro` (licenses in
`/usr/share/licenses/qcom-gyro`).

| Component | Upstream | Commit | License | Notes |
|---|---|---|---|---|
| qrtr (`libqrtr`, `qrtr-lookup`) | https://github.com/linux-msm/qrtr | `b51ffaf22707b6000ecfb894c5b750f3bb7843b2` (v1.2) | BSD-3-Clause | |
| libqrtr-glib | https://gitlab.freedesktop.org/mobile-broadband/libqrtr-glib | `8991f0e93713ebf4da48ae4f23940ead42f64c8c` (1.2.2) | LGPL-2.1-or-later | |
| libqmi (`libqmi-glib` only) | https://gitlab.freedesktop.org/mobile-broadband/libqmi | `defb13dcab0adc7f44f6741807244507a14a30c5` (1.36.0) | LGPL-2.1-or-later | no MBIM, udev, tools |
| libssc | https://codeberg.org/DylanVanAssche/libssc | `3befde3ef215bdb78c4a48aa72c99cd458c2aed0` | GPL-3.0-or-later | + `src/libssc/*.patch` |
| hexagonrpc (`hexagonrpcd`, `libhexagonrpc`) | https://github.com/linux-msm/hexagonrpc | `dd9ac70c026e1bad93e8cffa3801255b8ceb551e` | GPL-3.0-or-later | + `src/hexagonrpc/*.patch` |
| qcom-motion | `src/batocera-qcom-motion` (Batocera) | this repo | GPL-3.0-or-later AND Apache-2.0 | DSU code from gCemuhook |
| qcom-sdl-pad | `src/qcom-sdl-pad` (Batocera) | this repo | GPL-3.0-or-later AND Apache-2.0 | DualSense blobs from inputtino |
| protobuf-c (`protoc-gen-c`, build only) | https://github.com/protobuf-c/protobuf-c | `8c201f6e47a53feaab773922a743091eb6c8972a` (v1.5.0) | BSD-2-Clause | not installed |

protoc-gen-c is built because the rootfs's protobuf-c package ships one
linked against an older abseil than the rootfs has, so it doesn't run.
