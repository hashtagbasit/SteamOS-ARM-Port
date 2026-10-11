# Pocket EVO sleep/wake isolation

Pocket EVO userspace recovery lives under
`sm8550-overlay/usr/lib/pocketevo/`: `pocket-evo-sleep` and
`pocket-evo-wifi-wake`. The original helpers in
`sm8650-overlay/usr/lib/konkr/konkr-sleep` and
`steamos-overlay/usr/lib/steamos-arm/steamos-arm-wifi-wake` are restored
byte-for-byte to upstream commit `4673fa6`.

The SM8550 overlay is installed on multiple SoCs. Its systemd drop-in keeps
the existing `konkr-sleep.service` lifecycle and s2idle ExecCondition, but
routes pre/post through the Pocket EVO dispatcher. Only the exact DT
compatible `ayaneo,pocketevo` selects the EVO implementation. Other boards,
including unknown or missing compatible values, exec the original helper
with unchanged arguments and exit status. Standby callers remain unchanged.

On EVO, UFS stays bound on SD and internal boots. Touch and Wi-Fi are
restored before reconnect scans, and debug sleep stages remain available.
Sleep report and Wi-Fi marker state use `/run/pocketevo`; the Wi-Fi helper
reads the existing daemon-owned `/run/konkr/wifi-last` channel information.
The reconnect worker uses its own `pocket-evo-wifi-wake` transient unit.

Full overlay builds and image repacks both call
`scripts/install-pocket-evo-sleep.sh`; repacks also restore the upstream
shared helpers so older test images do not retain the former shared patch.
The image manifest includes both EVO helpers and the systemd drop-in.

Validation: `python3 scripts/tests/test-pocket-evo-session.py` covers EVO
UFS preservation, Wi-Fi restoration ordering, other-board UFS behavior,
exact board dispatch, argument/exit-code forwarding, and rootfs installation.
The separate `kernel-pocketevo` recipe contains the UFS lane-clock, serial
suspend/resume, GPU recovery and Renesas USB resume patches. Generic SM8550
recipes retain their existing patches.

With `BOOT/debug` enabled, EVO captures sleep stages, runtime journals, audio
state and suspend statistics. Device testing must verify repeated power-button
sleep/wake, USB controller recovery, Wi-Fi reconnection and battery drain.
Local tests do not establish hardware sleep/wake reliability.
