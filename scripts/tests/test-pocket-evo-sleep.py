#!/usr/bin/env python3
"""Run sleep/wake policies with fake network commands and temporary sysfs.

No device, user state or SD-card writes. Run: python3 scripts/tests/test-pocket-evo-sleep.py
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
WIFI = REPO / 'steamos-overlay/usr/lib/steamos-arm/steamos-arm-wifi-wake'
SLEEP = REPO / 'sm8650-overlay/usr/lib/konkr/konkr-sleep'


def fake_tool():
    tool = Path(sys.argv[2]).name
    args = sys.argv[3:]
    root = Path(os.environ['EVO_TEST_ROOT'])
    with (root / 'calls').open('a') as out:
        out.write(json.dumps([tool, *args]) + '\n')
    if tool == 'timeout':
        return subprocess.call(args[1:])
    if tool in ('iw', 'sleep'):
        return 0
    if tool == 'nmcli':
        if 'GENERAL.STATE' in args:
            print('100 (connected)')
        elif args[-2:] == ['radio', 'wifi']:
            print('enabled')
        return 0
    return 0


class SleepPolicies(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='evo-policy-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        command = f'exec {shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))} --fake-tool "$0" "$@"\n'
        for name in ['timeout', 'iw', 'nmcli', 'sleep']:
            p = self.bin / name
            p.write_text('#!/bin/sh\n' + command)
            p.chmod(0o755)
        self.env = dict(os.environ, EVO_TEST_ROOT=str(self.root),
                        EVO_TEST_BIN=str(self.bin),
                        XDG_STATE_HOME=str(self.root / 'state'),
                        PATH=str(self.bin) + ':' + os.environ['PATH'])

    def calls(self):
        p = self.root / 'calls'
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def test_wifi_watch_scans_known_channel_without_radio_reset(self):
        mark = self.root / 'wifi-mark'
        mark.touch()
        last = self.root / 'wifi-last'
        last.write_text('5180\nTest network\n')
        source = WIFI.read_text().replace('/run/konkr/wifi-was-connected', str(mark))
        source = source.replace('/run/konkr/wifi-last', str(last))
        result = subprocess.run(['bash', '-c', source, 'wifi-wake', 'watch'],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(mark.exists())
        calls = self.calls()
        self.assertIn(['iw', 'dev', 'wlan0', 'scan', 'trigger', 'freq', '5180', 'ssid', 'Test network'], calls)
        self.assertIn(['timeout', '3', 'nmcli', '-w', '2', '-t', '-g', 'GENERAL.STATE', 'device', 'show', 'wlan0'], calls)
        self.assertFalse(any('off' in c for c in calls))

    def test_post_restores_wifi_before_scan_without_mutating_sysfs(self):
        # Use real post/step control flow with mock hardware functions. Both
        # the full SM8550 path and the existing light path must start a watch.
        source = SLEEP.read_text().split('\ncase "${1:-}" in', 1)[0]
        source = source.replace('/sys/module/', str(self.root / 'modules') + '/')
        for is_light in (0, 1):
            mock = '''
report_end() { :; }
sleep_debug() { :; }
ufs_on() { echo ufs; }
light() { return LIGHT_RESULT; }
touch_on() { echo touch; }
modprobe() { echo reload; }
timeout() { shift; "$@"; }
wifi_watch_start() { echo scan; }
audio() { echo audio; }
systemctl() { :; }
post
'''.replace('LIGHT_RESULT', str(is_light))
            result = subprocess.run(['bash', '-c', source + '\n' + mock],
                                    env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            events = result.stdout.splitlines()
            self.assertIn('scan', events)
            self.assertLess(events.index('ufs'), events.index('scan'))
            if is_light == 1:  # shell exit 1 => full preparation
                self.assertLess(events.index('reload'), events.index('scan'))

    def ufs_fixture(self, compatible):
        dt = self.root / 'compatible'
        dt.write_bytes(b'\0'.join(c.encode() for c in compatible) + b'\0')
        driver = self.root / 'ufshcd-qcom'
        host = driver / '1d84000.ufshc'
        host.mkdir(parents=True)
        for path in (driver / 'bind', driver / 'unbind', host / 'clkscale_enable'):
            path.write_text('untouched\n')
        state = self.root / 'ufs-unbound'
        source = SLEEP.read_text().split('\ncase "${1:-}" in', 1)[0]
        source = source.replace('/proc/device-tree/compatible', str(dt))
        source = source.replace('/sys/bus/platform/drivers/ufshcd-qcom', str(driver))
        source = source.replace('/run/konkr/ufs-unbound', str(state))
        source = source.replace('/sys/module/', str(self.root / 'modules') + '/')
        return source, driver, state

    def test_evo_pre_post_leave_ufs_bound_and_restore_other_devices(self):
        source, driver, state = self.ufs_fixture(
            ['ayaneo,pocketevo', 'qcom,qcs8550', 'qcom,sm8550'])
        # Exercise the full pre/post path. UFS use detection must not even
        # run: the board policy applies to both SD and internal installs.
        mock = '''
report_start() { :; }
report_end() { :; }
sleep_debug() { :; }
sync() { :; }
wifi_mark() { :; }
wake_sources() { :; }
touch_off() { echo 0; }
touch_on() { echo touch-restored; }
audio() { echo audio-$1; }
modprobe() { echo wifi-restored; }
timeout() { shift; "$@"; }
wifi_watch_start() { echo scan; }
systemctl() { :; }
ufs_in_use() { echo unexpected-ufs-probe >&2; return 1; }
pre
post
'''
        result = subprocess.run(['bash', '-c', source + '\n' + mock],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(state.exists())
        for path in (driver / 'bind', driver / 'unbind',
                     driver / '1d84000.ufshc/clkscale_enable'):
            self.assertEqual(path.read_text(), 'untouched\n')
        self.assertNotIn('unexpected-ufs-probe', result.stderr)
        self.assertIn('stage=ufs_off end rc=0', result.stderr)
        self.assertIn('stage=ufs_on end rc=0', result.stderr)
        events = result.stdout.splitlines()
        self.assertIn('touch-restored', events)
        self.assertIn('audio-0', events)
        self.assertLess(events.index('wifi-restored'), events.index('scan'))

    def test_other_boards_keep_ufs_detach_and_rebind(self):
        # Same GPU/SoC is insufficient to opt a different board out; the
        # Pocket FIT workaround also remains intact on SM8650.
        for compatible in (['ayn,odin2', 'qcom,sm8550'],
                           ['konkr,pocketfit', 'qcom,sm8650']):
            with self.subTest(compatible=compatible), tempfile.TemporaryDirectory() as d:
                saved_root, self.root = self.root, Path(d)
                try:
                    source, driver, state = self.ufs_fixture(compatible)
                    result = subprocess.run(
                        ['bash', '-c', source + '\nufs_in_use() { return 1; }; ufs_off; ufs_on'],
                        env=self.env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((driver / 'unbind').read_text(), '1d84000.ufshc\n')
                    self.assertEqual((driver / 'bind').read_text(), '1d84000.ufshc\n')
                    self.assertEqual((driver / '1d84000.ufshc/clkscale_enable').read_text(), '0\n')
                    self.assertFalse(state.exists())
                finally:
                    self.root = saved_root


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--fake-tool':
        raise SystemExit(fake_tool())
    unittest.main()
