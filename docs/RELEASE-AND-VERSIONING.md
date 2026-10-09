# Release and Versioning Strategy — SteamOS ARM Handhelds

This document outlines the version management architecture, component upgrade lifecycles, and automated release pipeline for the SteamOS ARM handheld ports (AYN Odin 3 / SM8750).

---

## 1. Architectural Philosophy: Two-Tier Build Cadence

Building an unofficial SteamOS distribution involves both lightweight platform customizations and heavyweight binary toolchains. To keep CI fast, reproducible, and affordable, this project separates builds into two speeds:

```
┌─────────────────────────────────────────────────────────────────┐
│                    FAST TIER (Image Assembly)                   │
│  • Handheld overlays (gamescope-session, odin3d fan daemon)     │
│  • Controller profiles (InputPlumber deck-uhid mappings)        │
│  • Audio UCM profiles & session scripts                         │
│  • Cadence: Frequent (PRs, bugfixes, feature iterations)        │
│  • Build Duration: ~10 minutes                                  │
└───────────────────────────────┬─────────────────────────────────┘
                                │ Consumes pinned, pre-built assets
┌───────────────────────────────┴─────────────────────────────────┐
│                    SLOW TIER (Core Binary Stacks)               │
│  • Kernel: Linux 7.2.0 from source with tracefs enabled         │
│  • Graphics: Mesa 26.2.3 (Turnip + Zink, 4 cross-slices)        │
│  • Base OS: Valve Deckard SteamOS rootfs (casync chunk store)   │
│  • Steam Client: Pre-bootstrapped sanitized ARM user seed       │
│  • Cadence: Infrequent (upstream major version bumps)           │
│  • Build Duration: 20 to 90 minutes                             │
└─────────────────────────────────────────────────────────────────┘
```

By decoupling image assembly from recompiling the core stacks, everyday commits and PRs can build and test fresh `.img` files in ~10 minutes on GitHub Actions.

---

## 2. Global Version Manifest (`versions.env`)

All upstream dependency versions, image hashes, toolchain pins, and release tags are centralized in a single file at the root of the repository: [`versions.env`](../versions.env).

It defines:
- **Valve SteamOS Base:** Upstream rootfs build, bundle name, and CDN URL (`STEAMOS_BUILD`, `STEAMOS_BUNDLE`, `STEAMOS_URL`).
- **Mesa Graphics Stack:** Mesa release version, sha256 checksum, Android NDK version, and NDK sha1 (`MESA_VERSION`, `MESA_SHA256`, `NDK_VERSION`, `NDK_SHA1`).
- **Steam Client ARM Channel:** The beta channel bootstrapped in CI (`STEAM_ARM_CHANNEL`).
- **Kernel & Distribution Pins:** Pinned ROCKNIX release tag and kernel version (`ROCKNIX_REF`, `KVER`).

### How It Is Consumed
- **Bash Scripts (`make-steamos-*.sh`, `scripts/build-mesa.sh`):** Automatically source `versions.env` if present, while allowing local environment variables to override them.
- **GitHub Actions Workflows:** Exported directly to `$GITHUB_ENV` in initial workflow steps, ensuring every job operates on identical pins.

---

## 3. Component Upgrade Runbooks

### A. Upgrading the Valve SteamOS Base (`STEAMOS_BUILD`)
Valve periodically updates the SteamOS ARM rootfs for the Steam Frame on `steamdeck-images.steamos.cloud`.
1. Update `STEAMOS_BUILD` and `STEAMOS_BUNDLE` in `versions.env`.
2. Trigger `build-image-sm8750.yml` (or run `./make-steamos-sm8750.sh` locally).
3. The script automatically fetches the new `.raucb` bundle and reassembles the updated `rootfs.img` via casync.

### B. Upgrading the Mesa Graphics Stack (`MESA_VERSION`)
The Mesa stack requires four slices (`aarch64` native via rootfs bubblewrap, `x86_64` and `i386` cross-compiled for FEX, and `android` for Lepton):
1. Update `MESA_VERSION` and `MESA_SHA256` in `versions.env`.
2. Review/rebase patches in `external-and-mods/mesa/patches/` (such as Adreno 830 chip IDs).
3. Trigger the `.github/workflows/build-mesa-sm8750.yml` workflow via GitHub Actions `workflow_dispatch`.
4. Once verified, publish the resulting `mesa-sm8750.tar.zst` artifact to a release asset tag and update the pointer.

### C. Upgrading the Kernel & ROCKNIX Tree
The Odin 3 kernel is compiled from source with `CONFIG_FTRACE=y` (enabling tracefs for `mangoapp` and `steamos-manager`):
1. Update `ROCKNIX_REF` or `KVER` in `versions.env` and `external-and-mods/kernel-sm8750/soc.env`.
2. Trigger `.github/workflows/build-kernel-sm8750.yml` via `workflow_dispatch` on native `ubuntu-24.04-arm` runners.
3. The new kernel artifact is built in ~13 minutes.

### D. Upgrading / Refreshing the Steam ARM Seed
The Steam client runs in user space under `/home/steamos/.local/share/Steam/`.
- **Automated CI Generation:** The seed is automatically bootstrapped headlessly from upstream rootfs in CI (`build-image-sm8750.yml` on `ubuntu-24.04-arm` runners) via `scripts/bootstrap-steam-arm-seed.sh`.
- **Cached in GitHub Actions:** Cached with `@actions/cache` keyed on `steam-seed-${STEAMOS_BUILD}-${STEAM_ARM_CHANNEL}`, requiring **no** manual release uploads or external seed hosting.
- **Why it is stable:** The generated seed includes `steam.cfg` with `BootStrapperInhibitAll=enable`, preventing the client from breaking itself with incompatible x86 CDN self-updates on handheld boot.
- **When to update:** Only when you bump `STEAMOS_BUILD` or change `STEAM_ARM_CHANNEL` in `versions.env`. CI will automatically handle the cache miss, bootstrap the new client in ~1 minute, and cache the new seed.

---

## 4. Image Testing & Decoupled Release Promotion

To ensure quality and prevent non-booting images from reaching end users, image assembly and release publishing are strictly decoupled into a two-stage process:

```
┌────────────────────────────────────────────────────────┐
│  build-image-sm8750.yml (The Builder)                  │
│  • Trigger: workflow_dispatch (manual test builds)      │
│  • Output: steamos-odin3-image Actions artifact        │
│  • Safe to test any commit or overlay change           │
└──────────────────────────┬─────────────────────────────┘
                           │
                 1. Download & Flash to SD Card
                 2. Verify boot, controls, audio on Odin 3
                           │
┌──────────────────────────▼─────────────────────────────┐
│  release-sm8750.yml (The Promoter / Publisher)         │
│  • Trigger: workflow_dispatch                           │
│  • Inputs: image_run_id (tested build) + tag_name      │
│  • Action: Grabs tested artifact, attaches to Release   │
│  • Duration: ~30 seconds (zero rebuild drift!)         │
└────────────────────────────────────────────────────────┘
```

### Step 1: Building a Test Image (`build-image-sm8750.yml`)
1. Trigger the **Build Odin 3 (8 Elite) Image** workflow via `workflow_dispatch` on GitHub Actions.
2. The workflow compiles the rootfs and uploads the compressed image as a workflow artifact named `steamos-odin3-image` (containing `steamos-odin3.img.zst` and `.sha256`).
3. Download the artifact from the Actions run summary, flash to your micro-SD card:
   ```bash
   zstd -d steamos-odin3.img.zst -o steamos-odin3.img
   sudo dd if=steamos-odin3.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```
4. Verify hardware boot on the Odin 3 (DSI-1 display orientation, controls, audio, WiFi, and Steam login).

### Step 2: Promoting to Official Release (`release-sm8750.yml`)
Once the image is verified working on hardware:
1. Open the **Release Odin 3 (8 Elite)** workflow on GitHub Actions.
2. Provide:
   - **`tag_name`**: Must follow the maintainer's convention: `v*8elite*` (e.g. `v1.3-8elite-beta2` or `v1.4-8elite`).
   - **`image_run_id`**: The Actions run ID of the tested `build-image-sm8750` workflow (leave blank to promote the latest successful build).
   - **`prerelease`**: Checked by default for beta/preview handheld releases.
3. The workflow fetches the exact verified `.img.zst` artifact, generates checksums, and publishes the official GitHub Release in under 60 seconds without risk of rebuild divergence.

