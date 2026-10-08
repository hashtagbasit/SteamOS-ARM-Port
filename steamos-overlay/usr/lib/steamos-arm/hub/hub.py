#!/usr/bin/env python3
"""steamos-arm-hub: emulators and apps in one tap, on every SteamOS-ARM device.

One engine behind every front end: the Decky panel (all devices), the Thor's
bottom screen and the command line. It runs as the user, needs no root
(AppImages go to ~/Applications, Flatpaks are installed for the user) and
keeps its work in files, so any front end can start a job, close, and the
next one opened sees the same progress.

  catalog.json          what can be installed and from where (best source first)
  ~/.config/steamos-arm/hub.json                  where the game library lives
  ~/.local/state/steamos-arm/hub/installed.json   what is installed, which build
  ~/.local/state/steamos-arm/hub/jobs/<id>.json   running and finished jobs
  ~/.local/state/steamos-arm/hub/steam.json       Steam shortcuts owed and made
  ~/.local/share/steamos-arm/hub/bin/<app>        a launcher per installed app

The launchers are what Steam shortcuts, ES-DE and the desktop menu point at:
they survive updates (an AppImage's file name can change) and set up what
the app needs on this device before starting it.

Command line (JSON out, for the front ends):
  hub.py device | catalog | status | jobs
  hub.py install|update|remove <app> [--wipe]     start a job, print its id
  hub.py starter                                  install the starter set
  hub.py update-all | check-updates
  hub.py cancel <job>
  hub.py library [<path>|internal|sd]             show or move the library
  hub.py steam-pending | steam-made <app> <appid> | steam-gone <app>
  hub.py run <app> [args...]                      what the launchers call
"""
from __future__ import annotations

import fcntl
import glob
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CATALOG = HERE / "catalog.json"
HOME = Path.home()
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "steamos-arm" / "hub.json"
STATE = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state")) / "steamos-arm" / "hub"
DATA = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share"))
BIN = DATA / "steamos-arm" / "hub" / "bin"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "steamos-arm" / "hub"
APPS = HOME / "Applications"
PLUGINS = HOME / "homebrew" / "plugins"
DESKTOP_DIR = DATA / "applications"
ICON_DIR = DATA / "icons" / "hicolor" / "256x256" / "apps"
CHIPS = ("sm8350", "sm8550", "sm8650", "sm8750")
FEED_TTL_S = 900           # release feeds are asked at most every 15 minutes
UA = "steamos-arm-hub/1 (+https://github.com/hashtagbasit)"
FLATHUB_REPO = "https://dl.flathub.org/repo/flathub.flatpakrepo"


# ------------------------------------------------------------- basics ----
def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default() if callable(default) else default


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=1))
    os.replace(tmp, path)


class Locked:
    """Serialises read-modify-write of a state file across processes."""
    def __init__(self, path: Path):
        self.path = path.with_name(path.name + ".lock")

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def update_json(path: Path, change, default=dict):
    with Locked(path):
        data = read_json(path, default)
        change(data)
        write_json(path, data)
        return data


def rd(path: str) -> str:
    try:
        with open(path, "rb") as fh:
            return fh.read().replace(b"\0", b" ").decode(errors="replace").strip()
    except OSError:
        return ""


def catalog() -> list[dict]:
    return read_json(CATALOG, {"apps": []}).get("apps", [])


def entry(app_id: str) -> dict:
    for e in catalog():
        if e["id"] == app_id:
            return e
    raise KeyError(f"no app called {app_id}")


# ------------------------------------------------------------- device ----
def device() -> dict:
    compat = rd("/proc/device-tree/compatible")
    chip = next((c for c in CHIPS if f"qcom,{c}" in compat or c in compat), "")
    if not chip and "qcs8550" in compat:
        chip = "sm8550"
    # A second panel this session: Game Mode wrote bottom-screen.env for it.
    dual = bool(bottom_env()) or "ayn,thor" in compat
    lease = dual and Path("/usr/share/steamos-arm/features/drm-lease").exists()
    return {
        "chip": chip or "unknown",
        "model": rd("/proc/device-tree/model") or "this device",
        "dual": dual,
        "lease": lease,
        "page": os.sysconf("SC_PAGE_SIZE"),
    }


def chip_rank(chip: str) -> int:
    return CHIPS.index(chip) if chip in CHIPS else 1


def fits(when: dict | None, dev: dict) -> bool:
    if not when:
        return True
    if "dual" in when and bool(when["dual"]) != (dev["dual"] and dev["lease"]):
        return False
    if "page" in when and int(when["page"]) != dev["page"]:
        return False
    if "chips" in when and dev["chip"] not in when["chips"]:
        return False
    return True


# ------------------------------------------------------------ library ----
def settings() -> dict:
    s = read_json(CONFIG, dict)
    s.setdefault("library", str(HOME / "Emulation"))
    return s


def _mount_disk(path: str) -> str:
    """The whole-disk name (mmcblk0, sda) a path's filesystem is on, or ""."""
    best, dev = "", ""
    try:
        with open("/proc/self/mounts") as f:
            for line in f:
                src, mnt = line.split()[:2]
                mnt = mnt.replace("\\040", " ")
                if src.startswith("/dev/") and (path == mnt or path.startswith(mnt.rstrip("/") + "/")) \
                        and len(mnt) > len(best):
                    best, dev = mnt, src
    except OSError:
        return ""
    name = os.path.basename(os.path.realpath(dev))
    part = f"/sys/class/block/{name}"
    if os.path.exists(f"{part}/partition"):
        name = os.path.basename(os.path.dirname(os.path.realpath(part)))
    return name


def _disk_kind(disk: str) -> str:
    """"sd" for a microSD card, "usb" for a USB drive, "internal" otherwise."""
    if disk.startswith("mmcblk"):
        return "sd"
    if "/usb" in os.path.realpath(f"/sys/class/block/{disk}"):
        return "usb"
    return "internal"


HOME_LABELS = {"sd": "microSD card (this system)", "usb": "USB drive (this system)",
               "internal": "Internal storage"}


def home_kind() -> str:
    return _disk_kind(_mount_disk(str(HOME)))


def sd_cards() -> list[str]:
    """Mounted removable cards and drives other than the one this system runs
    from, largest first. Internal storage partitions mounted under /run/media
    (Android's, an internal install's) don't count: they aren't cards."""
    out = []
    user = os.environ.get("USER") or HOME.name
    own = _mount_disk(str(HOME))
    for base in (f"/run/media/{user}", "/run/media"):
        for m in glob.glob(f"{base}/*"):
            disk = _mount_disk(m)
            if not disk or disk == own or _disk_kind(disk) == "internal":
                continue
            if os.path.ismount(m) and os.access(m, os.W_OK):
                try:
                    st = os.statvfs(m)
                    out.append((st.f_blocks * st.f_frsize, m))
                except OSError:
                    pass
    return [m for _, m in sorted(set(out), reverse=True)]


def library() -> Path:
    return Path(settings()["library"])


SYSTEM_NAMES = {
    "nes": "NES", "snes": "Super Nintendo", "gb": "Game Boy", "gbc": "Game Boy Color",
    "gba": "Game Boy Advance", "genesis": "Mega Drive / Genesis", "mastersystem": "Master System",
    "gamegear": "Game Gear", "n64": "Nintendo 64", "pcengine": "PC Engine", "neogeo": "Neo Geo",
    "arcade": "Arcade", "mame": "MAME", "atari2600": "Atari 2600", "psx": "PlayStation",
    "psp": "PSP", "nds": "Nintendo DS", "n3ds": "Nintendo 3DS", "gc": "GameCube", "wii": "Wii",
    "ps2": "PlayStation 2", "switch": "Switch", "wiiu": "Wii U", "ps3": "PlayStation 3",
    "psvita": "PS Vita", "xbox": "Xbox", "dreamcast": "Dreamcast", "naomi": "Naomi",
    "atomiswave": "Atomiswave", "scummvm": "ScummVM", "dos": "DOS",
    "saturn": "Saturn", "atarijaguar": "Atari Jaguar",
}


def make_library(systems: list[str]) -> None:
    lib = library()
    for sub in ("roms", "bios", "saves", "states"):
        (lib / sub).mkdir(parents=True, exist_ok=True)
    for s in systems:
        (lib / "roms" / s).mkdir(parents=True, exist_ok=True)
    readme = lib / "README.txt"
    if not readme.exists():
        readme.write_text(
            "Your games and the files the emulators need.\n\n"
            "  roms/<system>   game files, one folder per system\n"
            "  bios/           BIOS and firmware files (bios/switch for Switch keys and firmware)\n"
            "  saves/, states/ kept here where an emulator lets us\n\n"
            "Move the whole library between the internal drive and an SD card from the\n"
            "Loadout's Mine tab; the emulators follow.\n")


def set_library(where: str) -> dict:
    if where == "internal":
        target = HOME / "Emulation"
    elif where == "sd":
        cards = sd_cards()
        if not cards:
            raise RuntimeError("No SD card is mounted")
        target = Path(cards[0]) / "Emulation"
    else:
        target = Path(where).expanduser()
    old = library()
    target.mkdir(parents=True, exist_ok=True)
    if old.exists() and old.resolve() != target.resolve():
        # Bring the games along: anything not already at the new place moves.
        for item in old.iterdir():
            dest = target / item.name
            if not dest.exists():
                shutil.move(str(item), str(dest))
    update_json(CONFIG, lambda s: s.__setitem__("library", str(target)))
    installed = read_json(STATE / "installed.json", dict)
    for app_id in installed:
        try:
            e = entry(app_id)
            make_library(e.get("systems", []))
            if installed[app_id].get("ref"):
                flatpak_allow(installed[app_id]["ref"])    # it may only see the old place
            SETUPS.get(e.get("setup", ""), lambda *_: None)(e, installed[app_id], True)
        except Exception as exc:  # one emulator's config never blocks the move
            log(f"library move: {app_id}: {exc}")
    write_esde_rules()
    return {"library": str(target)}


def log(msg: str) -> None:
    print(f"hub: {msg}", file=sys.stderr, flush=True)


# -------------------------------------------------------------- feeds ----
def http_json(url: str):
    cache = CACHE / "feeds" / (hashlib.sha1(url.encode()).hexdigest() + ".json")
    try:
        if time.time() - cache.stat().st_mtime < FEED_TTL_S:
            return json.loads(cache.read_text())
    except (OSError, ValueError):
        pass
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            data = json.load(r)
    except (urllib.error.URLError, OSError, ValueError):
        # Offline or rate limited: a stale answer beats none.
        try:
            return json.loads(cache.read_text())
        except (OSError, ValueError):
            raise RuntimeError(f"Can't reach {urllib.parse.urlparse(url).netloc}")
    write_json(cache, data)
    return data


def releases(src: dict) -> list[dict]:
    """The source's releases as [{tag, date, pre, files: [{name, url, sha256, size, date}]}]."""
    kind, repo = src["kind"], src["repo"]
    if kind == "github":
        if src.get("tag"):
            raw = [http_json(f"https://api.github.com/repos/{repo}/releases/tags/{src['tag']}")]
        else:
            raw = http_json(f"https://api.github.com/repos/{repo}/releases?per_page=20")
        out = []
        for r in raw:
            if r.get("draft"):
                continue
            files = []
            for a in r.get("assets", []):
                digest = a.get("digest") or ""
                files.append({"name": a["name"], "url": a["browser_download_url"],
                              "sha256": digest[7:] if digest.startswith("sha256:") else "",
                              "size": a.get("size", 0), "date": a.get("updated_at") or ""})
            out.append({"tag": r.get("tag_name", ""), "date": r.get("published_at") or "",
                        "pre": bool(r.get("prerelease")), "files": files, "notes": r.get("body") or ""})
        return out
    if kind == "forgejo":
        raw = http_json(f"{src['base']}/api/v1/repos/{repo}/releases?limit=10")
        return [{"tag": r.get("tag_name", ""), "date": r.get("published_at") or "", "pre": bool(r.get("prerelease")),
                 "files": [{"name": a["name"], "url": a["browser_download_url"], "sha256": "",
                            "size": a.get("size", 0), "date": a.get("created_at") or ""} for a in r.get("assets", [])],
                 "notes": r.get("body") or ""}
                for r in raw if not r.get("draft")]
    if kind == "gitlab":
        raw = http_json(f"{src['base']}/api/v4/projects/{urllib.parse.quote(repo, safe='')}/releases?per_page=10")
        return [{"tag": r.get("tag_name", ""), "date": r.get("released_at") or "", "pre": bool(r.get("upcoming_release")),
                 "files": [{"name": l["name"], "url": l.get("direct_asset_url") or l["url"], "sha256": "",
                            "size": 0, "date": r.get("released_at") or ""} for l in r.get("assets", {}).get("links", [])],
                 "notes": r.get("description") or ""}
                for r in raw]
    raise ValueError(kind)


def pick_file(src: dict) -> dict:
    """The newest matching file: stable releases first unless the source is
    nightly-only. Ordered by date, never by tag (tags sort badly)."""
    pattern = re.compile(src["file"])
    found = []
    for r in releases(src):
        for f in r["files"]:
            if pattern.search(f["name"]):
                found.append((r["pre"], r["date"] or f["date"], f["date"], r, f))
                break
    if not found:
        raise RuntimeError("no build for this device in the newest releases")
    stable = [x for x in found if not x[0]]
    pool = stable if stable and not src.get("prerelease") else found
    _, date, fdate, r, f = max(pool, key=lambda x: (x[1], x[2]))
    # A fixed tag (nightly, continuous) keeps its tag while the file changes.
    version = nice_version(r["tag"], f["name"])
    if src.get("tag"):
        version = f"{version} {fdate[:10]}"
    return {"how": "file", "url": f["url"], "name": f["name"], "sha256": f["sha256"],
            "size": f["size"], "version": version, "stamp": fdate or date,
            "notes": (r.get("notes") or "")[:6000]}


def nice_version(tag: str, name: str) -> str:
    """'2609@2026-10-01_1790876487' -> '2609', 'build-<sha>' -> the file's version."""
    tag = tag.split("@")[0]
    # one repo, several apps: tags like "heroic-2.22.3"
    m = re.fullmatch(r"[a-z][a-z0-9_]*(?:-[a-z][a-z0-9_]*)*-v?(\d+(?:\.\d+)+)", tag)
    if m:
        return m.group(1)
    if re.fullmatch(r"build-[0-9a-f]{12,}", tag) or not tag:
        m = re.search(r"v?(\d+(?:\.\d+)+(?:-\d+)?)", name)
        return m.group(1) if m else tag[:14]
    return tag.lstrip("v") if re.match(r"v\d", tag) else tag


def resolve(e: dict, dev: dict | None = None) -> tuple[int, dict]:
    """(source index, what to install) for this device, falling through
    sources that don't fit or can't be reached."""
    dev = dev or device()
    errors = []
    for i, src in enumerate(e["sources"]):
        if not fits(src.get("when"), dev):
            continue
        try:
            if src["kind"] == "flathub":
                return i, {"how": "flatpak", "ref": src["ref"], "version": "", "stamp": ""}
            if src["kind"] == "builtin":
                return i, {"how": "builtin", "exec": src["exec"], "version": "built in", "stamp": ""}
            return i, pick_file(src)
        except Exception as exc:
            errors.append(str(exc))
    raise RuntimeError(errors[-1] if errors else "nothing fits this device")


# --------------------------------------------------------------- jobs ----
JOBS = STATE / "jobs"


def job_path(job_id: str) -> Path:
    return JOBS / f"{job_id}.json"


def jobs(include_old: bool = False) -> list[dict]:
    out = []
    now = time.time()
    for p in sorted(JOBS.glob("*.json")):
        j = read_json(p, None)
        if not j:
            continue
        # A runner that died (reboot, crash) can't finish its job.
        if j["state"] == "running" and not pid_alive(j.get("pid", 0)) and now - j.get("updated", 0) > 30:
            j["state"], j["error"] = "failed", "Stopped before it finished"
            write_json(p, j)
        if j["state"] != "running" and now - j.get("updated", 0) > 3600:
            p.unlink(missing_ok=True)
            continue
        if include_old or j["state"] == "running" or now - j.get("updated", 0) < 600:
            out.append(j)
    return out


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError):
        return False


def start_job(action: str, app_id: str, **extra) -> dict:
    title = entry(app_id)["title"]  # unknown ids fail here, not in the runner
    for j in jobs():
        if j["app"] == app_id and j["state"] == "running":
            return j
    job = {"id": uuid.uuid4().hex[:10], "app": app_id, "app_title": title, "action": action, "state": "running",
           "stage": "Waiting", "pct": 0, "started": time.time(), "updated": time.time(), "extra": extra}
    write_json(job_path(job["id"]), job)
    cmd = [sys.executable, str(Path(__file__).resolve()), "_run", job["id"]]
    # A transient user unit outlives whichever front end asked; plain
    # detaching is the fallback without a user manager (tests, chroots).
    unit = f"steamos-arm-hub-{app_id}-{job['id']}"
    try:
        # Downloads and unpacks go to /home, on the same card as the system:
        # cap them so a big Flatpak can't freeze everything else (the user
        # manager gets the io controller from 20-steamos-arm-io.conf).
        r = subprocess.run(["systemd-run", "--user", "--collect", "--quiet", f"--unit={unit}",
                            "--property=Nice=5", "--property=CPUWeight=20", "--property=IOWeight=20",
                            f"--property=IOReadBandwidthMax={HOME} 40M",
                            f"--property=IOWriteBandwidthMax={HOME} 20M", *cmd],
                           capture_output=True, timeout=15)
        if r.returncode == 0:
            return job
    except (OSError, subprocess.TimeoutExpired):
        pass
    subprocess.Popen(cmd, start_new_session=True, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=open(STATE / "runner.log", "ab"))
    return job


class Job:
    def __init__(self, job_id: str):
        self.path = job_path(job_id)
        self.data = read_json(self.path, None)
        if not self.data:
            raise KeyError(job_id)
        self.data["pid"] = os.getpid()
        self.last = 0.0
        self.save()

    @property
    def cancelled(self) -> bool:
        return self.path.with_suffix(".cancel").exists()

    def check(self) -> None:
        if self.cancelled:
            raise Cancelled()

    def step(self, stage: str, pct: float | None = None, force: bool = False) -> None:
        self.data["stage"] = stage
        if pct is not None:
            self.data["pct"] = max(0, min(100, round(pct, 1)))
        if force or time.monotonic() - self.last > 0.4:
            self.save()

    def save(self) -> None:
        self.data["updated"] = time.time()
        write_json(self.path, self.data)
        self.last = time.monotonic()

    def finish(self, state: str, error: str = "") -> None:
        self.data.update(state=state, error=error, pct=100 if state == "done" else self.data.get("pct", 0))
        self.save()
        self.path.with_suffix(".cancel").unlink(missing_ok=True)


class Cancelled(Exception):
    pass


def cancel(job_id: str) -> dict:
    job_path(job_id).with_suffix(".cancel").touch()
    return {"ok": True}


# ---------------------------------------------------------- downloads ----
def download(url: str, dest: Path, job: Job, size: int = 0, sha256: str = "") -> None:
    """Resumable: a .part left by an earlier try is continued with a Range."""
    part = dest.with_name(dest.name + ".part")
    # A part file is only resumed for the same file: after an update of the
    # app it would belong to the old build, and appending to it would make a
    # broken AppImage where no checksum is published to catch it.
    origin = dest.with_name(dest.name + ".part.url")
    if part.exists() and (not origin.exists() or origin.read_text().strip() != url):
        part.unlink()
    origin.write_text(url)
    have = part.stat().st_size if part.exists() else 0
    req = urllib.request.Request(url, headers={"User-Agent": UA, **({"Range": f"bytes={have}-"} if have else {})})
    with urllib.request.urlopen(req, timeout=60) as r:
        if have and r.status != 206:       # the server ignored the range
            have = 0
        total = int(r.headers.get("Content-Length") or 0) + have or size
        with open(part, "ab" if have else "wb") as out:
            got = have
            t0, g0 = time.monotonic(), got
            while True:
                job.check()
                chunk = r.read(1 << 18)
                if not chunk:
                    break
                out.write(chunk)
                got += len(chunk)
                dt = time.monotonic() - t0
                speed = (got - g0) / dt if dt > 0.5 else 0
                note = f"{got / 1e6:.0f} of {total / 1e6:.0f} MB" if total else f"{got / 1e6:.0f} MB"
                if speed:
                    note += f" · {speed / 1e6:.1f} MB/s"
                job.step(f"Downloading · {note}", 5 + 85 * got / total if total else None)
    if sha256:
        job.step("Checking the download", 92, force=True)
        h = hashlib.sha256()
        with open(part, "rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                h.update(block)
        if h.hexdigest() != sha256:
            part.unlink(missing_ok=True)
            origin.unlink(missing_ok=True)
            raise RuntimeError("The download was damaged (checksum mismatch); try again")
    os.replace(part, dest)
    origin.unlink(missing_ok=True)


# ------------------------------------------------------------ flatpak ----
def flatpak_install(ref: str, job: Job, update: bool = False) -> str:
    """User install through libflatpak, so progress comes straight from the
    transaction (each runtime and the app weigh in by download size)."""
    subprocess.run(["flatpak", "remote-add", "--user", "--if-not-exists", "flathub", FLATHUB_REPO],
                   capture_output=True, timeout=60)
    try:
        import gi
        gi.require_version("Flatpak", "1.0")
        from gi.repository import Flatpak, Gio
    except (ImportError, ValueError):
        return flatpak_cli(ref, job, update)
    inst = Flatpak.Installation.new_user()
    tx = Flatpak.Transaction.new_for_installation(inst)
    tx.set_no_interaction(True)
    cancellable = Gio.Cancellable()
    arch = Flatpak.get_default_arch()
    full = f"app/{ref}/{arch}/stable"
    installed = any(r.get_name() == ref for r in inst.list_installed_refs_by_kind(Flatpak.RefKind.APP))
    if installed:
        tx.add_update(full, None, None)
    else:
        tx.add_install("flathub", full, None)
    state = {"ops": 0, "done": 0}

    def on_new_op(_tx, op, progress):
        state["ops"] = max(state["ops"], len(_tx.get_operations()))
        is_app = op.get_ref().split("/")[1] == ref
        part = state["done"] + 1

        def changed(p):
            if cancellable.is_cancelled():
                return
            if job.cancelled:
                cancellable.cancel()
                return
            overall = (state["done"] + p.get_progress() / 100) / max(1, state["ops"])
            what = "Installing the app" if is_app else f"Installing support files, part {part} of {state['ops']}"
            m = re.search(r"([\d.]+ [kMG]B)/([\d.]+ [kMG]B)(?: \(([\d.]+ [kMG]B/s)\))?", p.get_status() or "")
            detail = f" · {m.group(1)} of {m.group(2)}" + (f" · {m.group(3)}" if m.group(3) else "") if m else ""
            job.step(what + detail, 5 + 90 * overall)
        progress.connect("changed", changed)
        progress.set_update_frequency(400)

    def on_done(_tx, op, commit, result):
        state["done"] += 1

    tx.connect("new-operation", on_new_op)
    tx.connect("operation-done", on_done)
    tx.connect("operation-error", lambda _t, op, err, details: False)  # stop on any error
    job.step("Asking Flathub", 3, force=True)
    try:
        tx.run(cancellable)
    except Exception as exc:
        if job.cancelled:
            raise Cancelled()
        msg = str(exc)
        if "already installed" in msg:
            return ref
        # GLib errors read "<domain>-quark: <message> (<code>)"; keep the message.
        msg = re.sub(r"^[\w-]+-quark:\s*", "", msg)
        msg = re.sub(r"\s*\(\d+\)$", "", msg)
        raise RuntimeError(msg[:160] or "Flatpak install failed")
    return ref


def flatpak_cli(ref: str, job: Job, update: bool) -> str:
    job.step("Installing from Flathub", 10, force=True)
    args = ["flatpak", "update" if update else "install", "--user", "-y", "--noninteractive"]
    args += [ref] if update else ["flathub", ref]
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in p.stdout:
        job.check()
        job.step(line.strip()[:80] or "Installing from Flathub")
    if p.wait() != 0:
        raise RuntimeError("Flatpak install failed")
    return ref


def flatpak_installed() -> set[str]:
    try:
        out = subprocess.run(["flatpak", "list", "--app", "--columns=application"],
                             capture_output=True, text=True, timeout=20).stdout
        return {line.strip() for line in out.splitlines() if line.strip()}
    except (OSError, subprocess.TimeoutExpired):
        return set()


def flatpak_remove(ref: str) -> None:
    for scope in ("--user", "--system"):
        r = subprocess.run(["flatpak", "uninstall", scope, "-y", "--noninteractive", ref],
                           capture_output=True, text=True, timeout=300)
        if r.returncode == 0:
            return


def flatpak_allow(ref: str) -> None:
    """Let the emulator see the library wherever it lives (SD cards too)."""
    subprocess.run(["flatpak", "override", "--user", ref, f"--filesystem={library()}",
                    "--filesystem=/run/media", "--filesystem=~/Applications"],
                   capture_output=True, timeout=30)


# ------------------------------------------------------------ install ----
def installed_db() -> dict:
    return read_json(STATE / "installed.json", dict)


def do_install(job: Job, update: bool = False) -> None:
    app_id = job.data["app"]
    e = entry(app_id)
    dev = device()
    job.step("Finding the right build", 1, force=True)
    idx, pick = resolve(e, dev)
    src = e["sources"][idx]
    old = installed_db().get(app_id, {})
    if update and old.get("version") == pick.get("version") and old.get("source") == idx and pick["how"] == "file":
        job.step("Already the newest", 100, force=True)
        return
    record = {"how": pick["how"], "source": idx, "version": pick.get("version", ""),
              "stamp": pick.get("stamp", ""), "label": src.get("label", ""), "lease": src.get("lease", ""),
              "at": time.time()}
    if pick["how"] == "file" and src.get("plugin"):
        # A Decky plugin: its zip unpacked into ~/homebrew/plugins, which
        # Decky picks up by itself (an update takes a Decky restart).
        PLUGINS.mkdir(parents=True, exist_ok=True)
        staging = PLUGINS.parent / f".{app_id}.hub.zip"
        download(pick["url"], staging, job, pick.get("size", 0), pick.get("sha256", ""))
        job.step("Unpacking", 94, force=True)
        with zipfile.ZipFile(staging) as z:
            names = [n for n in z.namelist() if n and not n.startswith(("/", "."))]
            if any(".." in n.split("/") for n in names):
                raise RuntimeError("the plugin archive has unsafe paths")
            tops = {n.split("/", 1)[0] for n in names}
            if len(tops) != 1:
                raise RuntimeError("unexpected plugin archive layout")
            top = tops.pop()
            shutil.rmtree(PLUGINS / top, ignore_errors=True)
            z.extractall(PLUGINS)
            for info in z.infolist():          # keep the exec bits zip stores
                mode = info.external_attr >> 16
                if mode & 0o111:
                    target = PLUGINS / info.filename
                    target.chmod(target.stat().st_mode | 0o111)
        staging.unlink(missing_ok=True)
        record.update(how="plugin", dir=top)
        update_json(STATE / "installed.json", lambda d: d.__setitem__(app_id, record))
        return
    if pick["how"] == "file" and e.get("unpack"):
        # An app that ships as a folder (Heroic): a .tar.* unpacked into
        # ~/Applications/<unpack>, started through its "start" file.
        APPS.mkdir(parents=True, exist_ok=True)
        folder = e["unpack"]
        staging = APPS / f".{folder}.hub.tar"
        download(pick["url"], staging, job, pick.get("size", 0), pick.get("sha256", ""))
        job.step("Unpacking", 92, force=True)
        work = APPS / f".{folder}.hub.new"
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir()
        r = subprocess.run(["tar", "-xf", str(staging), "-C", str(work), "--no-same-owner"],
                           capture_output=True, text=True)
        staging.unlink(missing_ok=True)
        tops = [p_ for p_ in work.iterdir()]
        if r.returncode or len(tops) != 1 or not tops[0].is_dir():
            shutil.rmtree(work, ignore_errors=True)
            raise RuntimeError("the download didn't unpack as one app folder")
        if not (tops[0] / e["start"]).is_file():
            shutil.rmtree(work, ignore_errors=True)
            raise RuntimeError(f"the app folder has no {e['start']}")
        old_dir = APPS / folder
        if old_dir.exists():
            shutil.rmtree(old_dir)
        os.replace(tops[0], old_dir)
        shutil.rmtree(work, ignore_errors=True)
        record.update(file=folder, start=e["start"])
    elif pick["how"] == "file":
        APPS.mkdir(parents=True, exist_ok=True)
        name = e.get("save_as") or pick["name"]
        staging = APPS / f".{name}.hub"
        download(pick["url"], staging, job, pick.get("size", 0), pick.get("sha256", ""))
        if pick["name"].endswith(".zip"):
            job.step("Unpacking", 94, force=True)
            with zipfile.ZipFile(staging) as z:
                inner = next((n for n in z.namelist() if n.lower().endswith(".appimage")), None)
                if not inner:
                    raise RuntimeError("the archive has no AppImage in it")
                with z.open(inner) as src_fh, open(staging.with_suffix(".x"), "wb") as out:
                    shutil.copyfileobj(src_fh, out)
            os.replace(staging.with_suffix(".x"), staging)
        os.chmod(staging, 0o755)
        if old.get("file") and old["file"] != name:
            (APPS / old["file"]).unlink(missing_ok=True)
        os.replace(staging, APPS / name)
        record["file"] = name
        if old.get("how") == "flatpak" and old.get("ref"):
            flatpak_remove(old["ref"])     # moved off Flathub to a better build
    elif pick["how"] == "flatpak":
        # Already there from Discover (either scope): take it over, unless
        # this is an update, rather than installing a second copy.
        if update or pick["ref"] not in flatpak_installed():
            flatpak_install(pick["ref"], job, update and old.get("ref") == pick["ref"])
        flatpak_allow(pick["ref"])
        record["ref"] = pick["ref"]
        if old.get("file"):
            (APPS / old["file"]).unlink(missing_ok=True)
    else:
        record["exec"] = pick["exec"]
    job.step("Setting up", 96, force=True)
    make_library(e.get("systems", []))
    try:
        SETUPS.get(e.get("setup", ""), lambda *_: None)(e, record, False)
    except Exception as exc:  # a config we couldn't seed isn't worth failing over
        log(f"{app_id} setup: {exc}")
    write_launcher(e, record)
    write_desktop(e)
    update_json(STATE / "installed.json", lambda d: d.__setitem__(app_id, record))
    write_esde_rules()
    if not e.get("desktop_only") and (e.get("kind") != "frontend" or app_id == "esde"):
        want_shortcut(app_id)


def do_remove(job: Job) -> None:
    app_id = job.data["app"]
    e = entry(app_id)
    rec = installed_db().get(app_id, {})
    job.step("Removing", 30, force=True)
    if rec.get("how") == "plugin" and rec.get("dir") and "/" not in rec["dir"]:
        shutil.rmtree(PLUGINS / rec["dir"], ignore_errors=True)
        update_json(STATE / "installed.json", lambda d: d.pop(app_id, None))
        return
    if rec.get("file") and "/" not in rec["file"]:
        target = APPS / rec["file"]
        if target.is_dir() and not target.is_symlink():
            shutil.rmtree(target, ignore_errors=True)
        else:
            target.unlink(missing_ok=True)
    if rec.get("ref"):
        flatpak_remove(rec["ref"])
        if job.data.get("extra", {}).get("wipe"):
            shutil.rmtree(HOME / ".var" / "app" / rec["ref"], ignore_errors=True)
    if job.data.get("extra", {}).get("wipe"):
        for d in e.get("data_dirs", []):
            shutil.rmtree(HOME / d, ignore_errors=True)
    (BIN / app_id).unlink(missing_ok=True)
    (DESKTOP_DIR / f"steamos-arm-hub-{app_id}.desktop").unlink(missing_ok=True)
    update_json(STATE / "installed.json", lambda d: d.pop(app_id, None))
    write_esde_rules()
    drop_shortcut(app_id)


def wait_turn(job: "Job"):
    """One job at a time. A pack starts a job per app; run together, eight
    downloads, unpacks and installs at once made Game Mode stutter and Decky
    lag. The others wait as Queued (and can still be cancelled)."""
    JOBS.mkdir(parents=True, exist_ok=True)
    lock = open(JOBS / ".running.lock", "w")
    queued = False
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return lock
        except BlockingIOError:
            if job.path.with_suffix(".cancel").exists():
                raise Cancelled()
            if not queued:
                job.step("Queued", 0)
                queued = True
            time.sleep(1.0)


def runner(job_id: str) -> None:
    job = Job(job_id)
    signal.signal(signal.SIGTERM, lambda *_: job.path.with_suffix(".cancel").touch())
    try:
        turn = wait_turn(job)  # held until this process exits
        action = job.data["action"]
        if action == "install":
            do_install(job)
        elif action == "update":
            do_install(job, update=True)
        elif action == "remove":
            do_remove(job)
        job.step("Ready", 100)
        job.finish("done")
    except Cancelled:
        job.finish("cancelled")
    except Exception as exc:
        log(f"job {job_id}: {exc}")
        job.finish("failed", str(exc))


# ------------------------------------------------------ launch & menus ----
def write_launcher(e: dict, rec: dict) -> None:
    BIN.mkdir(parents=True, exist_ok=True)
    p = BIN / e["id"]
    p.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{Path(__file__).resolve()}" run {e["id"]} "$@"\n')
    os.chmod(p, 0o755)


def bottom_env() -> dict:
    """What Game Mode wrote about the second panel (gamescope-session)."""
    path = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "bottom-screen.env"
    out = {}
    try:
        for line in path.read_text().splitlines():
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip().strip("'\"").replace("\\,", ",")
    except OSError:
        pass
    return out


def bottom_touch_name() -> str:
    """The evdev name of the bottom panel's touchscreen. The session lists it
    as names or path:<part of the sysfs path>; the emulators want the name."""
    want = [w for w in bottom_env().get("BOTTOM_TOUCH", "").split(",") if w and w != "none"]
    for ev in sorted(glob.glob("/sys/class/input/event*")):
        name = rd(f"{ev}/device/name")
        syspath = os.path.realpath(f"{ev}/device")
        for w in want:
            if (w.startswith("path:") and w[5:] in syspath) or w == name:
                return name
    return ""


# The hardware video decoder for VA-API clients (Chromium/Electron, FFmpeg):
# msm_drv_video.so drives the Snapdragon video core through V4L2, and
# libgbm.so.1 adds the NV12 buffers Mesa's GBM can't make on Adreno (it
# depends on Mesa's own libgbm under the name libgbm-mesa.so.1).
VA_SYSTEM = Path("/usr/lib/steamos-arm/va")
VA_DIR = ".steamos-arm-va"
FLATPAK_MESA_GBM = "/usr/lib/aarch64-linux-gnu/GL/default/lib/libgbm.so.1"


def _sync_file(src: Path, dst: Path) -> None:
    """Copy when it differs, replacing atomically: a running app may have it mapped."""
    try:
        if dst.stat().st_size == src.stat().st_size and dst.read_bytes() == src.read_bytes():
            return
    except OSError:
        pass
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".new")
    shutil.copyfile(src, tmp)
    os.chmod(tmp, 0o755)
    os.replace(tmp, dst)


def flatpak_video_accel(ref: str, spec: dict) -> list[str]:
    """`flatpak run` options that give a Flatpak app the hardware decoder.

    A sandbox can't see the host's /usr, so the driver is copied into the
    app's own data folder, which it can always read."""
    drv = VA_SYSTEM / "msm_drv_video.so"
    if not drv.exists():
        return []
    dest = HOME / ".var" / "app" / ref / VA_DIR
    try:
        _sync_file(drv, dest / "msm_drv_video.so")
        opts = [f"--env=LIBVA_DRIVERS_PATH={dest}", "--env=LIBVA_DRIVER_NAME=msm"]
        if spec.get("gbm_nv12") and (VA_SYSTEM / "libgbm.so.1").exists():
            _sync_file(VA_SYSTEM / "libgbm.so.1", dest / "lib" / "libgbm.so.1")
            link = dest / "lib" / "libgbm-mesa.so.1"
            if not link.is_symlink() or os.readlink(link) != FLATPAK_MESA_GBM:
                link.unlink(missing_ok=True)
                link.symlink_to(FLATPAK_MESA_GBM)
            opts.append(f"--env=LD_LIBRARY_PATH={dest / 'lib'}")
    except OSError as err:
        log(f"video decoder setup for {ref} failed: {err}")
        return []
    opts += [f"--env={k}={v}" for k, v in spec.get("env", {}).items()]
    if spec.get("command"):
        opts.append(f"--command={spec['command']}")
    return opts


# Flatpaks not started by the hub that should still decode on the video core.
# They get a persistent per-app override instead of launch options.
VIDEO_ACCEL_EXTRA = {"org.mozilla.firefox": {}}


FIREFOX_PREFS_MARK = "// steamos-arm: hardware video decoding"
FIREFOX_PREFS = {
    # Firefox's GPU list doesn't know Adreno on Linux; the decoder is ours.
    "media.hardware-video-decoding.force-enabled": "true",
    # WebRTC (xbox.com/play, video calls) through the hardware decoder too.
    "media.webrtc.hw.h264.enabled": "true",
}


def firefox_prefs() -> None:
    """A marked block in each Firefox profile's user.js (rewritten, not appended)."""
    app = HOME / ".var/app/org.mozilla.firefox"
    block = [FIREFOX_PREFS_MARK] + [f'user_pref("{k}", {v});' for k, v in FIREFOX_PREFS.items()]
    block.append(FIREFOX_PREFS_MARK + " end")
    # Newer Firefox keeps profiles under XDG config, older under ~/.mozilla.
    profiles = [*app.glob("config/mozilla/firefox/*/prefs.js"), *app.glob(".mozilla/firefox/*/prefs.js")]
    for prefs in profiles:
        user = prefs.parent / "user.js"
        try:
            lines = user.read_text().splitlines() if user.exists() else []
        except OSError:
            continue
        if FIREFOX_PREFS_MARK in lines:
            i = lines.index(FIREFOX_PREFS_MARK)
            end = FIREFOX_PREFS_MARK + " end"
            j = lines.index(end, i) if end in lines[i:] else i
            lines[i:j + 1] = []
        new = "\n".join(lines + block) + "\n"
        if not user.exists() or user.read_text() != new:
            tmp = user.with_name("user.js.new")
            tmp.write_text(new)
            os.replace(tmp, user)


def video_accel_sync() -> int:
    """At login: keep the decoder files current in every installed Flatpak
    that uses them, and give the ones the hub doesn't launch an override."""
    try:
        out = subprocess.run(["flatpak", "list", "--app", "--columns=application"],
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1
    installed = set(out.split())
    for ref, spec in VIDEO_ACCEL_EXTRA.items():
        if ref not in installed:
            continue
        opts = flatpak_video_accel(ref, spec)
        if opts:
            subprocess.run(["flatpak", "override", "--user", ref, *opts], timeout=60)
            if ref == "org.mozilla.firefox":
                firefox_prefs()
    for e in catalog():
        va = e.get("video_accel")
        for src in e.get("sources", []):
            if va is not None and src.get("kind") == "flathub" and src.get("ref") in installed:
                flatpak_video_accel(src["ref"], va)      # files only; run() adds the rest
    return 0


def run(app_id: str, args: list[str]) -> None:
    e = entry(app_id)
    rec = installed_db().get(app_id)
    if not rec:
        raise SystemExit(f"{e['title']} isn't installed; install it from Loadout")
    env = dict(os.environ)
    env.update(e.get("env", {}))
    if rec.get("lease"):
        # The bottom-screen builds draw on the lower panel themselves and read
        # its touchscreen; tell them which one it is.
        touch = bottom_touch_name()
        if touch:
            env.setdefault("MELONDS_DRM_LEASE_TOUCH", touch)
    if rec["how"] == "file" and rec.get("start"):
        cmd = [str(APPS / rec["file"] / rec["start"])]
    elif rec["how"] == "file":
        cmd = [str(APPS / rec["file"])]
        # Without FUSE an AppImage can still unpack itself and run.
        if not os.path.exists("/dev/fuse") or not shutil.which("fusermount"):
            env.setdefault("APPIMAGE_EXTRACT_AND_RUN", "1")
    elif rec["how"] == "flatpak":
        va = e.get("video_accel")
        opts = flatpak_video_accel(rec["ref"], va) if va is not None else []
        cmd = ["flatpak", "run", *opts, rec["ref"]]
        if opts:
            cmd += va.get("args", [])
    else:
        cmd = [rec["exec"]]
    # Fixed arguments an app needs here (Electron apps: no Chromium sandbox,
    # which needs a setuid helper the image doesn't have).
    cmd += e.get("args", [])
    os.execvpe(cmd[0], cmd + args, env)


def icon_for(e: dict) -> str:
    """A local icon file for the app, fetched once and cached."""
    spec = e.get("icon", "")
    if spec.startswith("file:"):
        return spec[5:]
    dest = ICON_DIR / f"steamos-arm-hub-{e['id']}.png"
    if dest.exists():
        return str(dest)
    url = ""
    try:
        kind, _, where = spec.partition(":")
        if kind in ("http", "https"):
            url = spec
        elif kind == "flathub":
            url = http_json(f"https://flathub.org/api/v2/appstream/{where}").get("icon") or ""
        elif kind == "github":
            url = f"https://github.com/{where}.png?size=256"
        elif kind in ("forgejo", "gitlab"):
            parts = urllib.parse.urlparse(where)
            repo = parts.path.strip("/")
            if kind == "forgejo":
                info = http_json(f"{parts.scheme}://{parts.netloc}/api/v1/repos/{repo}")
                url = info.get("avatar_url") or info.get("owner", {}).get("avatar_url") or ""
            else:
                info = http_json(f"{parts.scheme}://{parts.netloc}/api/v4/projects/{urllib.parse.quote(repo, safe='')}")
                url = info.get("avatar_url") or ""
        if url:
            ICON_DIR.mkdir(parents=True, exist_ok=True)
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=20) as r:
                dest.write_bytes(r.read())
            return str(dest)
    except Exception as exc:
        log(f"icon for {e['id']}: {exc}")
    return "applications-games"


def fetch_icons() -> None:
    """Every catalog app's icon, so the store shows them before anything is
    installed (icon_for used to run only at install). One runner at a time."""
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    with open(ICON_DIR / ".fetch.lock", "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        for e in catalog():
            if e.get("icon") and not (ICON_DIR / f"steamos-arm-hub-{e['id']}.png").exists():
                icon_for(e)


def fetch_icons_soon() -> None:
    """Start fetch_icons in the background, at most every 10 minutes (an
    offline device would otherwise try on every refresh)."""
    stamp = ICON_DIR / ".fetch.stamp"
    try:
        if time.time() - stamp.stat().st_mtime < 600:
            return
    except OSError:
        pass
    try:
        ICON_DIR.mkdir(parents=True, exist_ok=True)
        stamp.touch()
        subprocess.Popen(["nice", "-n", "10", sys.executable, str(Path(__file__).resolve()), "_icons"],
                         start_new_session=True, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


def write_desktop(e: dict) -> None:
    DESKTOP_DIR.mkdir(parents=True, exist_ok=True)
    cat = {"emulator": "Game;Emulator;", "frontend": "Game;", "app": "Network;"}.get(e.get("kind"), "Game;")
    (DESKTOP_DIR / f"steamos-arm-hub-{e['id']}.desktop").write_text(
        "[Desktop Entry]\nType=Application\n"
        f"Name={e['title']}\nComment={e.get('plays', '')}\n"
        f"Exec={BIN / e['id']} %F\nIcon={icon_for(e)}\nTerminal=false\nCategories={cat}\n"
        f"X-SteamOS-ARM-Hub={e['id']}\n")


def write_esde_rules() -> None:
    """ES-DE finds every hub emulator through its launcher, whatever the
    file is called or wherever it came from."""
    rules = ['<?xml version="1.0"?>', "<!-- Written by Loadout: your installs, by launcher. -->", "<ruleList>"]
    for app_id in sorted(installed_db()):
        try:
            name = entry(app_id).get("esde")
        except KeyError:
            continue
        if name:
            rules += [f'    <emulator name="{name}">', '        <rule type="staticpath">',
                      f"            <entry>{BIN / app_id}</entry>", "        </rule>", "    </emulator>"]
    rules.append("</ruleList>")
    d = HOME / "ES-DE" / "custom_systems"
    d.mkdir(parents=True, exist_ok=True)
    (d / "es_find_rules.xml").write_text("\n".join(rules) + "\n")
    # ES-DE has no ARMSX2 command. A custom system replaces the bundled one,
    # so this is ES-DE's own ps2 entry with ARMSX2 put first.
    systems = d / "es_systems.xml"
    # ours: written by Loadout, or by the Emulator Hub it used to be
    ours = not systems.exists() or any(m in systems.read_text(errors="replace")
                                       for m in ("Written by Loadout", "Emulator Hub"))
    if ours and "armsx2" in installed_db():
        systems.write_text(ESDE_PS2)
    elif ours and systems.exists():
        systems.unlink()


ESDE_PS2 = """<?xml version="1.0"?>
<!-- Written by Loadout: ES-DE's ps2 system with ARMSX2 added. -->
<systemList>
    <system>
        <name>ps2</name>
        <fullname>Sony PlayStation 2</fullname>
        <path>%ROMPATH%/ps2</path>
        <extension>.bin .BIN .chd .CHD .ciso .CISO .cso .CSO .desktop .dump .DUMP .elf .ELF .gz .GZ .m3u .M3U .mdf .MDF .img .IMG .iso .ISO .isz .ISZ .ngr .NRG .zso .ZSO</extension>
        <command label="ARMSX2 (Standalone)">%EMULATOR_ARMSX2% %ROM%</command>
        <command label="PCEE2">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/pcee2_libretro.so %ROM%</command>
        <command label="LRPS2">%EMULATOR_RETROARCH% -L %CORE_RETROARCH%/pcsx2_libretro.so %ROM%</command>
        <command label="Shortcut or script">%ENABLESHORTCUTS% %EMULATOR_OS-SHELL% %ROM%</command>
        <platform>ps2</platform>
        <theme>ps2</theme>
    </system>
</systemList>
"""


# ------------------------------------------------------ emulator setup ----
# Each setup points an emulator at the library and fills in what it needs on
# a handheld. A config the user already has is only touched where it still
# points at our old library (moved=True); otherwise it is left alone.
def ini_set(path: Path, section: str, values: dict, only_new: bool) -> None:
    text = path.read_text(errors="replace") if path.exists() else ""
    if text and only_new:
        return
    lines = text.splitlines()
    head = f"[{section}]"
    if head not in lines:
        lines += ["", head]
    start = lines.index(head) + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("[")), len(lines))
    body = lines[start:end]
    for k, v in values.items():
        row = f"{k} = {v}" if " = " in "\n".join(body) else f"{k}={v}"
        for i, line in enumerate(body):
            if re.match(rf"\s*{re.escape(k)}\s*=", line):
                body[i] = row
                break
        else:
            body.append(row)
    lines[start:end] = body
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).strip("\n") + "\n")


def config_home(rec: dict, ref_dir: str) -> Path:
    """An emulator's ~/.config, or the Flatpak's own copy of it."""
    if rec.get("how") == "flatpak":
        return HOME / ".var" / "app" / rec["ref"] / "config" / ref_dir
    return HOME / ".config" / ref_dir


def setup_retroarch(e, rec, moved):
    lib = library()
    cfg = HOME / ".var/app/org.libretro.RetroArch/config/retroarch/retroarch.cfg"
    values = {
        # Flathub's aarch64 build ships with no core download address at all.
        "core_updater_buildbot_cores_url": "https://buildbot.libretro.com/nightly/linux/aarch64/latest/",
        "rgui_browser_directory": str(lib / "roms"),
        "system_directory": str(lib / "bios"),
        "savefile_directory": str(lib / "saves" / "retroarch"),
        "savestate_directory": str(lib / "states" / "retroarch"),
        # Menu on Select+Start, quit by holding it: no keyboard on a handheld.
        "input_menu_toggle_gamepad_combo": "4",
        "input_quit_gamepad_combo": "4",
        "quit_press_twice": "true",
        "menu_driver": "ozone",
        "video_fullscreen": "true",
    }
    text = cfg.read_text(errors="replace") if cfg.exists() else ""
    if not text:
        # RetroArch copies its Flatpak's skeleton config on first start; a
        # config of ours without it would lack the paths to its assets and
        # cores. Start from the same skeleton, or leave first start to it.
        loc = subprocess.run(["flatpak", "info", "--show-location", "org.libretro.RetroArch"],
                             capture_output=True, text=True, timeout=30).stdout.strip()
        skeleton = Path(loc) / "files" / "etc" / "retroarch.cfg" if loc else None
        if not skeleton or not skeleton.is_file():
            return
        text = skeleton.read_text(errors="replace")
    keep = {} if moved else {k: v for k, v in values.items()
                             if not re.search(rf'^{k}\s*=\s*"[^"]+"', text, re.M)}
    if moved:
        keep = {k: values[k] for k in ("rgui_browser_directory", "system_directory", "savefile_directory", "savestate_directory")}
    for k, v in (keep or {}).items():
        line = f'{k} = "{v}"'
        if re.search(rf"^{k}\s*=", text, re.M):
            text = re.sub(rf"^{k}\s*=.*$", line, text, flags=re.M)
        else:
            text += ("" if text.endswith("\n") or not text else "\n") + line + "\n"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text(text)
    for d in ("saves/retroarch", "states/retroarch"):
        (lib / d).mkdir(parents=True, exist_ok=True)


def setup_duckstation(e, rec, moved):
    lib = library()
    cfg = HOME / ".local/share/duckstation/settings.ini"
    if cfg.exists() and not moved:
        return
    ini_set(cfg, "GameList", {"RecursivePaths": str(lib / "roms" / "psx")}, only_new=False)
    ini_set(cfg, "BIOS", {"SearchDirectory": str(lib / "bios")}, only_new=False)


def setup_dolphin(e, rec, moved):
    lib = library()
    base = config_home(rec, "dolphin-emu")
    ini_set(base / "Dolphin.ini", "General",
            {"ISOPaths": "2", "ISOPath0": str(lib / "roms" / "gc"), "ISOPath1": str(lib / "roms" / "wii")},
            only_new=not moved)


def setup_primehack(e, rec, moved):
    lib = library()
    ini_set(HOME / ".var/app/io.github.shiiion.primehack/config/dolphin-emu/Dolphin.ini", "General",
            {"ISOPaths": "1", "ISOPath0": str(lib / "roms" / "wii")}, only_new=not moved)


def setup_ppsspp(e, rec, moved):
    lib = library()
    base = config_home(rec, "ppsspp") / "PSP" / "SYSTEM"
    ini_set(base / "ppsspp.ini", "General", {"CurrentDirectory": str(lib / "roms" / "psp")}, only_new=not moved)


# Games see Steam's virtual pad in Game Mode. melonDS maps raw SDL joystick
# numbers (out of the box it maps none, so no button works): face buttons
# by position, as on a DS (its A is the right-hand button), d-pad on the
# hat, R3 swaps the screens, L3 toggles fast forward.
MELONDS_PAD = {"A": 1, "B": 0, "X": 3, "Y": 2, "L": 4, "R": 5, "Select": 6, "Start": 7,
               "Up": 257, "Right": 258, "Down": 260, "Left": 264,
               "HK_SwapScreens": 10, "HK_FastForwardToggle": 9}


def setup_melonds(e, rec, moved):
    lib = library()
    cfg = config_home(rec, "melonDS") / "melonDS.toml"
    if cfg.exists() and not moved:
        return
    text = cfg.read_text() if cfg.exists() else ""
    head = {"LastROMFolder": lib / "roms" / "nds", "LastBIOSFolder": lib / "bios"}
    for k, v in head.items():
        line = f'{k} = "{v}"'
        text = re.sub(rf"^{k}\s*=.*$", line, text, flags=re.M) if re.search(rf"^{k}\s*=", text, re.M) else line + "\n" + text
    # Only into a config of ours: a table that's already there can't be
    # opened a second time (melonDS would reject the whole file).
    if "[Instance0]" not in text and "[Instance0.Joystick]" not in text:
        text += "\n[Instance0]\nJoystickID = 0\n\n[Instance0.Joystick]\n" + "".join(f"{k} = {v}\n" for k, v in MELONDS_PAD.items())
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text(text)


def link_into_library(real: Path, inside: Path) -> None:
    """Keep files the emulator insists on finding in its own folder (keys,
    firmware) inside the library instead, through a link."""
    inside.mkdir(parents=True, exist_ok=True)
    if real.is_symlink():
        real.unlink()
    elif real.exists():
        # Already has files: move them into the library once.
        for item in real.iterdir():
            if not (inside / item.name).exists():
                shutil.move(str(item), str(inside / item.name))
        shutil.rmtree(real, ignore_errors=True)
    real.parent.mkdir(parents=True, exist_ok=True)
    real.symlink_to(inside)


def setup_eden(e, rec, moved):
    lib = library()
    link_into_library(HOME / ".local/share/eden/keys", lib / "bios" / "switch" / "keys")
    link_into_library(HOME / ".local/share/eden/nand/system/Contents/registered", lib / "bios" / "switch" / "firmware")
    ini_set(HOME / ".config/eden/qt-config.ini", "UI",
            {"Paths\\gamedirs\\size": "1", "Paths\\gamedirs\\1\\path": str(lib / "roms" / "switch"),
             "Paths\\gamedirs\\1\\deep_scan": "true", "Paths\\gamedirs\\1\\expanded": "true"}, only_new=not moved)


def setup_ryujinx(e, rec, moved):
    lib = library()
    link_into_library(HOME / ".var/app/io.github.ryubing.Ryujinx/config/Ryujinx/system", lib / "bios" / "switch" / "keys")


STEAM_PAD = "engine:sdl,api:controller,guid:030079f6de280000ff11000001000000,maptype:guid+port,port:0"
# SDL game controller numbering; 3DS face buttons by position.
AZAHAR_PAD = {"button_a": "button:1", "button_b": "button:0", "button_x": "button:3", "button_y": "button:2",
              "button_l": "button:9", "button_r": "button:10", "button_select": "button:4",
              "button_start": "button:6", "button_home": "button:5",
              "button_up": "button:11", "button_down": "button:12", "button_left": "button:13", "button_right": "button:14",
              "button_zl": "axis:4,direction:+,threshold:0.500000", "button_zr": "axis:5,direction:+,threshold:0.500000",
              "circle_pad": "axis_x:0,axis_y:1,deadzone:0.050000", "c_stick": "axis_x:2,axis_y:3,deadzone:0.050000"}


def setup_azahar(e, rec, moved):
    lib = library()
    cfg = config_home(rec, "azahar-emu") / "qt-config.ini"
    if not cfg.exists():
        controls = {"profile": "0", "profiles\\size": "1", "profiles\\1\\name": "Default", "profiles\\1\\input_maptype": "2"}
        for k, v in AZAHAR_PAD.items():
            controls[f"profiles\\1\\{k}"] = f'"{STEAM_PAD},{v}"'
            controls[f"profiles\\1\\{k}\\default"] = "false"
        ini_set(cfg, "Controls", controls, only_new=False)
        if rec.get("lease"):
            # The touch screen is on the lower panel: the top window shows
            # the top screen alone.
            ini_set(cfg, "Layout", {"layout_option": "5", "layout_option\\default": "false"}, only_new=False)
    elif not moved:
        return
    # Its own INSTALLED and SYSTEM entries stay first; the library third.
    ini_set(cfg, "UI", {
        "Paths\\gamedirs\\size": "3",
        "Paths\\gamedirs\\1\\path": "INSTALLED", "Paths\\gamedirs\\1\\expanded": "true",
        "Paths\\gamedirs\\2\\path": "SYSTEM", "Paths\\gamedirs\\2\\expanded": "true",
        "Paths\\gamedirs\\3\\path": str(lib / "roms" / "n3ds"),
        "Paths\\gamedirs\\3\\deep_scan": "false", "Paths\\gamedirs\\3\\expanded": "true"}, only_new=False)


def setup_esde(e, rec, moved):
    lib = library()
    settings_xml = HOME / "ES-DE" / "settings" / "es_settings.xml"
    text = settings_xml.read_text() if settings_xml.exists() else '<?xml version="1.0"?>\n'
    row = f'<string name="ROMDirectory" value="{lib / "roms"}" />'
    if 'name="ROMDirectory"' in text:
        if moved:
            text = re.sub(r'<string name="ROMDirectory"[^>]*/>', row, text)
    else:
        text += row + "\n"
    settings_xml.parent.mkdir(parents=True, exist_ok=True)
    settings_xml.write_text(text)
    write_esde_rules()


def setup_simple(subdir: str):
    def go(e, rec, moved):
        (library() / "roms" / subdir).mkdir(parents=True, exist_ok=True)
    return go


def setup_heroic(e, rec, moved):
    """Heroic's first-run defaults, only while it has no settings of its own:
    none of its x86 Wine, DXVK, VKD3D or anti-cheat runtimes (they can't run
    here), and Steam's ARM64 Proton for its own Play button. Games are meant
    to be played from Steam, where Loadout adds them with Proton set."""
    cfg = HOME / ".config/heroic/config.json"
    if cfg.exists():
        return
    common = HOME / ".local/share/Steam/steamapps/common"
    proton = next((common / n for n in ("Proton 11.0 (ARM64)", "Proton Experimental (ARM64)")
                   if (common / n / "proton").exists()), None)
    defaults = {"autoInstallDxvk": False, "autoInstallVkd3d": False, "autoInstallDxvkNvapi": False,
                "eacRuntime": False, "battlEyeRuntime": False, "disableUMU": True,
                "checkForUpdatesOnStartup": False, "addSteamShortcuts": False,
                "defaultInstallPath": str(HOME / "Games/Heroic")}
    if proton:
        defaults["wineVersion"] = {"bin": str(proton / "proton"), "name": proton.name, "type": "proton"}
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text(json.dumps({"defaultSettings": defaults, "version": "v0"}, indent=2) + "\n")


SETUPS = {
    "heroic": setup_heroic,
    "retroarch": setup_retroarch, "duckstation": setup_duckstation, "dolphin": setup_dolphin,
    "primehack": setup_primehack, "ppsspp": setup_ppsspp, "melonds": setup_melonds,
    "eden": setup_eden, "ryujinx": setup_ryujinx, "azahar": setup_azahar, "esde": setup_esde,
    "armsx2": setup_simple("ps2"), "cemu": setup_simple("wiiu"), "rpcs3": setup_simple("ps3"),
    "vita3k": setup_simple("psvita"), "xemu": setup_simple("xbox"), "flycast": setup_simple("dreamcast"),
    "mgba": setup_simple("gba"), "rmg": setup_simple("n64"), "mame": setup_simple("arcade"),
    "scummvm": setup_simple("scummvm"), "dosbox": setup_simple("dos"),
    "ymir": setup_simple("saturn"), "bigpemu": setup_simple("atarijaguar"),
}


# ------------------------------------------------------ Steam library ----
# Steam owns shortcuts.vdf while it runs and rewrites it on exit, so a
# shortcut is queued here. The Decky panel adds queued ones through Steam's
# own client API the moment it sees them; with Steam closed (Desktop Mode)
# the file is edited directly.
STEAM_FILE = STATE / "steam.json"


def want_shortcut(app_id: str) -> None:
    def change(s):
        s.setdefault("made", {})
        s.setdefault("owed", [])
        s.setdefault("drop", [])
        if app_id not in s["made"] and app_id not in s["owed"]:
            s["owed"].append(app_id)
        if app_id in s["drop"]:
            s["drop"].remove(app_id)
    update_json(STEAM_FILE, change)
    if not steam_running():
        flush_shortcuts_offline()


def drop_shortcut(app_id: str) -> None:
    def change(s):
        s.setdefault("drop", [])
        if app_id in s.get("owed", []):
            s["owed"].remove(app_id)
        if app_id in s.get("made", {}) and app_id not in s["drop"]:
            s["drop"].append(app_id)
    update_json(STEAM_FILE, change)
    if not steam_running():
        flush_shortcuts_offline()


def shortcut_spec(app_id: str) -> dict:
    e = entry(app_id)
    return {"app": app_id, "name": e["title"], "exe": str(BIN / app_id), "dir": str(HOME),
            "icon": icon_for(e), "options": "", "art": f"hub:{app_id}" if e.get("art") else "",
            "tag": "Emulators" if e.get("kind") == "emulator" else "Apps"}


# Steam's artwork slots for a shortcut (SetCustomArtworkForApp's asset type)
# and the file each one takes in userdata/<id>/config/grid/.
ART_SLOTS = {"grid": (0, "{appid}p"), "hero": (1, "{appid}_hero"), "logo": (2, "{appid}_logo"),
             "wide": (3, "{appid}")}


def app_art(app_id: str) -> list[dict]:
    """A catalog app's own Steam artwork (its "art" URLs), fetched once and
    cached: [{"slot", "type", "ext", "path"}]."""
    e = entry(app_id)
    cache = CACHE / "art" / f"hub-{app_id}"
    out = []
    for slot, url in (e.get("art") or {}).items():
        if slot not in ART_SLOTS:
            continue
        ext = url.rsplit(".", 1)[-1].lower()
        dest = cache / f"{slot}.{ext}"
        if not dest.exists():
            try:
                cache.mkdir(parents=True, exist_ok=True)
                req = urllib.request.Request(url, headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=20) as r, open(dest.with_suffix(".part"), "wb") as fh:
                    shutil.copyfileobj(r, fh)
                os.replace(dest.with_suffix(".part"), dest)
            except Exception as exc:
                log(f"art for {app_id} ({slot}): {exc}")
                dest.with_suffix(".part").unlink(missing_ok=True)
                continue
        out.append({"slot": slot, "type": ART_SLOTS[slot][0], "ext": ext, "path": str(dest)})
    return out


def steam_pending() -> dict:
    s = read_json(STEAM_FILE, dict)
    custom = s.get("custom", {})
    adds = [shortcut_spec(a) for a in s.get("owed", []) if a in installed_db()]
    adds += [{"app": a, "name": custom[a[7:]]["name"], "exe": custom[a[7:]]["exe"],
              "dir": custom[a[7:]].get("dir") or str(Path(custom[a[7:]]["exe"].strip('"')).parent),
              "icon": "", "options": custom[a[7:]].get("options", ""),
              "compat": custom[a[7:]].get("compat", ""), "art": custom[a[7:]].get("art", ""),
              "tag": custom[a[7:]].get("tag", "Apps")}
             for a in s.get("owed", []) if a.startswith("custom:") and a[7:] in custom]
    # Proton picked for shortcuts already made (e.g. written while Steam was
    # closed, where only Steam itself can set it): the panel applies these.
    compat = [{"app": a, "appid": s["made"][a], "tool": custom[a[7:]]["compat"]}
              for a in s.get("made", {}) if a.startswith("custom:") and a[7:] in custom
              and custom[a[7:]].get("compat") and not custom[a[7:]].get("compat_done")]
    return {"add": adds, "compat": compat,
            "remove": [{"app": a, "appid": s["made"][a]} for a in s.get("drop", []) if a in s.get("made", {})]}


def steam_made(app_id: str, appid: int) -> None:
    def change(s):
        s.setdefault("made", {})[app_id] = int(appid)
        if app_id in s.get("owed", []):
            s["owed"].remove(app_id)
    update_json(STEAM_FILE, change)


def steam_gone(app_id: str) -> None:
    def change(s):
        s.get("made", {}).pop(app_id, None)
        if app_id in s.get("drop", []):
            s["drop"].remove(app_id)
            if app_id.startswith("custom:"):        # taken out on purpose: forget it
                s.get("custom", {}).pop(app_id[7:], None)
    update_json(STEAM_FILE, change)


def steam_running() -> bool:
    for pid in os.listdir("/proc"):
        if pid.isdigit() and rd(f"/proc/{pid}/comm") in ("steam", "steamwebhelper"):
            return True
    return False


def vdf_read(data: bytes) -> dict:
    pos = 0

    def cstr():
        nonlocal pos
        end = data.index(b"\0", pos)
        s = data[pos:end].decode(errors="replace")
        pos = end + 1
        return s

    def obj():
        nonlocal pos
        out = {}
        while True:
            t = data[pos]
            pos += 1
            if t == 8:
                return out
            key = cstr()
            if t == 0:
                out[key] = obj()
            elif t == 1:
                out[key] = cstr()
            elif t == 2:
                out[key] = int.from_bytes(data[pos:pos + 4], "little", signed=True)
                pos += 4
            else:
                raise ValueError(f"vdf type {t}")
    return obj()


def vdf_write(d: dict) -> bytes:
    out = bytearray()
    for k, v in d.items():
        if isinstance(v, dict):
            out += b"\x00" + k.encode() + b"\0" + vdf_write(v)
        elif isinstance(v, int):
            out += b"\x02" + k.encode() + b"\0" + (v & 0xFFFFFFFF).to_bytes(4, "little")
        else:
            out += b"\x01" + k.encode() + b"\0" + str(v).encode() + b"\0"
    return bytes(out) + b"\x08"


def shortcut_appid(exe: str, name: str) -> int:
    import zlib
    return (zlib.crc32((exe + name).encode()) | 0x80000000) - (1 << 32)


def flush_shortcuts_offline() -> None:
    files = glob.glob(str(HOME / ".local/share/Steam/userdata/*/config"))
    if not files:
        return
    pending = steam_pending()
    if not pending["add"] and not pending["remove"]:
        return
    for cfg_dir in files:
        path = Path(cfg_dir) / "shortcuts.vdf"
        try:
            root = vdf_read(path.read_bytes()) if path.exists() else {"shortcuts": {}}
        except (ValueError, IndexError):
            continue
        items = list(root.get("shortcuts", {}).values())
        drop_ids = {int(r["appid"]) & 0xFFFFFFFF for r in pending["remove"]}
        items = [i for i in items if int(i.get("appid", 0)) & 0xFFFFFFFF not in drop_ids]
        for spec in pending["add"]:
            exe = f'"{spec["exe"]}"'
            appid = shortcut_appid(exe, spec["name"])
            if any(int(i.get("appid", 0)) == appid for i in items):
                continue
            items.append({"appid": appid, "AppName": spec["name"], "Exe": exe, "StartDir": f'"{spec["dir"]}"',
                          "icon": spec["icon"], "ShortcutPath": "", "LaunchOptions": spec["options"],
                          "IsHidden": 0, "AllowDesktopConfig": 1, "AllowOverlay": 1, "OpenVR": 0,
                          "Devkit": 0, "DevkitGameID": "", "DevkitOverrideAppID": 0, "LastPlayTime": 0,
                          "FlatpakAppID": "", "tags": {"0": spec["tag"]}})
            if spec.get("art", "").startswith("hub:"):
                grid = Path(cfg_dir) / "grid"
                for a in app_art(spec["art"][4:]):
                    try:
                        grid.mkdir(exist_ok=True)
                        name = ART_SLOTS[a["slot"]][1].format(appid=appid & 0xFFFFFFFF)
                        shutil.copyfile(a["path"], grid / f"{name}.{a['ext']}")
                    except OSError as exc:
                        log(f"art for {spec['app']}: {exc}")
            steam_made(spec["app"], appid & 0xFFFFFFFF)
        for r in pending["remove"]:
            steam_gone(r["app"])
        root["shortcuts"] = {str(i): item for i, item in enumerate(items)}
        path.write_bytes(vdf_write(root))


# -------------------------------------------------------------- BIOS ----
# What an emulator can't run games without, and where in the library it
# goes. Checked by name pattern only: the files are the user's own dumps.
BIOS_NEEDS = {
    "duckstation": ("bios", r"(?i)^(scph|psxonpsp|ps1_rom).*\.bin$", "a PlayStation BIOS (scph….bin) in bios/"),
    "armsx2": ("bios", r"(?i)^(scph|ps2).*\.bin$", "a PlayStation 2 BIOS (….bin) in bios/"),
    "flycast": ("bios/dc", r"(?i)^dc_boot\.bin$", "dc_boot.bin in bios/dc/"),
    "eden": ("bios/switch/keys", r"(?i)^prod\.keys$", "prod.keys in bios/switch/keys/ and firmware in bios/switch/firmware/"),
    "ryujinx": ("bios/switch/keys", r"(?i)^prod\.keys$", "prod.keys in bios/switch/keys/"),
    "ymir": ("bios", r"(?i)^(sega_|saturn|mpr-).*\.bin$", "a Saturn BIOS (….bin) in bios/"),
}


def bios_missing(app_id: str) -> str:
    need = BIOS_NEEDS.get(app_id)
    if not need:
        return ""
    folder, pattern, what = need
    d = library() / folder
    try:
        if any(re.match(pattern, f.name) for f in d.iterdir() if f.is_file() or f.is_symlink()):
            return ""
    except OSError:
        pass
    return f"Needs {what}"


# --------------------------------------------------- reset & your own ----
# The settings files the setups seed, per app and install kind ({cfg} is
# the emulator's config home, ~/.config or the Flatpak's own).
CONFIG_FILES = {
    "retroarch": [".var/app/org.libretro.RetroArch/config/retroarch/retroarch.cfg"],
    "duckstation": [".local/share/duckstation/settings.ini"],
    "dolphin": ["{cfg}/dolphin-emu/Dolphin.ini"],
    "ppsspp": ["{cfg}/ppsspp/PSP/SYSTEM/ppsspp.ini"],
    "melonds": ["{cfg}/melonDS/melonDS.toml"],
    "azahar": ["{cfg}/azahar-emu/qt-config.ini"],
    "eden": [".config/eden/qt-config.ini"],
}


def reset_settings(app_id: str) -> dict:
    """Put an emulator's settings back to how the hub sets it up. The old
    file is kept next to it (.before-reset-<date>), games and saves stay."""
    rec = installed_db().get(app_id)
    if not rec or app_id not in CONFIG_FILES:
        raise RuntimeError("Nothing to reset for that app")
    cfg_home = (f".var/app/{rec['ref']}/config" if rec.get("how") == "flatpak" else ".config")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    moved = []
    for rel in CONFIG_FILES[app_id]:
        f = HOME / rel.format(cfg=cfg_home)
        if f.exists():
            f.rename(f.with_name(f"{f.name}.before-reset-{stamp}"))
            moved.append(str(f))
    e = entry(app_id)
    SETUPS.get(e.get("setup", ""), lambda *_: None)(e, rec, False)
    return {"reset": moved}


def found_files() -> list[dict]:
    """AppImages put on the device by hand, not by the hub: offered as Steam
    shortcuts (the hub's own files and half-done downloads are left out)."""
    ours = {r.get("file") for r in installed_db().values()}
    made = read_json(STEAM_FILE, dict).get("custom", {})
    out = []
    for d in (APPS, HOME / "Downloads", *[Path(c) / "Downloads" for c in sd_cards()]):
        for f in sorted(d.glob("*")) if d.is_dir() else []:
            if f.is_file() and f.suffix.lower() == ".appimage" and not f.name.startswith(".") and f.name not in ours:
                key = hashlib.sha1(str(f).encode()).hexdigest()[:12]
                out.append({"key": key, "path": str(f), "name": nice_name(f.name), "added": key in made})
    return out


def nice_name(filename: str) -> str:
    base = re.sub(r"\.appimage$", "", filename, flags=re.I)
    base = re.sub(r"[-_](x86_64|aarch64|arm64|anylinux|linux|v?\d[\w.]*)\b.*$", "", base, flags=re.I)
    return re.sub(r"[-_.]+", " ", base).strip() or filename


def add_file(path: str) -> dict:
    f = Path(path).expanduser()
    if not f.is_file():
        raise RuntimeError("That file isn't there")
    f.chmod(f.stat().st_mode | 0o100)       # owner exec, nothing wider
    key = hashlib.sha1(str(f).encode()).hexdigest()[:12]

    def change(s):
        s.setdefault("custom", {})[key] = {"name": nice_name(f.name), "exe": str(f)}
        s.setdefault("owed", [])
        if f"custom:{key}" not in s["owed"]:
            s["owed"].append(f"custom:{key}")
    update_json(STEAM_FILE, change)
    if not steam_running():
        flush_shortcuts_offline()
    return {"ok": True, "key": key}


def open_desktop() -> dict:
    """Desktop-only tools: switch to Desktop Mode to use them."""
    subprocess.Popen(["steamos-session-select", "plasma"], start_new_session=True)
    return {"ok": True}


# ------------------------------------------------------------- status ----
def status() -> dict:
    dev = device()
    db = installed_db()
    flat = flatpak_installed()
    running = {j["app"]: j for j in jobs()}
    made = read_json(STEAM_FILE, dict).get("made", {})
    apps = []
    for e in catalog():
        rec = db.get(e["id"])
        if rec and rec.get("how") == "flatpak" and rec.get("ref") not in flat:
            rec = None              # removed behind our back
        if not rec:
            # Installed some other way (Discover): it shows as installed, and
            # Install just takes it over (launcher, Steam shortcut, library).
            ref = next((s_["ref"] for s_ in e["sources"] if s_["kind"] == "flathub" and s_["ref"] in flat), None)
            adopt = bool(ref)
        else:
            adopt = False
        if rec and rec.get("how") == "file" and not (APPS / rec.get("file", "")).exists():
            rec = None
        if rec and rec.get("how") == "plugin" and not (PLUGINS / rec.get("dir", "-")).is_dir():
            rec = None
        if e.get("retired") and not rec:
            continue        # replaced by another app: kept only so old installs still run and uninstall
        builtin = e["sources"][0]["kind"] == "builtin" and Path(e["sources"][0]["exec"]).exists()
        heavy = "heavy_below" in e and chip_rank(dev["chip"]) < chip_rank(e["heavy_below"])
        best = next((s for s in e["sources"] if fits(s.get("when"), dev)), None)
        apps.append({
            "id": e["id"], "title": e["title"], "plays": e.get("plays", ""), "kind": e.get("kind", "app"),
            "note": e.get("note", ""), "heavy": heavy, "desktop_only": bool(e.get("desktop_only")),
            "resettable": e["id"] in CONFIG_FILES,
            "bios": bios_missing(e["id"]) if rec else "",
            "starter": "starter" in e and chip_rank(dev["chip"]) >= chip_rank(e["starter"]),
            "installed": bool(rec) or builtin, "builtin": builtin, "elsewhere": adopt,
            "version": (rec or {}).get("version", ""), "label": (rec or {}).get("label") or (best or {}).get("label", ""),
            "update": (rec or {}).get("update", ""),
            "update_notes": (rec or {}).get("update_notes", "") if (rec or {}).get("update") else "",
            "job": running.get(e["id"]),
            "steam_appid": made.get(e["id"]) if rec else None,
            "icon": str(ICON_DIR / f"steamos-arm-hub-{e['id']}.png") if (ICON_DIR / f"steamos-arm-hub-{e['id']}.png").exists() else "",
            "available": best is not None,
        })
    if any(not a["icon"] for a in apps):
        fetch_icons_soon()
    return {"device": dev, "library": str(library()), "sd": sd_cards(),
            "home_label": HOME_LABELS[home_kind()], "apps": apps, "found": found_files()}


def check_updates() -> dict:
    """Ask every source of an installed file app whether there's newer.
    Flatpaks update through Flathub and are left to the update-all job.
    The feeds are asked first, without holding the record's lock: that can
    take a while, and an install finishing meanwhile must not wait on it."""
    dev = device()
    latest = {}
    for app_id, rec in installed_db().items():
        if rec.get("how") != "file":
            continue
        try:
            idx, pick = resolve(entry(app_id), dev)
        except Exception:
            continue
        if pick.get("how") == "file":
            latest[app_id] = (idx, pick.get("version", ""), pick.get("notes", ""))
    found = {}

    def change(d):
        for app_id, (idx, version, notes) in latest.items():
            rec = d.get(app_id)
            if not rec or rec.get("how") != "file":
                continue
            newer = version != rec.get("version") or idx != rec.get("source")
            rec["update"] = version if newer else ""
            rec["update_notes"] = notes if newer else ""
            if newer:
                found[app_id] = version
    update_json(STATE / "installed.json", change)
    return {"updates": found}


def update_all() -> dict:
    started = [start_job("update", a) for a in installed_db()]
    return {"jobs": [j["id"] for j in started]}


def starter() -> dict:
    st = status()
    picks = [a["id"] for a in st["apps"] if a["starter"] and not a["installed"] and a["available"]]
    return {"jobs": [start_job("install", a)["id"] for a in picks], "apps": picks}


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    out = None
    if cmd == "_run":
        runner(rest[0])
        return 0
    if cmd == "_icons":
        fetch_icons()
        return 0
    if cmd == "run":
        run(rest[0], rest[1:])
        return 0
    if cmd == "video-accel-sync":
        return video_accel_sync()
    if cmd == "device":
        out = device()
    elif cmd == "catalog":
        out = {"apps": catalog()}
    elif cmd == "status":
        out = status()
    elif cmd == "jobs":
        out = {"jobs": jobs()}
    elif cmd in ("install", "update", "remove"):
        out = start_job(cmd, rest[0], wipe="--wipe" in rest)
    elif cmd == "starter":
        out = starter()
    elif cmd == "update-all":
        out = update_all()
    elif cmd == "check-updates":
        out = check_updates()
    elif cmd == "cancel":
        out = cancel(rest[0])
    elif cmd == "library":
        out = set_library(rest[0]) if rest else {"library": str(library()), "sd": sd_cards()}
    elif cmd == "steam-pending":
        out = steam_pending()
    elif cmd == "steam-made":
        steam_made(rest[0], int(rest[1]))
        out = {"ok": True}
    elif cmd == "steam-gone":
        steam_gone(rest[0])
        out = {"ok": True}
    elif cmd == "reset":
        out = reset_settings(rest[0])
    elif cmd == "add-file":
        out = add_file(rest[0])
    elif cmd == "desktop":
        out = open_desktop()
    elif cmd == "icons":
        for e in catalog():
            icon_for(e)
        out = {"ok": True}
    else:
        print(f"unknown command {cmd}", file=sys.stderr)
        return 2
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (KeyError, RuntimeError, ValueError) as exc:
        print(json.dumps({"error": str(exc).strip("'")}))
        sys.exit(1)
