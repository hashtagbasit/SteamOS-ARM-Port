# Pocket EVO joystick lighting

Pocket EVO support lives in SteamOS-ARM's existing **Handheld Control** Decky
plugin, under **Lighting**. The LED helper and its systemd units are sourced from
`sm8550-overlay`; the helper installs to `/usr/lib/pocketevo/pocket_evo_led.py`.
It uses a separate Python service to send LED frames
to the AYANEO MCU at `/dev/ttyHS0`, 115200 baud, 8N1. It activates only when the
device-tree model is exactly `AYANEO Pocket EVO`.

The effect list matches the stock Pocket EVO panel: **Default**, **Breath –
Single**, **Breath – RGB**, **Breath – Google**, **Static**, and **Reactive**,
plus **Off**. **Customize** opens settings, as on Android; it is not a seventh
MCU effect. Default and Static use the same solid-colour command but remember
separate colors and brightness. Factory presets are white (Default/Static),
green (Single), and magenta foreground/blue background (Reactive), at full
brightness. Existing saved settings are preserved.

Single and RGB breathing follow the stock 100-step cosine ramps at 20 ms per
step, with 700 ms at peak and 500 ms at minimum. Single starts fading down to
3%; RGB starts fading up from 1% and cycles magenta, green, blue, red, green,
blue, yellow, one complete breath per color. The default speed is 1x; the
optional speed control scales this timeline. Scheduler/UART overhead can differ
from Android's coroutine timing.

Google uses the MCU's native simultaneous multicolor ring animation. Its stock
command has no brightness, color or speed parameters; those controls are hidden
for Google. Select Off to turn it off. Reactive mode has foreground/background
colors, not separate left/right joystick colors.

Settings share `/var/lib/konkrd/state.json` with the existing plugin, with
per-effect values stored in `rgb_presets`. A dedicated sleep unit blanks the
LEDs for system sleep, and the daemon also observes the existing fake-standby
marker. Resume reinitializes the MCU and restores the selected effect.

## Protocol evidence

The implementation was independently written from observations of the supplied
stock APKs; no decompiled application source is included. APK SHA-256 values:

- `com.ayaneo.gamewindow`, version 1.5.66 (186):
  `20fdc4eff9baa84f6c62081a44b71dc573e0aa8e99dab22ca770a3bbfc260b77`
- `com.ayaneo.settings`, version 1.1.94 (129):
  `3921fb2e37fe6a6183c20ef52416c9ae61816e9e9e2fa13da60871920d545f0b`

`AyaDevicesUtilKt` identifies EVO as AR07, whose light configuration inherits
AR03 modes 0, 1, 2, 3, 6 and 7. The Android port is `dev/ttyHS4`; the built
mainline DTS aliases `hsuart0` to the controller's UART11 at `0x88c000`, exposed
as `/dev/ttyHS0`. `utils/rgb/UtilsKt`, `LightEffectController`, and
`ControllerSerialManagerKt` establish:

- Initialization: `F7 00 00 00 00 00 00 00 00 00 ED`.
  Accepted reply prefixes: `F7 55 AA` and `E7 55 AA`, followed by firmware version.
- Register frame: `F7 00 1C`, eleven address/value pairs, checksum, `ED`.
  Checksum is sum of bytes 1–24 modulo 256.
- Static pairs (hex): `20=01 80=00 81=00 8B=0F 88=R 89=G 8A=B
  86=brightness 87=brightness 58=02 45=00`.
- Off: `20=00`, remaining pairs zero.
- Reactive: `F7 55 brightness backR backG backB frontR frontG frontB checksum ED`.
  Checksum is sum of bytes 1–8 modulo 256.
- Google on EVO: `F7 FF 00 00 00 00 00 00 00 FF ED`, sent by
  `LightEffectController$startBreathGoogle$1`'s non-AR14 branch.
- `RgbCmdUtilAR03` routes Default and Static to the same constant-light command,
  with separately saved parameters. `RgbView` opens
  `ayaneo://settings/custom_rgb` for Customize. AR07 supports modes 0,1,2,3,6,7;
  scan/wave are not exposed by stock EVO.
- Stock setting changes repeat the frame three times, 40 ms apart.

The service requires the initialization reply before applying saved lighting.
Serial transactions have bounded timeouts and share a lock with the sleep helper.
The UI exposes connection errors instead of reporting saved settings as hardware
success. An initialization reply proves MCU communication, not visual LED output.

## Validation and hardware test

Run in Linux (the installer test requires GNU install):

```sh
python3 scripts/tests/test-pocket-evo-led.py
node --check external-and-mods/Decky/sm8650/konkr-control/dist/index.js
node scripts/tests/test-pocket-evo-led-ui.cjs
```

The LED tests cover known packet bytes (including native Google), stock breathing
timing/palette, separate customization, queued UI changes, split MCU
replies, missing replies, repeated writes, sleep guarding, a daemon with a
pseudo-terminal MCU, API compatibility and installation in both root and
persistent `/etc`. They do not establish physical LED behavior.

The user confirmed basic lighting control on the prior test image. The corrected
Google effect and Android-mode parity still need a new device test.

On the device, open Decky → Handheld Control → Lighting. Check static red/green/
blue, brightness including zero, each effect, reactive joystick movement, saved
settings after reboot, and blank/restore across sleep. This build still requires
that hardware test. If it fails, collect:

```sh
systemctl status pocket-evo-led.service pocket-evo-led-sleep.service --no-pager
journalctl -b -u pocket-evo-led.service -u pocket-evo-led-sleep.service --no-pager
cat /run/pocket-evo-led/status.json
cat /var/lib/konkrd/state.json
ls -l /dev/ttyHS*
```
