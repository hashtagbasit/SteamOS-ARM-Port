# AYN Thor / Odin 2 — gyroscope (kernel layer)

Thor (SH5001) and Odin 2 (LSM6DSV) expose accelerometer and gyroscope via
**Qualcomm Sensor Core** on the ADSP. This kernel tree delivers the
**kernel + firmware layer**. Userspace lives in the monorepo:

`vendor/masi-motion/` → `sudo ./scripts/install-masi-motion.sh`

## Kernel vs userspace

| Layer | Location | What |
|-------|----------|------|
| **Kernel/DTB** | `boot/KERNEL` (`./make.sh`) | FastRPC SensorsPD, PDR routing, DT gyro, `CONFIG_UHID=y` |
| **Firmware** | `firmware/qcom/sm8550/ayn/thor/` | ADSP split `.mdt` (Thor SH5001); Odin 2 `adsp.mbn` intact |
| **Userspace** | `vendor/masi-motion/` | SSC + uinput IMU + InputPlumber deck-uhid |

`update.sh` **only installs kernel + firmware + modules**. After reboot:

```bash
sudo ./update.sh
sudo reboot
# userspace:
sudo ./scripts/install-masi-motion.sh
```

## Patches / overlays in this tree

- `patches/masi/1025-misc-fastrpc-adsp-sensor-pd-and-legacy-ioctl.patch`
- `patches/masi/1026-dt-bindings-misc-qcom-fastrpc-pd-routing.patch`
- `patches/masi/qcs8550-ayn-gyro-fastrpc.dtsi.frag` — remote heap + SensorsPD (all AYN SM8550)
- `patches/masi/qcs8550-ayn-thor-gyro-fastrpc-pd.dtsi.frag` — `qcom,pd-type` on Thor only
- `lib/gyro-firmware.sh` — Thor ADSP overlay in `firmware/`
- `vendor/qcom-gyro/firmware-thor-adsp/` — Thor ADSP blobs
- `config/golden.config` — `CONFIG_UHID=y` (required for virtual Deck/DualSense userspace pads)

## Thor vs Odin 2

| Device | IMU | DT note |
|--------|-----|---------|
| **Thor** | Senodia SH5001 | `qcom,pd-type` on FastRPC |
| **Odin 2** | ST LSM6DSV | no forced pd-type (first-free banks) |

## Userspace (`vendor/masi-motion`)

Gaming Mode uses **InputPlumber + deck-uhid** (not a second virtual pad).
Odin 2 look frame is locked as **`odin2-dsu-v9`** `(X, -Z, -Y)` in `qcom-motion`.

```bash
sudo ./scripts/install-masi-motion.sh
# or: cd vendor/masi-motion && sudo ./install.sh
```

**New images:** `finalize-handheld-rootfs.sh` installs masi-motion into the rootfs and the default AYN composite includes the IMU.

Includes qrtr/hexagonrpcd/libssc and `qcom-motion` (uinput Sunshine whitelist name +
optional DSU `:26760`). InputPlumber merges rsinput gamepad + IMU into one
`deck-uhid` device for Steam.

Details: `vendor/masi-motion/README.md`

## Known kernel-layer limitations

- Odin 2 needs the Android `persist` partition for factory calibration (consumed by userspace).
- The stack waits for the handheld ALSA card before opening FastRPC (ADSP is shared with audio).
- In DT, **`qcom,pd-type` is Thor-only**. Forcing it in common prevented SSC from publishing on Odin 2.
- Install Image + modules from the **same** build (full `./update.sh`). Image-only `make Image` can black-screen.

## SteamOS, 7.2.8 kernel (Odin 2 / Portal / Thor)

Kernel (`external-and-mods/kernel-sm8550`):

- `patches/0052-misc-fastrpc-adsp-sensors-pd-for-gyro.patch`: FastRPC remote
  heap + SensorsPD routing for the ADSP sensors, rebased onto 7.2.8. The
  SensorsPD part only runs with `qcom,fastrpc-adsp-sensors-pdr` in the DT.
- `dts/qcs8550-ayn-odin2-gyro.dtsi`, included from the Odin 2 / Mini / Portal
  dts appends (not the shared common dtsi): `adsp_rpc_remote_heap_mem` and the
  `qcom,fastrpc-adsp-sensors-pdr` / `qcom,vmids` fastrpc properties. Without
  them dmesg says `no reserved DMA memory for FASTRPC` and the SSC service
  (QRTR 400) never shows up.
- `dts/qcs8550-ayn-thor-gyro.dtsi`, included from the Thor dts append: the
  same Odin 2 gyro dtsi plus `qcom,pd-type` on ADSP context banks 3–7 (root,
  audio, sensors with 8 sessions, user, user). The Thor already boots its
  stock ADSP (`qcom/sm8550/ayn/thor/adsp.mbn`, which has the SH5001 driver).
- Builds on an x86_64 host too: `build-gcc15.sh` cross compiles in podman/docker
  (`DOCKER=podman`), e.g.
  `SM8550_RECIPE=7.2 MOUNT=… FRAME_FW_DIR=… BUSYBOX=… DOCKER=podman bash external-and-mods/kernel-common/build-gcc15.sh sm8550`.

Userspace (`vendor/qcom-gyro/steamos`, installed by
`scripts/install-qcom-gyro-sm8550.sh` into `/usr/lib/qcom-gyro`, state such as
the persist registry copy and calibration in `/var/lib/qcom-gyro`). The units
only run on `ayn,odin2`, `ayn,odin2mini`, `ayn,odin2portal` and `ayn,thor`
(`supported`). The binaries (hexagonrpcd, sscregistrygen, qrtr-lookup,
qcom-motion, qcom-sdl-pad and their libs) are built from source inside the
rootfs by `scripts/build-qcom-gyro-in-rootfs.sh`; upstreams, commits and licenses are in
`vendor/qcom-gyro/SOURCES.md`.

- `qcom-sensors.service` → `qcom-sensors-start.sh`: sets up the sensor
  registry in `/var/lib/qcom-gyro/state/registry` (only when it isn't there
  yet, it keeps the unit's learned calibration) and starts the hexagonrpcd
  SensorsPD + RootPD listeners. Odin 2 family: copied from the Android
  persist partition (read-only). Thor: there is none on persist, so
  `sscregistrygen -p HDK -s <soc_id>` generates the SH5001 one from
  `share-qcom/sm8550/AYN/thor/sensors/config`.
- `qcom-motion.service`: qcom-motion, DSU on :26760 (`--profile auto` picks
  `thor`, `portal` or `odin2` from the DT compatible). The Portal has
  its own `portal` profile: its IMU sits turned compared to the Odin 2
  (top, left and out of the screen are +X, +Y, +Z), and with the Odin 2 map
  tilting up/down moved the cursor sideways.
- `qcom-imu-pad.service`: `qcom-sdl-pad --motion-only`, a DualSense over uhid
  named "AYN Odin2 IMU" with idle buttons/sticks. Motion is sent in the units
  its calibration report declares (20 per deg/s, 10000 per G); it used to send
  1024 per deg/s, which Steam read about 51x too fast. The SM8550 InputPlumber
  composite takes it as a hidraw source, so gyro reaches targets that have one
  (deck-uhid, ds5-edge); the Thor's composite (`02-ayn-odin.yaml`) takes it
  the same way. InputPlumber skips virtual devices, so this needs
  `external-and-mods/InputPlumber/0003-manage-ayn-odin2-imu-uhid.patch`
  (tested on a Portal: the IMU hidraw joined the composite and got hidden).
- Back paddles (Portal M1/M2) already work through `gpio-keys-paddles` with
  any paddle target (xbox-elite, deck-uhid, ds5-edge); checked with real presses.

Status (Portal): gyro works in Steam Input (deck-uhid target) with this
kernel, the stock ADSP firmware and these units (checked: SSC on QRTR 400,
DSU on :26760, right directions and speed in Steam, audio fine).
Thor: not tested on hardware yet.

The listeners have to attach soon after "msm/adsp/sensor_pd is up". Started
by hand a minute or more after boot, SensorsPD still reads the registry and
config but SSC never registers, and only a reboot (or ADSP restart, which
breaks audio until reboot) brings it back. Starting at boot from
qcom-sensors.service (waits for the audio card, ~10 s) is in time.
