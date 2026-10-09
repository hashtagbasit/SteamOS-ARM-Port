# Building

## Building the SteamOS Image

The top-level build scripts assemble the complete flashable `.img` (downloading Valve's official SteamOS rootfs, applying device-specific overlays, Mesa GPU drivers, and the repacked kernel):

- **AYN Odin 3 (Snapdragon 8 Elite / SM8750):** `./make-steamos-sm8750.sh`
- **KONKR Pocket FIT / AYANEO Pocket S2 (SM8650):** `./make-steamos-sm8650.sh`
- **Odin 2 family (SM8550):** `SOC=sm8550 ./make-steamos-sm8650.sh`
- **REDMAGIC 6 (SM8350):** `./make-steamos-sm8350.sh` (fastboot kit; see [redmagic6.md](redmagic6.md))

### Odin 3 (SM8750) Build Options

```bash
# Full build (downloads official rootfs, applies overlays, builds image):
./make-steamos-sm8750.sh

# Incremental repack (reuses existing rootfs & overlays; repacks .img):
./make-steamos-sm8750.sh --image-only
```

#### Key Environment Variables:
- `STEAM_ARM_SEED=sm8750-work/steam-arm-seed`: Pre-seeds the complete Steam client so the device first-boots directly to the login screen instead of downloading 2.5 GB on a black screen. On aarch64 hosts and in CI, this is automatically bootstrapped from the upstream rootfs if absent.
- `MESA_STACK=sm8750-work/mesa-stack`: Required for Adreno 830 OpenGL (via zink) and Vulkan.
- `SM8750_KERNEL=source`: Uses the from-source SteamOS kernel (enabling `CONFIG_TRACEFS=y` for mangoapp and performance overlays). If a kernel is already staged in `sm8750-work/kernel-sm8750-src/output/current`, the build script automatically prefers it.

---

## Compiling the SM8750 (8 Elite) Kernel

The SM8750 uses Qualcomm's custom ARMv9.2-A **Oryon** CPU cores.

### ⚠️ Critical Toolchain Requirement (GCC 15+ / Binutils 2.45+)
- Linux 7.2 on Oryon cores **requires** modern toolchain support for packed relative relocations (`CONFIG_RELR=y`, `--pack-dyn-relocs=relr`).
- **Do not compile using older compilers (like GCC 13 on Ubuntu 24.04).** Older toolchains lack RELR support and generate relocation tables that crash immediately during early kernel initialization (`arch/arm64/kernel/head.S`), triggering an instant PMIC watchdog reboot.
- The build script enforces `gcc >= 15` for SM8750 builds.

### Building via Container (Recommended)

To guarantee the exact GCC 15 + Binutils 2.45 toolchain on any Linux host (native ARM64, Colima, or Docker):

```bash
# Build SM8750 kernel inside the tested Fedora 43 container:
./external-and-mods/kernel-sm8750/build-container.sh
```

Or invoke the generic container runner:
```bash
bash external-and-mods/kernel-common/build-gcc15.sh sm8750
```

The output kernel, modules, and firmware are staged into `kernel-work/output/<release>/` (or `$WORK/output/<release>/`), with a `current` symlink pointing to the latest build.

### Building in GitHub Actions CI
- `.github/workflows/build-kernel-sm8750.yml` runs inside the official `fedora:43` container on an ARM64 runner (`ubuntu-24.04-arm`).
- It produces the `kernel-sm8750` artifact containing `boot/KERNEL`, `modules/`, and firmware.
- `.github/workflows/build-image-sm8750.yml` can consume this artifact directly by setting `kernel_source: source`.

---

## Other Components
- **Gamescope:** `scripts/build-gamescope-in-rootfs.sh`, source in `external-and-mods/gamescope/`
- **Mesa (Freedreno / Turnip):** `scripts/build-mesa.sh` (builds aarch64, x86_64, i386 FEX guest, and Android slices)

Valve's official rootfs and the Steam client are downloaded at build time. See [HOW-IT-WORKS.md](HOW-IT-WORKS.md) for architectural details.
