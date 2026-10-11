# Pocket EVO sleep/wake recovery

## Observed failure and board-specific fix

On an AYANEO Pocket EVO, a captured failed sleep attempt reached
`stage=ufs_off begin` after audio, touch and Wi-Fi preparation, with no matching
completion or kernel suspend entry. This identifies UFS preparation as the
blocking stage, but does not distinguish the clock-scaling write from driver
unbind. It does not establish a GPU resume failure.

Keep the UFS host bound on the exact `ayaneo,pocketevo` compatible and let the
kernel manage UFS suspend/resume. This applies to both SD and internal boots.
Other boards retain their existing detach/rebind workaround. A userspace
timeout cannot reliably recover an uninterruptible sysfs write.

## Related recovery changes

- Restore the Wi-Fi module before starting reconnect scans. Bound module reload,
  `iw` and `nmcli` calls, and use elapsed-time reconnect deadlines.
- Update the UFS lane-clock and GENI serial PM patches from Armada.
- Import A740 GMU fixes that preserve polled response bits, bound coredump waits
  to two seconds, and mask HFI interrupts before GMU boot.
- Restore Renesas USB RAM firmware after suspend and disable PCI wake by default
  so that the controller can power down. Preserve PM guards and error handling.
- Record pre/post hook stages in the journal and, with `BOOT/debug` enabled,
  `BOOT/debug-logs/sleep-stages.txt`. Refresh runtime evidence during the existing
  performance capture period and retain release and pstore information.

Kernel patch authorship is retained. These six kernel patches are selected by
`SM8550_RECIPE=7.2`; the older 7.1 recipe continues to skip them.

## Validation and limits

Run `python3 scripts/tests/test-pocket-evo-sleep.py` for four hardware-free
regression tests. They exercise the real pre/post shell flow against temporary
sysfs files, verify that EVO UFS clock scaling/bind/unbind are untouched, check
restoration of other devices and Wi-Fi scan ordering, and preserve UFS detaching
for Odin 2 and Pocket FIT. Network commands are mocked; these tests do not
measure real reconnect timing or kernel power management.

The Pocket EVO owner reports that sleep/wake works on the rebuilt image with
these changes. That image also contains independent session/audio/build fixes;
this isolated PR has not been rebuilt and flashed separately. The captured
failure supports the UFS change directly, not attribution to each kernel patch.
No repeated-cycle count or battery-drain measurement is claimed. Other devices
still need hardware validation, especially USB peripheral recovery and wake.
