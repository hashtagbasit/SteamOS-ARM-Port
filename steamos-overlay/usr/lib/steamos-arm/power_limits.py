"""Steam's own power controls, on top of the device daemon's profile.

konkrd (8 Gen 2 / 8 Gen 3) and odin3d (8 Elite) call apply() right after
they apply a profile. The limits come from their state.json, where the
steamos-arm-power bridge writes what Steam's Quick Access asks for:

  tdp            watts, or absent for no limit. There is no power limiter on
                 these chips, so a TDP is turned into clocks. The share of
                 the slider is a share of power, not of clock speed: each
                 big cluster gets its fastest step whose power (from the
                 kernel's energy model) stays inside that share of its own
                 range, and the GPU the same along a f^2.5 power curve.
                 Power climbs much faster than clock, so a linear clock
                 split left 8 W on an 8 Gen 3 at 1.19 GHz big cores and a
                 500 MHz GPU, far below what 8 W actually affords. The
                 little cores are left alone, they barely draw anything.
  gpu_manual_mhz Steam's "Manual GPU clock": the GPU held at that clock.
  cpu_limit      CPU underclock, ClusterTune's presets: "small", "medium",
                 "large", or "custom" with cpu_custom {first cpu: kHz}; absent
                 or "stock" for none. A ceiling per cluster, little cores
                 included; less heat for the fan to chase. With a TDP too,
                 the lower of the two wins.

Nothing here is applied when none is set, so the profiles behave exactly
as before.
"""
from __future__ import annotations

import glob
import os

# Watts the TDP slider spans per chip; the top of the range means no limit.
TDP_RANGE = {"sm8250": (3, 10), "sm8350": (3, 12), "sm8550": (4, 15), "sm8650": (4, 18), "sm8750": (5, 22)}


def _rd(path: str, default: str = "") -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return default


def _wr(path: str, value) -> bool:
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(str(value))
        return True
    except OSError:
        return False


def chip() -> str:
    try:
        compat = open("/proc/device-tree/compatible", "rb").read().decode(errors="replace")
    except OSError:
        return ""
    for c in TDP_RANGE:
        if f"qcom,{c}" in compat:
            return c
    return "sm8550" if "qcs8550" in compat else ""


def tdp_range() -> tuple[int, int]:
    return TDP_RANGE.get(chip(), (4, 15))


def gpu_dir() -> str | None:
    for d in glob.glob("/sys/class/devfreq/*"):
        if "gpu" in os.path.basename(d) or "3d00000" in d:
            return d
    return None


def gpu_freqs() -> list[int]:
    d = gpu_dir()
    return sorted(int(f) for f in _rd(f"{d}/available_frequencies").split() if f.isdigit()) if d else []


def gpu_range_mhz() -> tuple[int, int]:
    f = gpu_freqs()
    return (f[0] // 1_000_000, f[-1] // 1_000_000) if f else (0, 0)


def _fraction(tdp) -> float | None:
    if tdp is None:
        return None
    lo, hi = tdp_range()
    try:
        w = float(tdp)
    except (TypeError, ValueError):
        return None
    if w >= hi:
        return None
    return max(0.0, min(1.0, (w - lo) / (hi - lo)))


def _big_policies() -> list[str]:
    """cpufreq policies of every cluster but the lowest-capacity one."""
    pols = []
    for pol in glob.glob("/sys/devices/system/cpu/cpufreq/policy*"):
        try:
            pols.append((int(_rd(f"{pol}/cpuinfo_max_freq", "0")), pol))
        except ValueError:
            pass
    if len(pols) < 2:
        return [p for _, p in pols]
    lowest = min(m for m, _ in pols)
    return [p for m, p in pols if m > lowest]


# Dynamic power grows roughly with f * V^2, and V rises with f.
GPU_POWER_EXP = 2.5


def _energy_model(pol: str) -> list[tuple[int, int]]:
    """(kHz, uW) per performance state of a policy, from debugfs, or []."""
    first = (_rd(f"{pol}/related_cpus").split() or [""])[0]
    out = []
    for ps in glob.glob(f"/sys/kernel/debug/energy_model/cpu{first}/ps:*"):
        try:
            out.append((int(_rd(f"{ps}/frequency")), int(_rd(f"{ps}/power"))))
        except ValueError:
            pass
    return sorted(out)


def _power_cap(states: list[tuple[int, float]], frac: float) -> int:
    """Fastest state whose power is within frac of the min..max power span."""
    lo, hi = states[0][1], states[-1][1]
    budget = lo + frac * (hi - lo)
    fits = [f for f, pw in states if pw <= budget + 1e-9]
    return fits[-1] if fits else states[0][0]


def _snap(freqs: list[int], want: float) -> int:
    """The highest available frequency not above want (or the lowest)."""
    below = [f for f in freqs if f <= want]
    return below[-1] if below else freqs[0]


# ClusterTune's bundled profiles (github.com/AurelioB/ClusterTune, GPL-2.0):
# max kHz per cluster, by the cluster's first CPU.
CPU_PRESETS = {
    "sm8750": {   # CQ8725S, AYN Odin 3
        "small": {0: 2745600, 6: 3072000},
        "medium": {0: 2227200, 6: 2246400},
        "large": {0: 1785600, 6: 1958400},
    },
    "sm8550": {   # QCS8550, AYN Odin 2 / Thor, Retroid Pocket 6
        "small": {0: 1785600, 3: 2323200, 7: 2476800},
        "medium": {0: 1555200, 3: 2054400, 7: 2092800},
        "large": {0: 1459200, 3: 1785600, 7: 1843200},
    },
}
# Chips ClusterTune has no profile for: its 8 Gen 2 profiles as shares of
# each cluster's top clock (little, middle, prime).
CPU_PRESET_SHARES = {
    "small": (0.88, 0.83, 0.78),
    "medium": (0.77, 0.73, 0.66),
    "large": (0.72, 0.64, 0.58),
}
CPU_LIMITS = ("stock", "small", "medium", "large", "custom")


def clusters() -> list[dict]:
    """The CPU clusters, slowest first: first cpu, policy dir, frequencies."""
    out = []
    for pol in glob.glob("/sys/devices/system/cpu/cpufreq/policy*"):
        cpus = _rd(f"{pol}/related_cpus").split()
        fmax = int(_rd(f"{pol}/cpuinfo_max_freq", "0") or 0)
        if not cpus or not fmax:
            continue
        fmin = int(_rd(f"{pol}/cpuinfo_min_freq", "0") or 0)
        avail = sorted(int(f) for f in _rd(f"{pol}/scaling_available_frequencies").split() if f.isdigit()) or [fmin, fmax]
        out.append({"cpu": int(cpus[0]), "cpus": [int(c) for c in cpus], "policy": pol,
                    "min": fmin, "max": fmax, "freqs": avail})
    return sorted(out, key=lambda c: (c["max"], c["cpu"]))


def cpu_caps(limit: str | None, custom: dict | None = None) -> dict[int, int]:
    """kHz ceiling per cluster (by first cpu) for an underclock, {} for none."""
    cl = clusters()
    if limit == "custom":
        custom = custom or {}
        return {c["cpu"]: _snap(c["freqs"], int(custom[str(c["cpu"])]))
                for c in cl if str(c["cpu"]) in custom}
    if limit not in CPU_PRESET_SHARES:
        return {}
    table = CPU_PRESETS.get(chip(), {}).get(limit)
    if table and set(table) == {c["cpu"] for c in cl}:
        return {c["cpu"]: _snap(c["freqs"], table[c["cpu"]]) for c in cl}
    shares = CPU_PRESET_SHARES[limit]
    caps = {}
    for i, c in enumerate(cl):
        share = shares[0] if i == 0 else shares[2] if i == len(cl) - 1 else shares[1]
        caps[c["cpu"]] = _snap(c["freqs"], c["max"] * share)
    return caps


def apply(state: dict) -> None:
    frac = _fraction(state.get("tdp"))
    under = cpu_caps(state.get("cpu_limit"), state.get("cpu_custom"))
    big = set(_big_policies())
    # CPU: big clusters capped by the TDP, every cluster by an underclock;
    # back to full without either.
    for c in clusters():
        pol, fmax, avail = c["policy"], c["max"], c["freqs"]
        cap = fmax
        if frac is not None and pol in big:
            em = _energy_model(pol)
            if len(em) < 2:
                em = [(f, (f / fmax) ** GPU_POWER_EXP) for f in avail]
            cap = _snap(avail, _power_cap(em, frac))
        cap = min(cap, under.get(c["cpu"], fmax))
        _wr(f"{pol}/scaling_max_freq", cap)
    # GPU: a manual clock wins; else the TDP caps the profile's ceiling.
    d = gpu_dir()
    freqs = gpu_freqs()
    if not d or not freqs:
        return
    manual = state.get("gpu_manual_mhz")
    if manual:
        f = min(freqs, key=lambda x: abs(x - int(manual) * 1_000_000))
        _wr(f"{d}/max_freq", freqs[-1])     # never min above max on the way
        _wr(f"{d}/min_freq", f)
        _wr(f"{d}/max_freq", f)
        return
    if frac is not None:
        top = freqs[-1]
        cap = _power_cap([(f, (f / top) ** GPU_POWER_EXP) for f in freqs], frac)
        cur_max = int(_rd(f"{d}/max_freq", str(freqs[-1])) or freqs[-1])
        cur_min = int(_rd(f"{d}/min_freq", str(freqs[0])) or freqs[0])
        if cur_min > cap:
            _wr(f"{d}/min_freq", freqs[0])
        _wr(f"{d}/max_freq", min(cur_max, cap))
