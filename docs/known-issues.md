# Known issues

## 8 Gen 3 (KONKR Pocket FIT, AYANEO Pocket S2)

- **Games flicker below 1080p** (picture jumps between full screen and the top-left corner). Fixed by the [v1.2.1 hotfix](https://github.com/hashtagbasit/SteamOS-ARM-Port/releases/tag/v1.2.1), and built into v1.3.

## 8 Gen 2 (beta)

- Nobody has booted this on real hardware yet, that's what the beta is for.
- No internal storage installer yet, SD card only.

## 8 Elite / SM8750 (AYN Odin 3)

- **Device powers off immediately after the "Ayn" splash screen:**
  - **Cause:** Kernel compiled with older GCC (< 15) or Binutils (< 2.45), such as default Ubuntu 24.04 toolchains. Binutils 2.42 lacks AArch64 relative relocations (`CONFIG_RELR`), and older compilers produce relocation tables that fault on Qualcomm Oryon CPU cores in `arch/arm64/kernel/head.S`, tripping the PMIC hardware watchdog.
  - **Fix:** Compile the kernel using GCC 15+ and GNU ld 2.45+ in a Fedora 43 container (`build-container.sh` or `build-gcc15.sh`), ensuring `CONFIG_RELR=y`. All official releases and CI builds (`build-kernel-sm8750.yml`) use this container environment.

If something else breaks for you, [open an issue](https://github.com/hashtagbasit/SteamOS-ARM-Port/issues) and say which device you have.
