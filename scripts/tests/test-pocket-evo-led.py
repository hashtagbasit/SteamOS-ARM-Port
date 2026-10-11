#!/usr/bin/env python3
"""Protocol fixtures and pseudo-terminal integration; no handheld required."""
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / 'sm8550-overlay/usr/lib/pocketevo/pocket_evo_led.py'
PLUGIN = REPO / 'external-and-mods/Decky/sm8650/konkr-control/main.py'


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


led = module(SOURCE, 'pocket_evo_led')


class Protocol(unittest.TestCase):
    def test_stock_packet_fixtures(self):
        # Independently transcribed register sequence from supplied gamewindow
        # APK's UtilsKt; checksum fixtures verified with sum modulo 256.
        self.assertEqual(led.static_frame((255, 0, 0), 64).hex(),
                         'f7001c2001800081008b0f88ff89008a0086408740580245009eed')
        self.assertEqual(led.off_frame().hex(), 'f7001c200000000000000000000000000000000000000000003ced')
        self.assertEqual(led.follow_frame((255, 0, 0), (0, 0, 255), 64).hex(),
                         'f755400000ffff000093ed')

    def test_brightness_zero_and_animation_bounds(self):
        for mode in set(led.MODES) - {'google'}:
            cfg = led.normalize({'mode': mode, 'brightness': 0})
            self.assertEqual(led.frame_at(cfg, 1), led.off_frame())
        for mode in ('breath', 'rgb-cycle'):
            cfg = led.normalize({'mode': mode, 'brightness': 80})
            frames = [led.frame_at(cfg, t / 20) for t in range(300)]
            self.assertGreater(len(set(frames)), 10)
            for frame in frames:
                self.assertEqual(len(frame), 27)
                self.assertLessEqual(frame[18], 80)
                self.assertEqual(frame[18], frame[20])
                self.assertEqual(frame[-2], sum(frame[1:-2]) & 255)

    def test_google_uses_native_chroma_command(self):
        # startBreathGoogle's non-AR14 branch: byte 1 = FF, rest zero,
        # sum bytes 1..8 = FF. It is not a 27-byte solid-colour packet.
        for brightness in (0, 64, 255):
            cfg = led.normalize({'mode': 'google', 'brightness': brightness})
            for t in (0, 0.5, 5.24, 40):
                self.assertEqual(led.frame_at(cfg, t).hex(), 'f7ff00000000000000ffed')

    def test_android_breath_timing_and_rgb_palette(self):
        single = led.normalize({'mode': 'breath', 'brightness': 255})
        rgb = led.normalize({'mode': 'rgb-cycle', 'brightness': 255})
        for t, bright in ((0, 255), (1, 131), (2.1, 7), (2.4, 7),
                          (3.52, 131), (4.6, 255), (5.1, 255)):
            self.assertAlmostEqual(led.frame_at(single, t)[18], bright, delta=1)
        expected = [(255, 0, 255), (0, 255, 0), (0, 0, 255), (255, 0, 0),
                    (0, 255, 0), (0, 0, 255), (255, 255, 0), (255, 0, 255)]
        for cycle, color in enumerate(expected):
            for offset in (0.1, 1, 2.1, 3.5, 4.9):
                frame = led.frame_at(rgb, cycle * 5.24 + offset)
                self.assertEqual(tuple(frame[i] for i in (12, 14, 16)), color)
        self.assertEqual(led.frame_at(rgb, 2.1)[18], 255)
        self.assertEqual(led.frame_at(rgb, 5.1)[18], 2)
        fast = {**single, 'speed': 2}
        self.assertEqual(led.frame_at(fast, 0.5), led.frame_at(single, 1))

    def test_default_and_static_have_independent_customization(self):
        saved = led.presets({'rgb': {'mode': 'static', 'color': '123456', 'brightness': 42},
                             'rgb_presets': {'default': {'color': 'abcdef', 'brightness': 99}}})
        self.assertEqual(saved['static']['color'], '123456')
        self.assertEqual(saved['default']['color'], 'abcdef')
        self.assertEqual(led.frame_at(saved['default'], 0), led.static_frame((171, 205, 239), 99))
        self.assertEqual(led.mode_defaults('default')['color'], 'ffffff')
        self.assertEqual(saved['breath']['color'], '00ff00')
        self.assertEqual(saved['follow']['color'], 'eb00ff')

    def test_validation(self):
        for cfg in ({'mode': 'flash-firmware'}, {'color': 'oops'}, {'brightness': -1},
                    {'brightness': 256}, {'brightness': True}, {'speed': float('nan')},
                    {'speed': 0}, {'secondary_color': None}, []):
            with self.subTest(cfg=cfg), self.assertRaises(ValueError):
                led.normalize(cfg)
        self.assertEqual(led.normalize({'color': '#AABBCC'})['color'], 'aabbcc')

    def test_model_guard(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'model'
            with patch.object(led, 'MODEL', path):
                for name in ('AYN Odin 2', 'AYANEO Pocket S', 'AYANEO Pocket EVO clone'):
                    path.write_text(name + '\0')
                    self.assertFalse(led.supported())
                path.write_text('AYANEO Pocket EVO\0')
                self.assertTrue(led.supported())


class SerialIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.master, self.slave = pty.openpty()
        self.port = os.ttyname(self.slave)
        self.packets = []
        self.running = True
        self.reply = True
        self.worker = threading.Thread(target=self.emulate, daemon=True)
        self.worker.start()
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.running = False
        self.worker.join(timeout=1)
        os.close(self.master)
        os.close(self.slave)
        self.temp.cleanup()

    def emulate(self):
        buf = bytearray()
        while self.running:
            if not select.select([self.master], [], [], 0.05)[0]:
                continue
            buf.extend(os.read(self.master, 4096))
            while len(buf) >= 3:
                if buf[0] != 0xf7:
                    del buf[0]
                    continue
                size = 27 if buf[:3] == b'\xf7\x00\x1c' else 11
                if len(buf) < size:
                    break
                packet = bytes(buf[:size])
                del buf[:size]
                self.packets.append(packet)
                if packet == led.INIT and self.reply:
                    # A split reply exercises stream buffering, not a single
                    # read() that happens to return a complete MCU message.
                    os.write(self.master, b'\xf7\x55')
                    time.sleep(0.005)
                    os.write(self.master, b'\xaa\x21')

    def wait_for(self, check, timeout=4):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            if check():
                return
            time.sleep(0.02)
        self.fail('Timed out waiting for emulated serial event')

    def test_handshake_repetition_and_timeout(self):
        link = led.SerialLink(self.port, self.root / 'lock', timeout=0.08)
        self.assertEqual(link.initialize(), 'f755aa21')
        frame = led.static_frame((12, 34, 56), 78)
        link.send(frame, repeats=3)
        self.wait_for(lambda: self.packets.count(frame) == 3)
        self.reply = False
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            link.initialize()
        self.assertLess(time.monotonic() - started, 0.8)

    def test_sleep_guard_prevents_old_frame(self):
        link = led.SerialLink(self.port, self.root / 'lock')
        sleep = self.root / 'sleep'
        sleep.touch()
        with patch.object(led, 'SLEEP', sleep):
            link.send(led.static_frame((255, 0, 0), 50), repeats=3)
            link.send(led.off_frame(), repeats=3, allow_sleep=True)
        self.wait_for(lambda: len(self.packets) >= 3)
        self.assertEqual(self.packets, [led.off_frame()] * 3)

    def test_daemon_restores_settings_and_blanks_on_exit(self):
        state = self.root / 'state.json'
        runtime = self.root / 'runtime'
        runtime.mkdir()
        cfg = {'mode': 'static', 'color': '123456', 'brightness': 78}
        state.write_text(json.dumps({'rgb': cfg}))
        code = '''
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('led', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = Path(sys.argv[2]); m.RUNTIME = root / 'runtime'
m.STATE = root / 'state.json'; m.SLEEP = m.RUNTIME / 'sleep'
m.STANDBY = root / 'standby'
real_link = m.SerialLink
m.SerialLink = lambda: real_link(sys.argv[3], m.RUNTIME / 'serial.lock', timeout=0.1)
m.run()
'''
        proc = subprocess.Popen([sys.executable, '-c', code, str(SOURCE), str(self.root), self.port],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def stop():
            if proc.poll() is None:
                proc.terminate()
            proc.communicate(timeout=3)
        self.addCleanup(stop)
        frame = led.static_frame((0x12, 0x34, 0x56), 78)
        self.wait_for(lambda: self.packets.count(frame) == 3)
        for marker in (runtime / 'sleep', self.root / 'standby'):
            marker.touch()
            self.wait_for(lambda: self.packets[-1] == led.off_frame())
            count = len(self.packets)
            time.sleep(0.3)
            self.assertTrue(all(p == led.off_frame() for p in self.packets[count:]))
            marker.unlink()
            self.wait_for(lambda: self.packets[-1] == frame)
        # Native Google is issued once (three stock retries), then left running.
        (self.root / 'state.json').write_text(json.dumps({'rgb': {'mode': 'google'}}))
        self.wait_for(lambda: self.packets.count(led.GOOGLE_FRAME) == 3)
        count = len(self.packets)
        time.sleep(0.3)
        self.assertEqual(len(self.packets), count)
        (runtime / 'sleep').touch()
        self.wait_for(lambda: self.packets[-1] == led.off_frame())
        (runtime / 'sleep').unlink()
        self.wait_for(lambda: self.packets.count(led.GOOGLE_FRAME) == 6)
        self.assertGreaterEqual(self.packets.count(led.INIT), 3)
        status = json.loads((runtime / 'status.json').read_text())
        self.assertTrue(status['ready'])
        proc.terminate()
        out, err = proc.communicate(timeout=3)
        self.assertEqual(proc.returncode, 0, out + err)
        self.wait_for(lambda: self.packets[-1] == led.off_frame())


class PluginAndInstall(unittest.TestCase):
    def test_api_keeps_extra_settings_and_old_device_contract(self):
        with patch.dict(sys.modules, {'decky': types.ModuleType('decky'), 'pocket_evo_led': led}):
            plugin = module(PLUGIN, 'evo_plugin_test')
        st = {'rgb': {'mode': 'follow', 'color': 'ff0000', 'brightness': 64,
                      'secondary_color': '00ff00', 'speed': 2}}
        with patch.object(plugin, 'load', return_value=st), patch.object(plugin, 'save') as save, \
                patch.object(plugin, 'evo_rgb_supported', return_value=True), \
                patch.dict(sys.modules, {'pocket_evo_led': led}):
            result = asyncio.run(plugin.Plugin().set_rgb('breath', '0000ff', 0))
            self.assertEqual(result['secondary_color'], '00ff00')
            self.assertEqual(result['speed'], 2)
            self.assertEqual(result['brightness'], 0)
            save.assert_called_once()
            self.assertEqual(st['rgb_presets']['follow']['color'], 'ff0000')
            self.assertEqual(st['rgb_presets']['follow']['secondary_color'], '00ff00')
            self.assertEqual(st['rgb_presets']['breath']['brightness'], 0)
            self.assertEqual(st['rgb_presets']['default']['color'], 'ffffff')
            # Persisted presets survive loading JSON in a fresh session.
            restored = led.presets(json.loads(json.dumps(st)))
            self.assertEqual(restored['follow']['brightness'], 64)
            self.assertEqual(restored['breath']['brightness'], 0)
            with self.assertRaises(ValueError):
                asyncio.run(plugin.Plugin().set_rgb('unsafe', '0000ff', 64))
        with patch.object(plugin, 'load', return_value=st), patch.object(plugin, 'save'), \
                patch.object(plugin, 'evo_rgb_supported', return_value=False):
            self.assertEqual(asyncio.run(plugin.Plugin().set_rgb('static', '#AABBCC', 999)),
                             {'mode': 'static', 'color': 'aabbcc', 'brightness': 255})

    @unittest.skipUnless(sys.platform == 'linux', 'installer uses GNU install -D')
    def test_installer_enables_root_and_persistent_etc(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'etc').mkdir()
            old_helper = root / 'usr/lib/konkr/pocket_evo_led.py'
            old_helper.parent.mkdir(parents=True)
            old_helper.write_text('old location')
            (root / 'var/lib/overlays/etc/upper').mkdir(parents=True)
            for _ in range(2):
                subprocess.run(['bash', str(REPO / 'scripts/install-pocket-evo-led.sh'), tmp], check=True)
            for etc in ('etc', 'var/lib/overlays/etc/upper'):
                self.assertTrue((root / etc / 'systemd/system/multi-user.target.wants/pocket-evo-led.service').is_symlink())
                self.assertTrue((root / etc / 'systemd/system/sleep.target.wants/pocket-evo-led-sleep.service').is_symlink())
            self.assertEqual((root / 'usr/lib/pocketevo/pocket_evo_led.py').read_bytes(), SOURCE.read_bytes())
            self.assertFalse(old_helper.exists())
            for unit in ('pocket-evo-led.service', 'pocket-evo-led-sleep.service'):
                text = (root / 'usr/lib/systemd/system' / unit).read_text()
                self.assertIn('/usr/lib/pocketevo/pocket_evo_led.py', text)
                self.assertNotIn('/usr/lib/konkr/', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
