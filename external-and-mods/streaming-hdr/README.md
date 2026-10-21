# Portal HDR streaming

This is an optional SDL override for the AYN Odin 2 Portal's existing Box64
streaming setup. It does not replace Steam's libraries or enable Box64.
It needs the P010-capable VA-API/GBM build and the Gamescope WSI and Portal
display-profile changes in this tree.

The SDL patch accepts the Portal's ARGB ten-bit Vulkan surface and reports HDR
display metadata only while Gamescope HDR is active on the internal panel.
The peak comes from the Portal's factory profile; SDR white comes from
Gamescope's current setting. This is not a measurement of physical brightness.

## Build and install

Build SDL on **x86-64 Ubuntu 24.04**, not on the ARM image. Install its build
dependencies first:

```sh
sudo apt-get install build-essential cmake ninja-build pkg-config curl patch python3 \
  libasound2-dev libpulse-dev libpipewire-0.3-dev \
  libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev \
  libxfixes-dev libxss-dev libxtst-dev libxkbcommon-dev \
  libdrm-dev libudev-dev libdbus-1-dev \
  libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev \
  libwayland-dev wayland-protocols libdecor-0-dev
OUT=/work/streaming-hdr-build bash scripts/build-streaming-hdr-component.sh
```

Copy the output directory to the image-building host and set
`STREAMING_HDR_BUILD` to it when running either overlay installer. Without a
bundle, the installer reports that HDR client installation was skipped.
An explicitly supplied missing or corrupt bundle fails the image build.
The standalone installer also accepts a rootfs argument:

```sh
STREAMING_HDR_BUILD=/work/streaming-hdr-build \
  bash scripts/install-streaming-hdr.sh /work/rootfs
```

Build Gamescope from the updated sources, including the WSI layer. The
ARM64 Ubuntu 24.04 recipe in `scripts/build-gamescope-component.sh` pins the
tested dependencies; its `OUT` directory is compatible with `GAMESCOPE_BUILD`
in the overlay installers. It requires the Gamescope development dependencies,
GCC/G++ 14, Meson, Ninja, CMake, rsync, Python Jinja2/pyparsing and LuaJIT.

## Runtime

At each stream launch the helper checks the board, stock Steam SDL fingerprint,
packaged SDL checksum and a real AV1 P010 VA-API config. An incompatible runtime
uses stock SDL and reports the reason in `streaming_client_box64.log`.
Create `.no-hdr-box64` in the Steam directory to disable the override.

Host HDR currently needs **Custom / enabled**. **Match client** did not negotiate
ten-bit video in the tested setup. Hardware AV1/P010 with an HDR10 swapchain and
the stock-SDL AV1/NV12 fallback were exercised on a Portal. Native ARM Steam HDR
negotiation, 4:4:4 and Android-equivalent brightness are not established by these
checks.
