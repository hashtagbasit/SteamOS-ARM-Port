#!/usr/bin/env python3
"""Decky backend — Handheld Control (SteamOS-ARM handhelds).

Thin front for the device daemon: konkrd (KONKR Pocket FIT, the 8 Gen 2
devices) or odin3d (AYN Odin 3, KONKR Pocket FIT Elite). Every setting lives
in the daemon's state.json, which it re-reads on SIGHUP, so the buttons,
konkrctl/odin3ctl, the bottom screen and this panel stay in sync.
"""
from __future__ import annotations

import asyncio
import glob
import json
import os
import subprocess
import sys
from typing import Any

import decky

ODIN3D = os.path.exists("/usr/lib/odin3/odin3d")
STATE = "/var/lib/odin3/state.json" if ODIN3D else "/var/lib/konkrd/state.json"
DAEMON = "odin3d" if ODIN3D else "konkrd"
BLACKLIST = "/etc/modprobe.d/konkr-mcu.conf"
PROFILES = ("silent", "balanced", "turbo")
ACTIONS = ("profile-next", "rgb-next", "sticks-toggle", "fan-boost", "game", "none")


def rd(path: str, default: str = "") -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return default


def evo_rgb_supported() -> bool:
    return (rd("/sys/firmware/devicetree/base/model").rstrip("\0") == "AYANEO Pocket EVO"
            and os.path.isfile("/usr/lib/pocketevo/pocket_evo_led.py"))


def evo_rgb_presets(state: dict) -> dict:
    if "/usr/lib/pocketevo" not in sys.path:
        sys.path.insert(0, "/usr/lib/pocketevo")
    from pocket_evo_led import presets
    return presets(state)


def evo_rgb_status() -> dict[str, Any]:
    try:
        value = json.loads(rd("/run/pocket-evo-led/status.json", "{}"))
        if not isinstance(value, dict):
            value = {}
    except ValueError:
        value = {}
    active = subprocess.run(["systemctl", "is-active", "--quiet", "pocket-evo-led.service"],
                            timeout=3).returncode == 0
    if not active:
        return {"ready": False, "error": "Pocket EVO LED service is not running"}
    return value or {"ready": False, "error": "Waiting for LED controller"}


def load() -> dict[str, Any]:
    try:
        with open(STATE, encoding="utf-8") as fh:
            st = json.load(fh)
    except (OSError, ValueError):
        st = {}
    st.setdefault("profile", "balanced")
    st.setdefault("rgb", {"mode": "static", "color": "ff3c00", "brightness": 160})
    st.setdefault("fan", {"mode": "auto", "fixed": 50, "boost": False})
    st.setdefault("power_led", True)
    st.setdefault("menu_clicks", True)
    st.setdefault("buttons", {"F13": "rgb-next", "F14": "profile-next"})
    return st


GAME_FILE = "/run/konkr/game.json"


def game_fan_state(st: dict[str, Any]) -> dict[str, Any]:
    """The game konkrd sees running (0 for none) and its fan choice."""
    try:
        appid = int(json.load(open(GAME_FILE, encoding="utf-8")).get("appid", 0))
    except (OSError, ValueError, TypeError):
        appid = 0
    entry = (st.get("fan_games") or {}).get(str(appid)) if appid else None
    if not entry:
        choice = "global"
    elif entry.get("mode") == "fixed":
        choice = f"fixed-{int(entry.get('fixed', 50))}"
    else:
        choice = entry.get("curve", "global")
    return {"appid": appid, "fan": choice}


def save(st: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(st, fh, indent=2)
    os.replace(STATE + ".tmp", STATE)
    subprocess.run(["systemctl", "kill", "-s", "HUP", f"{DAEMON}.service"], check=False)


def telemetry() -> dict[str, Any]:
    out: dict[str, Any] = {"fan_rpm": None, "fan_pwm": None, "gpu_mhz": None, "temp_c": None}
    for d in glob.glob("/sys/class/hwmon/hwmon*"):
        if rd(f"{d}/name") == "pwmfan":
            out["fan_rpm"] = int(rd(f"{d}/fan1_input", "0") or 0)
            out["fan_pwm"] = int(rd(f"{d}/pwm1", "0") or 0)
    for d in glob.glob("/sys/class/devfreq/*gpu*"):
        cur = rd(f"{d}/cur_freq")
        if cur.isdigit():
            out["gpu_mhz"] = int(cur) // 1_000_000
    temps = []
    for z in glob.glob("/sys/class/thermal/thermal_zone*"):
        if rd(f"{z}/type").startswith(("cpu", "gpu")):
            v = rd(f"{z}/temp")
            if v.lstrip("-").isdigit():
                temps.append(int(v) / 1000)
    if temps:
        out["temp_c"] = round(max(temps), 1)
    return out


# Bypass charging lives in steamos-arm-power (it also serves Steam's charge
# limit): plugged in, the battery holds and the device runs from the charger.
POWER = ["busctl", "--system", "--", "org.steamos_arm.Power", "/org/steamos_arm/Power", "org.steamos_arm.Power1"]


def bypass_state() -> dict[str, Any]:
    out: dict[str, Any] = {"supported": False, "on": False, "level": 55}
    for prop, key in (("BypassSupported", "supported"), ("BypassCharging", "on"), ("BypassLevel", "level")):
        r = subprocess.run(["busctl", "--system", "get-property", *POWER[3:], prop],
                           capture_output=True, text=True, timeout=5)
        if r.returncode != 0:
            return out
        val = r.stdout.split(maxsplit=1)[-1].strip()
        out[key] = (val == "true") if key != "level" else int(val)
    return out


def mode_of(st: dict[str, Any]) -> tuple[str, bool]:
    return st["profile"], bool(st["fan"].get("boost"))


class Plugin:
    async def _main(self) -> None:
        self.watcher = asyncio.create_task(self._watch_mode())
        decky.logger.info(f"Handheld Control ready ({DAEMON})")

    async def _unload(self) -> None:
        self.watcher.cancel()

    # The KONKR/Performance button goes straight to konkrd, so the frontend
    # would only see a change once the panel is opened. Watch konkrd's state
    # and tell the frontend, which shows a toast over whatever is running.
    async def _watch_mode(self) -> None:
        try:
            await self._watch_mode_loop()
        except asyncio.CancelledError:
            raise
        except Exception:
            decky.logger.exception("mode watcher stopped")

    async def _watch_mode_loop(self) -> None:
        stamp = None
        mode = mode_of(load())
        while True:
            await asyncio.sleep(0.25)
            try:
                cur = os.stat(STATE).st_mtime_ns
            except OSError:
                continue
            if cur == stamp:
                continue
            stamp = cur
            new = mode_of(load())
            if new != mode:
                old, mode = mode, new
                decky.logger.info(f"mode {old} -> {new}")
                await decky.emit("konkr_mode", new[0], new[1], old[0] != new[0])

    async def get_state(self, **_: Any) -> dict[str, Any]:
        st = load()
        model = rd("/sys/firmware/devicetree/base/model").rstrip("\0")
        leds = glob.glob("/sys/class/leds/*joysticks*") + glob.glob("/sys/class/leds/*-joystick") \
            + glob.glob("/sys/class/leds/rgb:[lr][0-9]") + glob.glob("/sys/class/leds/[lr]:r1")
        fit = model == "KONKR Pocket FIT"
        evo = evo_rgb_supported()
        return {
            "model": model,
            "daemon_name": DAEMON,
            "profile": st["profile"],
            "rgb": st["rgb"],
            "fan": st["fan"],
            "game": game_fan_state(st),
            "power_led": st["power_led"],
            "menu_clicks": st["menu_clicks"],
            "has_motors": any("HID_ID=0003:00004001:00000428" in rd(f"{d}/device/uevent")
                              for d in glob.glob("/sys/class/hidraw/hidraw*")),
            "buttons": st["buttons"],
            # What this device has, so the panel only shows what works here.
            "has_power_led": not ODIN3D and bool(glob.glob("/sys/class/leds/*power-led*")),
            "has_mcu_link": fit and not ODIN3D,
            "has_breath": evo or (not ODIN3D and any(os.path.exists(f"{d}/effect") for d in leds)),
            "evo_rgb": evo,
            "rgb_presets": evo_rgb_presets(st) if evo else {},
            "rgb_status": await asyncio.to_thread(evo_rgb_status) if evo else None,
            "fit_buttons": fit,
            "mcu_enabled": not os.path.exists(BLACKLIST),
            "mcu_loaded": os.path.isdir("/sys/module/konkr_sysbtn"),
            "sticks_led": bool(leds) or (evo and os.path.exists("/dev/ttyHS0")),
            "daemon": subprocess.run(["systemctl", "is-active", "--quiet", DAEMON]).returncode == 0,
            "bypass": await asyncio.to_thread(bypass_state),
            **await asyncio.to_thread(telemetry),
        }

    async def set_bypass(self, on: bool = False, **_: Any) -> dict[str, Any]:
        await asyncio.to_thread(subprocess.run, ["busctl", "--system", "set-property", *POWER[3:],
                                                 "BypassCharging", "b", "true" if on else "false"],
                                capture_output=True, timeout=5)
        return await asyncio.to_thread(bypass_state)

    async def set_profile(self, profile: str = "balanced", **_: Any) -> str:
        if profile not in PROFILES:
            return load()["profile"]
        st = load()
        st["profile"] = profile
        save(st)
        return profile

    async def set_rgb(self, mode: str = "static", color: str = "ff3c00", brightness: int = 160,
                      secondary_color: str | None = None, speed: float | None = None, **_: Any) -> dict:
        st = load()
        if evo_rgb_supported():
            if "/usr/lib/pocketevo" not in sys.path:
                sys.path.insert(0, "/usr/lib/pocketevo")
            from pocket_evo_led import normalize
            cfg = {**st["rgb"], "mode": mode, "color": color, "brightness": brightness}
            if secondary_color is not None:
                cfg["secondary_color"] = secondary_color
            if speed is not None:
                cfg["speed"] = speed
            validated = normalize(cfg)
            saved = evo_rgb_presets(st)
            saved[mode] = validated
            st["rgb_presets"] = saved
            st["rgb"] = validated
        else:
            st["rgb"] = {"mode": mode, "color": color.lstrip("#").lower()[:6],
                         "brightness": max(0, min(255, int(brightness)))}
        save(st)
        return st["rgb"]

    async def set_mcu(self, enabled: bool = False, **_: Any) -> bool:
        if enabled:
            if os.path.exists(BLACKLIST):
                os.remove(BLACKLIST)
            subprocess.run(["modprobe", "konkr_sysbtn"], check=False)
        else:
            with open(BLACKLIST, "w", encoding="utf-8") as fh:
                fh.write("# Pocket FIT MCU UART driver — opt-in (konkrctl mcu enable)\nblacklist konkr_sysbtn\n")
            subprocess.run(["modprobe", "-r", "konkr_sysbtn"], check=False)
        subprocess.run(["systemctl", "restart", "inputplumber.service"], check=False)
        return enabled

    async def set_fan(self, mode: str = "auto", fixed: int = 50, boost: bool = False, **_: Any) -> dict:
        st = load()
        st["fan"] = {"mode": "fixed" if mode == "fixed" else "auto",
                     "fixed": max(0, min(100, int(fixed))), "boost": bool(boost)}
        save(st)
        return st["fan"]

    async def set_game_fan(self, appid: int = 0, choice: str = "global", **_: Any) -> dict:
        """The running game's own fan setting: "global" (none), a curve
        ("silent", "balanced", "turbo") or "fixed-<percent>"."""
        appid = int(appid or 0)
        st = load()
        games = st.setdefault("fan_games", {})
        if not appid:
            return game_fan_state(st)
        if choice == "global":
            games.pop(str(appid), None)
        elif choice in ("silent", "balanced", "turbo"):
            games[str(appid)] = {"curve": choice}
        elif choice.startswith("fixed-") and choice[6:].isdigit():
            games[str(appid)] = {"mode": "fixed", "fixed": max(0, min(100, int(choice[6:])))}
        save(st)
        return game_fan_state(st)

    async def set_button(self, key: str = "F13", action: str = "none", **_: Any) -> dict:
        if key not in ("F13", "F14") or action not in ACTIONS:
            return load()["buttons"]
        st = load()
        st["buttons"][key] = action
        save(st)
        return st["buttons"]

    async def set_menu_clicks(self, on: bool = True, **_: Any) -> bool:
        st = load()
        st["menu_clicks"] = bool(on)
        save(st)
        return st["menu_clicks"]

    async def set_power_led(self, on: bool = True, **_: Any) -> bool:
        st = load()
        st["power_led"] = bool(on)
        save(st)
        return st["power_led"]
