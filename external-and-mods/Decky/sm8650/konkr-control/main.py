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

sys.path.insert(0, "/usr/lib/steamos-arm")
try:
    import power_limits
except ImportError:
    power_limits = None

ODIN3D = os.path.exists("/usr/lib/odin3/odin3d")
STATE = "/var/lib/odin3/state.json" if ODIN3D else "/var/lib/konkrd/state.json"
DAEMON = "odin3d" if ODIN3D else "konkrd"
BLACKLIST = "/etc/modprobe.d/konkr-mcu.conf"
FLIP = "/etc/steamos-arm/flip-screen"


def gen5() -> bool:
    """Lenovo Legion Y700 Gen 5 (its bootloader can't be unlocked: Android and
    SteamOS take turns in boot_a)."""
    try:
        with open("/sys/firmware/devicetree/base/compatible", "rb") as fh:
            return "lenovo,baldur" in fh.read().decode(errors="replace").split("\0")
    except OSError:
        return False


def tablet() -> bool:
    """Lenovo Legion Y700 Gen 3 / Gen 4."""
    try:
        with open("/sys/firmware/devicetree/base/compatible", "rb") as fh:
            compat = fh.read().decode(errors="replace").split("\0")
    except OSError:
        return False
    return any(c in compat for c in ("lenovo,tb321fu", "lenovo,elden", "lenovo,baldur"))
ACTIONS = ("profile-next", "rgb-next", "sticks-toggle", "fan-boost", "game", "none")


def rd(path: str, default: str = "") -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return default


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


KONKR_STICK_LED = "/sys/class/leds/konkr:rgb:joysticks"
EFFECTS = ("static", "breath", "chroma", "rainbow")


def stick_leds() -> list[str]:
    return glob.glob("/sys/class/leds/*joysticks*") + glob.glob("/sys/class/leds/*-joystick") \
        + glob.glob("/sys/class/leds/rgb:[lr][0-9]") + glob.glob("/sys/class/leds/[lr]:r1")


def lights_state(st: dict[str, Any]) -> dict[str, Any]:
    """Joystick Lights as Steam's Settings page shows them. The daemons draw
    every effect on the per-LED rings and zones at any speed; the KONKR
    single LED runs the MCU's own breath and hue cycle (chroma), at one speed."""
    leds = stick_leds()
    mcu = os.path.isdir(KONKR_STICK_LED)
    if not leds:
        effects: tuple[str, ...] = ()
    elif mcu:
        effects = ("static", "breath", "chroma") if os.path.exists(f"{KONKR_STICK_LED}/effect") else ("static",)
    else:
        effects = EFFECTS
    rgb = st["rgb"]
    mode = rgb.get("mode", "static")
    effect = rgb.get("last_mode", "static") if mode == "off" else mode
    return {
        "present": bool(leds),
        # The Pocket FIT's lights need the MCU link, which can be turned off.
        "needs_mcu": not leds and model() == "KONKR Pocket FIT" and not ODIN3D,
        "effects": list(effects),
        "has_speed": bool(leds) and not mcu,
        "enabled": mode != "off",
        "effect": effect or "static",
        "color": rgb.get("color", "ff3c00"),
        "brightness": round(int(rgb.get("brightness", 160)) * 100 / 255),
        "speed": int(rgb.get("speed", 50)),
    }


def cpu_state(st: dict[str, Any]) -> dict[str, Any]:
    """CPU underclock (Quick Access > Performance): the choice, each
    cluster's frequencies and ceiling, and what each preset sets."""
    if power_limits is None:
        return {"supported": False}
    cl = power_limits.clusters()
    limit = st.get("cpu_limit") or "stock"
    caps = power_limits.cpu_caps(limit, st.get("cpu_custom"))
    presets = {name: {str(k): v for k, v in power_limits.cpu_caps(name).items()}
               for name in ("small", "medium", "large")}
    return {
        "supported": bool(cl),
        "limit": limit,
        "presets": presets,
        "clusters": [{
            "cpu": c["cpu"], "cores": len(c["cpus"]), "max": c["max"], "freqs": c["freqs"],
            "cap": caps.get(c["cpu"], c["max"]),
            "now": int(rd(f"{c['policy']}/scaling_max_freq", str(c["max"])) or c["max"]),
        } for c in cl],
    }


def model() -> str:
    return rd("/sys/firmware/devicetree/base/model").rstrip("\0")


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
        name = model()
        fit = name == "KONKR Pocket FIT"
        return {
            "model": name,
            "daemon_name": DAEMON,
            "profile": st["profile"],
            "rgb": st["rgb"],
            "fan": st["fan"],
            "game": game_fan_state(st),
            "power_led": st["power_led"],
            "power_led_mode": st.get("power_led_mode", "charge"),
            "menu_clicks": st["menu_clicks"],
            "has_flip": tablet(),
            "flip": os.path.exists(FLIP),
            # Tablets: SteamOS on the microSD card next to Android. Handhelds:
            # ROCKNIX ABL, whose menu picks Android or Linux.
            "has_dualboot": not tablet() or subprocess.run(["sh", "-c", "findmnt -no SOURCE / | grep -q mmcblk"]).returncode == 0,
            "dualboot_label": ("Restart into ZUI" if gen5() else "Restart into ZUXOS") if tablet() else "Restart into Android",
            "dualboot_text": ("SteamOS runs from the microSD card. This restarts into "
                              + ("ZUI; to come back, use Switch to SteamOS in KernelSU" if gen5()
                                 else "ZUXOS; to come back, run fastboot set_active b")) if tablet() else
                             ("Restarts into the boot menu: choose Switch boot mode until it says Android, "
                              "then Start. To come back, restart holding Volume Down and switch it back to Linux."),
            "has_motors": any("HID_ID=0003:00004001:00000428" in rd(f"{d}/device/uevent")
                              for d in glob.glob("/sys/class/hidraw/hidraw*")),
            "buttons": st["buttons"],
            # What this device has, so the panel only shows what works here.
            "has_power_led": not ODIN3D and bool(glob.glob("/sys/class/leds/*power-led*")),
            "has_mcu_link": fit and not ODIN3D,
            "fit_buttons": fit,
            "mcu_enabled": not os.path.exists(BLACKLIST),
            "mcu_loaded": os.path.isdir("/sys/module/konkr_sysbtn"),
            "daemon": subprocess.run(["systemctl", "is-active", "--quiet", DAEMON]).returncode == 0,
            "bypass": await asyncio.to_thread(bypass_state),
            **await asyncio.to_thread(telemetry),
        }

    async def set_bypass(self, on: bool = False, **_: Any) -> dict[str, Any]:
        await asyncio.to_thread(subprocess.run, ["busctl", "--system", "set-property", *POWER[3:],
                                                 "BypassCharging", "b", "true" if on else "false"],
                                capture_output=True, timeout=5)
        return await asyncio.to_thread(bypass_state)


    async def get_cpu(self, **_: Any) -> dict[str, Any]:
        return cpu_state(load())

    async def set_cpu(self, limit: str = "stock", custom: dict | None = None, **_: Any) -> dict[str, Any]:
        """limit: stock / small / medium / large / custom; custom: {first
        cpu: kHz} for "custom". The daemon applies it on the reload."""
        st = load()
        if power_limits is None or limit not in power_limits.CPU_LIMITS:
            return cpu_state(st)
        if limit == "stock":
            st.pop("cpu_limit", None)
        else:
            st["cpu_limit"] = limit
        if limit == "custom" and isinstance(custom, dict):
            st["cpu_custom"] = {str(int(k)): int(v) for k, v in custom.items()}
        save(st)
        return cpu_state(st)

    async def get_lights(self, **_: Any) -> dict[str, Any]:
        return lights_state(load())

    async def set_lights(self, enabled: bool = True, effect: str = "static", color: str = "ff3c00",
                         brightness: int = 63, speed: int = 50, **_: Any) -> dict[str, Any]:
        """Steam Settings > Joystick Lights. brightness and speed are 0-100;
        turned off, the effect is kept in last_mode (konkrd's sticks toggle
        brings it back from there too)."""
        st = load()
        effects = lights_state(st)["effects"]
        if effect not in effects:
            effect = "static"
        color = str(color).lstrip("#").lower()
        if len(color) != 6 or any(c not in "0123456789abcdef" for c in color):
            color = st["rgb"].get("color", "ff3c00")
        rgb = st["rgb"]
        rgb.update(mode=effect if enabled else "off", color=color,
                   brightness=round(max(0, min(100, int(brightness))) * 255 / 100),
                   speed=max(0, min(100, int(speed))))
        if not enabled:
            rgb["last_mode"], rgb["last_color"] = effect, color
        save(st)
        return lights_state(st)

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

    async def set_flip(self, on: bool = False, **_: Any) -> bool:
        """Lenovo tablets: Game Mode the other way up. gamescope reads it when
        Game Mode starts; the touch mapping follows through udev now."""
        if on:
            os.makedirs(os.path.dirname(FLIP), exist_ok=True)
            open(FLIP, "w").close()
        elif os.path.exists(FLIP):
            os.remove(FLIP)
        await asyncio.to_thread(subprocess.run, ["udevadm", "trigger", "--subsystem-match=input", "--action=change"])
        return os.path.exists(FLIP)

    async def boot_android(self, **_: Any) -> bool:
        """Restart into Android: tablets switch back to their Android (ZUXOS or
        ZUI), handhelds restart into the ABL's boot menu."""
        # Gen 5: copy Android's boot image back into boot_a. Gen 4: make slot A active.
        # Handhelds: restart into ROCKNIX ABL's menu (its boot mode lives in a
        # UEFI variable Linux can't set).
        if not tablet():
            tool = ["systemctl", "reboot", "--reboot-argument=bootloader"]
        else:
            tool = ["/usr/lib/steamos-arm/gen5-android"] if gen5() else ["/usr/lib/steamos-arm/tablet-slot", "android"]
        r = await asyncio.to_thread(subprocess.run, tool)
        return r.returncode == 0

    async def set_power_led(self, mode: str = "charge", **_: Any) -> str:
        """"charge" (charging status), "profile" (the performance profile's
        colour) or "off"."""
        st = load()
        st["power_led"] = mode != "off"
        if mode in ("charge", "profile"):
            st["power_led_mode"] = mode
        save(st)
        return mode
