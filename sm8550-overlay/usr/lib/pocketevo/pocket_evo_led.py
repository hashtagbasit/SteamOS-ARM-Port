#!/usr/bin/env python3
"""Pocket EVO MCU lighting; protocol observations are in docs/pocket-evo-led.md.

Reads Handheld Control's saved RGB settings and sends lighting frames to the MCU.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import termios
import time
import tty

MODEL = Path('/sys/firmware/devicetree/base/model')
STATE = Path('/var/lib/konkrd/state.json')
RUNTIME = Path('/run/pocket-evo-led')
SLEEP = RUNTIME / 'sleep'
STANDBY = Path('/run/konkr-standby')
PORT = '/dev/ttyHS0'
MODES = ('default', 'static', 'breath', 'rgb-cycle', 'google', 'follow', 'off')
DEFAULT = {'mode': 'static', 'color': 'ff3c00', 'brightness': 160,
           'secondary_color': '0000ff', 'speed': 1.0}
INIT = bytes.fromhex('F7 00 00 00 00 00 00 00 00 00 ED')
GOOGLE_FRAME = bytes.fromhex('F7 FF 00 00 00 00 00 00 00 FF ED')
RGB_BREATH_COLORS = ((255, 0, 255), (0, 255, 0), (0, 0, 255),
                     (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0))


def supported() -> bool:
    try:
        return MODEL.read_text().strip('\0\n ') == 'AYANEO Pocket EVO'
    except OSError:
        return False


def normalize(cfg: dict) -> dict:
    """Validate the on-disk and API contract before producing any bytes."""
    if not isinstance(cfg, dict):
        raise ValueError('RGB settings must be an object')
    out = {**DEFAULT, **cfg}
    if out['mode'] not in MODES:
        raise ValueError('Unsupported Pocket EVO lighting mode')
    for key in ('color', 'secondary_color'):
        value = out[key]
        if not isinstance(value, str) or not re.fullmatch(r'#?[0-9a-fA-F]{6}', value):
            raise ValueError(f'{key} must contain six hexadecimal digits')
        out[key] = value.lstrip('#').lower()
    if isinstance(out['brightness'], bool) or not isinstance(out['brightness'], int):
        raise ValueError('Brightness must be an integer')
    if not 0 <= out['brightness'] <= 255:
        raise ValueError('Brightness must be between 0 and 255')
    if isinstance(out['speed'], bool) or not isinstance(out['speed'], (int, float)):
        raise ValueError('Speed must be a number')
    if not math.isfinite(out['speed']) or not 0.25 <= out['speed'] <= 3:
        raise ValueError('Speed must be between 0.25 and 3')
    return {k: out[k] for k in DEFAULT}


def color_rgb(color: str) -> tuple[int, int, int]:
    return tuple(int(color[i:i + 2], 16) for i in (0, 2, 4))


def registers(pairs) -> bytes:
    if len(pairs) > 11:
        raise ValueError('Too many LED registers')
    data = bytearray(27)
    data[:3] = b'\xf7\x00\x1c'
    for i, (address, value) in enumerate(pairs):
        data[3 + i * 2:5 + i * 2] = bytes((address, value))
    data[25] = sum(data[1:25]) & 255
    data[26] = 0xed
    return bytes(data)


def off_frame() -> bytes:
    return registers(((0x20, 0),))


def static_frame(rgb, brightness: int) -> bytes:
    r, g, b = rgb
    return registers(((0x20, 1), (0x80, 0), (0x81, 0), (0x8b, 15),
                      (0x88, r), (0x89, g), (0x8a, b),
                      (0x86, brightness), (0x87, brightness), (0x58, 2), (0x45, 0)))


def follow_frame(front, back, brightness: int) -> bytes:
    # Stock application orders background before foreground; these are not
    # left/right stick colours. The MCU implements joystick response itself.
    data = bytearray((0xf7, 0x55, brightness, *back, *front, 0, 0xed))
    data[9] = sum(data[1:9]) & 255
    return bytes(data)


def mode_defaults(mode: str) -> dict:
    if mode not in MODES:
        raise ValueError('Unsupported Pocket EVO lighting mode')
    color = '00ff00' if mode == 'breath' else 'eb00ff' if mode == 'follow' else 'ffffff'
    return {**DEFAULT, 'mode': mode, 'color': color, 'brightness': 255}


def presets(state: dict) -> dict:
    """Android keeps Default, Static, Single and Reactive settings separately."""
    saved = state.get('rgb_presets', {})
    saved = saved if isinstance(saved, dict) else {}
    result = {mode: mode_defaults(mode) for mode in MODES}
    for mode in MODES:
        if isinstance(saved.get(mode), dict):
            try:
                result[mode] = normalize({**saved[mode], 'mode': mode})
            except ValueError:
                pass
    current = state.get('rgb')
    if isinstance(current, dict):
        try:
            current = normalize(current)
            result[current['mode']] = current
        except ValueError:
            pass
    return result


def breath_scale(t: float, *, rgb: bool) -> float:
    # Android emits steps 0..100 every 20 ms (2.02 s), with 700 ms
    # at the peak and 500 ms at the floor. Single starts by fading down;
    # RGB starts by fading up and advances its colour only after a full breath.
    phase = t % 5.24
    if rgb:
        step = min(100, int(phase / 0.02)) if phase < 2.02 else (
            100 if phase < 2.72 else max(0, 100 - int((phase - 2.72) / 0.02)))
        floor = 0.01
    else:
        step = max(0, 100 - int(phase / 0.02)) if phase < 2.02 else (
            0 if phase < 2.52 else min(100, int((phase - 2.52) / 0.02)))
        floor = 0.03
    return floor + (1 - math.cos(step * math.pi / 100)) * (1 - floor) / 2


def frame_at(cfg: dict, elapsed: float) -> bytes:
    mode = cfg['mode']
    # Native MCU effect: do not overwrite it with solid-colour register frames.
    # The stock Google command exposes no brightness, colour or speed fields.
    if mode == 'google':
        return GOOGLE_FRAME
    brightness = cfg['brightness']
    if mode == 'off' or brightness == 0:
        return off_frame()
    rgb = color_rgb(cfg['color'])
    t = elapsed * cfg['speed']
    if mode == 'follow':
        return follow_frame(rgb, color_rgb(cfg['secondary_color']), brightness)
    if mode in ('breath', 'rgb-cycle'):
        brightness = int(brightness * breath_scale(t, rgb=mode == 'rgb-cycle'))
        if mode == 'rgb-cycle':
            rgb = RGB_BREATH_COLORS[int(t / 5.24) % len(RGB_BREATH_COLORS)]
    return static_frame(rgb, brightness)


class SerialLink:
    def __init__(self, port=PORT, lock=RUNTIME / 'serial.lock', timeout=0.25):
        self.port, self.lock, self.timeout = port, Path(lock), timeout

    @contextlib.contextmanager
    def opened(self):
        self.lock.parent.mkdir(parents=True, exist_ok=True)
        with self.lock.open('a') as lock:
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('LED serial port is busy')
                    time.sleep(0.01)
            fd = os.open(self.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            try:
                tty.setraw(fd, termios.TCSANOW)
                attrs = termios.tcgetattr(fd)
                attrs[2] = (attrs[2] & ~(termios.PARENB | termios.CSTOPB | termios.CSIZE |
                                       termios.HUPCL | getattr(termios, 'CRTSCTS', 0))) | termios.CS8 | termios.CREAD | termios.CLOCAL
                attrs[4] = attrs[5] = termios.B115200
                termios.tcsetattr(fd, termios.TCSANOW, attrs)
                yield fd
            finally:
                os.close(fd)

    def write(self, fd: int, packet: bytes) -> None:
        deadline = time.monotonic() + self.timeout
        view = memoryview(packet)
        while view:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([], [fd], [], left)[1]:
                raise TimeoutError('LED serial write timed out')
            try:
                count = os.write(fd, view)
            except BlockingIOError:
                continue
            if count == 0:
                raise OSError('LED serial port closed')
            view = view[count:]

    def initialize(self) -> str:
        with self.opened() as fd:
            termios.tcflush(fd, termios.TCIFLUSH)
            received = bytearray()
            for _ in range(3):
                self.write(fd, INIT)
                deadline = time.monotonic() + self.timeout
                while time.monotonic() < deadline:
                    if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                        break
                    chunk = os.read(fd, 256)
                    if not chunk:
                        raise OSError('LED serial port closed during initialization')
                    received.extend(chunk)
                    # Stock app accepts F7/E7 55 AA. Require the version byte
                    # too so a split reply is retained in the diagnostic status.
                    for prefix in (b'\xf7\x55\xaa', b'\xe7\x55\xaa'):
                        index = received.find(prefix)
                        if index >= 0 and len(received) >= index + 4:
                            return received[index:index + 4].hex()
                    received = received[-512:]
            raise TimeoutError('No Pocket EVO MCU reply to LED initialization')

    def send(self, packet: bytes, repeats=1, allow_sleep=False) -> None:
        with self.opened() as fd:
            for i in range(repeats):
                # Check inside the lock: a concurrent suspend helper can never
                # be followed by an old animation frame that relights the LEDs.
                if not allow_sleep and sleeping():
                    return
                if i:
                    time.sleep(0.04)
                self.write(fd, packet)


def sleeping() -> bool:
    return SLEEP.exists() or STANDBY.exists()


def status(**values) -> None:
    RUNTIME.mkdir(parents=True, exist_ok=True)
    payload = {'port': PORT, 'updated_at': time.time(), **values}
    temp = RUNTIME / 'status.tmp'
    temp.write_text(json.dumps(payload) + '\n')
    temp.replace(RUNTIME / 'status.json')


def run() -> None:
    stopping = False

    def stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    link = SerialLink()
    last = None
    previous_cfg = None
    initialized = False
    was_asleep = False
    reply = ''
    retry_at = 0.0
    started = time.monotonic()
    error = None
    status(ready=False, error='Waiting for LED controller')
    try:
        while not stopping:
            try:
                asleep = sleeping()
                if asleep:
                    if not was_asleep:
                        link.send(off_frame(), repeats=3, allow_sleep=True)
                        status(ready=initialized, sleeping=True, error=None, mcu_reply=reply)
                    was_asleep = True
                    initialized = False
                    last = None
                    time.sleep(0.1)
                    continue
                if was_asleep:
                    retry_at = 0
                    was_asleep = False
                if time.monotonic() < retry_at:
                    time.sleep(0.1)
                    continue
                if not initialized:
                    reply = link.initialize()
                    initialized = True
                    last = None
                try:
                    data = json.loads(STATE.read_text())
                except FileNotFoundError:
                    data = {}
                cfg = normalize(data.get('rgb', DEFAULT))
                if cfg != previous_cfg:
                    previous_cfg = cfg
                    started = time.monotonic()
                    last = None
                packet = frame_at(cfg, time.monotonic() - started)
                if packet != last:
                    link.send(packet, repeats=3 if last is None else 1)
                    if last is None or error:
                        status(ready=True, sleeping=False, error=None, mode=cfg['mode'], mcu_reply=reply)
                    last = packet
                error = None
                time.sleep(0.02 if cfg['mode'] in ('breath', 'rgb-cycle') else 0.2)
            except (OSError, termios.error, ValueError, TypeError, AttributeError) as exc:
                message = str(exc)
                if message != error:
                    print(f'pocket-evo-led: {message}', flush=True)
                    status(ready=False, error=message)
                error = message
                initialized = False
                retry_at = time.monotonic() + 5
                time.sleep(0.1)
    finally:
        try:
            link.send(off_frame(), repeats=3, allow_sleep=True)
        except (OSError, termios.error):
            pass
        status(ready=False, error='LED service stopped')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('run', 'supported', 'sleep', 'wake'))
    action = parser.parse_args().action
    if not supported():
        return 1 if action == 'supported' else 0
    if action == 'run':
        run()
    elif action == 'sleep':
        RUNTIME.mkdir(parents=True, exist_ok=True)
        SLEEP.touch()
        try:
            SerialLink().send(off_frame(), repeats=3, allow_sleep=True)
        except (OSError, termios.error) as exc:
            print(f'pocket-evo-led: sleep blanking: {exc}', flush=True)
    elif action == 'wake':
        SLEEP.unlink(missing_ok=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
