#!/usr/bin/env python3
"""loadout: the store on top of the hub engine (hub.py).

hub.py installs, updates and removes; this adds what a store needs around it:
what your game library holds and what to get for it, what an emulator still
needs, ready-made sets, putting any game or app you have into Steam, and the
games Heroic installed. Runs as the user, JSON out, like hub.py; any command
it doesn't know goes to hub.py.

  loadout.py discover                 library by system, what to get, bundles
  loadout.py bios <app>               files an emulator needs: found or missing
  loadout.py inspect <path>           what a file is and how it would be added
  loadout.py add-game <path> [--as windows|linux|rom|apk] [--name NAME]
                                      [--app EMULATOR] [--proton TOOL]
  loadout.py art <title>              Steam store artwork for a title
  loadout.py store-games              games Heroic installed, and which are in Steam
  loadout.py add-store-game <store> <id> [--proton TOOL]
  loadout.py added | remove-added <key>   games you put in Steam through Loadout
  loadout.py compat-done <key>        the panel set that shortcut's Proton
  loadout.py sizes                    disk space each installed app takes
  loadout.py bundle <id>              install a bundle (only what's missing)
"""
from __future__ import annotations

import base64
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import hub  # noqa: E402

DEFAULT_PROTON = "proton_experimental"

# ------------------------------------------------------- game files ----
# Extensions per system, for counting a library and for telling which
# emulator a dropped file is for. Disc images (.iso, .chd, .cue) fit several
# systems; the folder they're in decides, or the user picks.
EXT = {
    "nes": {".nes", ".unf", ".fds"}, "snes": {".sfc", ".smc"}, "gb": {".gb"}, "gbc": {".gbc"},
    "gba": {".gba"}, "genesis": {".md", ".gen", ".smd"}, "mastersystem": {".sms"},
    "gamegear": {".gg"}, "n64": {".n64", ".z64", ".v64"}, "pcengine": {".pce"},
    "atari2600": {".a26"}, "psx": {".cue", ".chd", ".pbp", ".m3u", ".bin"},
    "psp": {".iso", ".cso", ".pbp", ".chd"}, "nds": {".nds"},
    "n3ds": {".3ds", ".cci", ".cia", ".3dsx", ".cxi"}, "gc": {".rvz", ".gcm", ".iso", ".ciso", ".gcz"},
    "wii": {".rvz", ".wbfs", ".iso", ".wad"}, "ps2": {".iso", ".chd", ".cso", ".gz"},
    "switch": {".nsp", ".xci", ".nsz"}, "wiiu": {".wua", ".wux", ".rpx"}, "ps3": {".pkg", ".iso"},
    "psvita": {".vpk"}, "xbox": {".iso", ".xiso"}, "dreamcast": {".chd", ".gdi", ".cdi"},
    "saturn": {".chd", ".cue"}, "atarijaguar": {".j64", ".jag"}, "neogeo": {".zip"},
    "arcade": {".zip", ".7z"}, "mame": {".zip", ".7z"}, "dos": {".zip", ".exe", ".bat"},
}
# Who plays a system best when several can; anything else falls back to the
# first installed emulator that lists it.
BEST = {
    "psx": "duckstation", "ps2": "armsx2", "gc": "dolphin", "wii": "dolphin", "n3ds": "azahar",
    "nds": "melonds", "psp": "ppsspp", "switch": "eden", "wiiu": "cemu", "ps3": "rpcs3",
    "psvita": "vita3k", "xbox": "xemu", "dreamcast": "flycast", "saturn": "ymir",
    "n64": "rmg", "gba": "mgba", "gb": "mgba", "gbc": "mgba", "atarijaguar": "bigpemu",
    "mame": "mame", "dos": "dosbox", "scummvm": "scummvm",
}
SKIP = {".txt", ".md", ".nfo", ".jpg", ".png", ".xml", ".dat", ".sav", ".srm", ".state"}

# What each emulator needs before it plays anything, in the library: the
# folder, then each file as (label, filename pattern, required).
BIOS = {
    "duckstation": ("bios", [("PlayStation BIOS", r"(?i)^(scph|psxonpsp|ps1_rom).*\.bin$", True)]),
    "armsx2": ("bios", [("PlayStation 2 BIOS", r"(?i)^(scph|ps2).*\.bin$", True)]),
    "flycast": ("bios/dc", [("dc_boot.bin", r"(?i)^dc_boot\.bin$", True),
                            ("dc_flash.bin (optional)", r"(?i)^dc_flash\.bin$", False)]),
    "eden": ("bios/switch", [("keys/prod.keys", r"(?i)^keys/prod\.keys$", True),
                             ("firmware/ (.nca files)", r"(?i)^firmware/.+\.nca$", True)]),
    "ryujinx": ("bios/switch", [("keys/prod.keys", r"(?i)^keys/prod\.keys$", True),
                                ("firmware/ (.nca files)", r"(?i)^firmware/.+\.nca$", False)]),
    "ymir": ("bios", [("Saturn BIOS", r"(?i)^(sega_|saturn|mpr-).*\.bin$", True)]),
    "retroarch": ("bios", [("PlayStation BIOS for PS1 cores (optional)", r"(?i)^scph.*\.bin$", False),
                           ("Neo Geo neogeo.zip (optional)", r"(?i)^neogeo\.zip$", False)]),
}


def out(obj) -> None:
    print(json.dumps(obj))


def files_in(d: Path, depth: int = 2) -> list[Path]:
    found = []
    try:
        for p in d.iterdir():
            if p.name.startswith("."):
                continue
            if p.is_dir() and depth > 1:
                found += files_in(p, depth - 1)
            elif p.is_file():
                found.append(p)
    except OSError:
        pass
    return found


def count_games(system: str, d: Path) -> int:
    exts = EXT.get(system)
    files = [f for f in files_in(d) if f.suffix.lower() not in SKIP]
    if system == "psx":
        # a .cue next to its .bin tracks, or an .m3u for a multi-disc game,
        # counts once
        cues = {f.stem for f in files if f.suffix.lower() in (".cue", ".m3u")}
        files = [f for f in files if not (f.suffix.lower() == ".bin" and f.stem.split(" (Track")[0] in cues)]
    if system in ("scummvm", "ps3") and not files:
        return sum(1 for p in d.iterdir() if p.is_dir() and not p.name.startswith(".")) if d.is_dir() else 0
    return sum(1 for f in files if not exts or f.suffix.lower() in exts)


# ----------------------------------------------------------- discover ----
def player_for(system: str, apps: list[dict]) -> dict | None:
    """The installed app that plays a system, else the best one to get."""
    lists = [a for a in apps if system in a.get("systems", [])]
    have = [a for a in lists if a["installed"]]
    best = BEST.get(system)
    pick = lambda pool: next((a for a in pool if a["id"] == best), pool[0] if pool else None)  # noqa: E731
    return pick(have) if have else pick([a for a in lists if a["available"]])


def discover() -> dict:
    st = hub.status()
    by_id = {e["id"]: e for e in hub.catalog()}
    apps = [dict(a, systems=by_id.get(a["id"], {}).get("systems", [])) for a in st["apps"]]
    roms = hub.library() / "roms"
    systems = []
    for d in sorted(roms.iterdir()) if roms.is_dir() else []:
        if not d.is_dir() or d.name.startswith("."):
            continue
        n = count_games(d.name, d)
        if not n:
            continue
        p = player_for(d.name, apps)
        systems.append({
            "system": d.name, "name": hub.SYSTEM_NAMES.get(d.name, d.name), "games": n,
            "app": p["id"] if p else "", "app_title": p["title"] if p else "",
            "ready": bool(p and p["installed"]), "bios": bios(p["id"])["missing"] if p and p["installed"] else [],
        })
    get = [s for s in systems if s["app"] and not s["ready"]]
    suggestions = []
    for app_id in dict.fromkeys(s["app"] for s in get):
        mine = [s for s in get if s["app"] == app_id]
        suggestions.append({"app": app_id, "title": mine[0]["app_title"],
                            "games": sum(s["games"] for s in mine), "systems": [s["name"] for s in mine]})
    suggestions.sort(key=lambda s: -s["games"])
    return {"library": str(hub.library()), "systems": systems, "suggestions": suggestions,
            "bundles": bundles(st), "device": st["device"]}


def bundles(st: dict | None = None) -> list[dict]:
    st = st or hub.status()
    apps = {a["id"]: a for a in st["apps"]}
    outl = []
    for b in hub.read_json(hub.CATALOG, {}).get("_bundles", []):
        members = [apps[i] for i in b["apps"] if i in apps and apps[i]["available"]]
        if not members:
            continue
        outl.append({"id": b["id"], "title": b["title"], "about": b.get("about", ""),
                     "apps": [m["id"] for m in members],
                     "missing": [m["id"] for m in members if not m["installed"]],
                     "heavy": [m["id"] for m in members if m.get("heavy")]})
    return outl


def install_bundle(bundle_id: str) -> dict:
    b = next((x for x in bundles() if x["id"] == bundle_id), None)
    if not b:
        raise RuntimeError("no such bundle")
    return {"jobs": [hub.start_job("install", a)["id"] for a in b["missing"]], "apps": b["missing"]}


# --------------------------------------------------------------- BIOS ----
def bios(app_id: str) -> dict:
    need = BIOS.get(app_id)
    if not need:
        return {"app": app_id, "folder": "", "files": [], "missing": []}
    folder, items = need
    base = hub.library() / folder
    have = [str(f.relative_to(base)) for f in files_in(base, 3)] if base.is_dir() else []
    rows, missing = [], []
    for label, pattern, required in items:
        hit = next((h for h in have if re.match(pattern, h)), "")
        rows.append({"label": label, "found": hit, "required": required})
        if required and not hit:
            missing.append(label)
    return {"app": app_id, "folder": str(base), "files": rows, "missing": missing}


# ------------------------------------------------------- add a game ----
def elf_arch(f: Path) -> str:
    try:
        head = f.read_bytes()[:20] if f.stat().st_size < 4096 else f.open("rb").read(20)
    except OSError:
        return ""
    if head[:4] != b"\x7fELF":
        return ""
    machine = int.from_bytes(head[18:20], "little")
    return {183: "arm64", 62: "x86_64", 3: "x86"}.get(machine, "other")


def title_from(f: Path) -> str:
    stem = f.stem if f.is_file() else f.name
    stem = re.sub(r"\s*[\(\[][^)\]]*[\)\]]", "", stem)          # (USA) [!] (Disc 1)
    stem = re.sub(r"[-_.](setup|launcher|win64|win32|x64|shipping)$", "", stem, flags=re.I)
    stem = re.sub(r"[_.]+", " ", stem)
    return re.sub(r"\s+", " ", stem).strip() or f.name


def systems_for(f: Path) -> list[str]:
    parent = f.parent.name.lower()
    ext = f.suffix.lower()
    fits = [s for s, exts in EXT.items() if ext in exts]
    if parent in fits:
        return [parent]
    return fits


def inspect(path: str) -> dict:
    f = Path(path).expanduser()
    if not f.exists():
        raise RuntimeError("That file isn't there")
    ext = f.suffix.lower()
    st = hub.status()
    by_id = {e["id"]: e for e in hub.catalog()}
    apps = [dict(a, systems=by_id.get(a["id"], {}).get("systems", [])) for a in st["apps"]]
    info = {"path": str(f), "name": title_from(f), "as": "", "note": "", "choices": []}
    if ext in (".exe", ".msi", ".bat", ".lnk"):
        info.update({"as": "windows", "proton": DEFAULT_PROTON,
                     "note": "Runs with Steam's Proton."})
        if re.search(r"(?i)(setup|install|unins)", f.stem):
            info["note"] = ("Looks like an installer: add it, run it once from Steam to install the game, "
                            "then add the game's own .exe.")
    elif ext in (".apk", ".apkm", ".xapk", ".apks"):
        ok = Path("/usr/bin/konkr-apk").exists()
        info.update({"as": "apk" if ok else "", "note": "Installed into Android; it gets its own Steam title."
                     if ok else "Android apps aren't available on this device."})
    elif ext == ".appimage" or elf_arch(f) or ext == ".sh":
        arch = elf_arch(f) if ext != ".appimage" else ""
        info.update({"as": "linux", "note": "x86 program: runs through FEX, slower than an ARM build."
                     if arch in ("x86_64", "x86") else ""})
    else:
        systems = systems_for(f)
        for s in systems:
            p = player_for(s, apps)
            if p:
                info["choices"].append({"system": s, "name": hub.SYSTEM_NAMES.get(s, s), "app": p["id"],
                                        "app_title": p["title"], "installed": p["installed"]})
        if info["choices"]:
            info["as"] = "rom"
            c = info["choices"][0]
            if not c["installed"]:
                info["note"] = f"Needs {c['app_title']}, which Loadout installs first."
        else:
            info["note"] = "Loadout doesn't know this kind of file."
    return info


def custom_key(*parts: str) -> str:
    return hashlib.sha1("\0".join(parts).encode()).hexdigest()[:12]


def queue_custom(key: str, rec: dict) -> dict:
    def change(s):
        s.setdefault("custom", {})[key] = rec
        s.setdefault("owed", [])
        if f"custom:{key}" not in s["owed"] and f"custom:{key}" not in s.get("made", {}):
            s["owed"].append(f"custom:{key}")
    hub.update_json(hub.STEAM_FILE, change)
    if not hub.steam_running():
        hub.flush_shortcuts_offline()
    return {"ok": True, "key": key, "name": rec["name"]}


def add_game(path: str, as_: str = "", name: str = "", app: str = "", proton: str = "") -> dict:
    info = inspect(path)
    kind = as_ or info["as"]
    f = Path(info["path"])
    title = name or info["name"]
    if kind == "windows":
        return queue_custom(custom_key("win", str(f)), {
            "name": title, "exe": str(f), "dir": str(f.parent), "options": "",
            "compat": proton or DEFAULT_PROTON, "art": title, "tag": "Games", "kind": "windows"})
    if kind == "linux":
        f.chmod(f.stat().st_mode | 0o100)
        return queue_custom(custom_key("linux", str(f)), {
            "name": title, "exe": str(f), "dir": str(f.parent), "options": "",
            "art": title, "tag": "Games", "kind": "linux"})
    if kind == "apk":
        r = subprocess.run(["/usr/bin/konkr-apk", "install", str(f)], capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError((r.stderr or r.stdout).strip().splitlines()[-1] if (r.stderr or r.stdout) else "install failed")
        return {"ok": True, "name": title, "android": True}
    if kind == "rom":
        choice = next((c for c in info["choices"] if not app or c["app"] == app), None)
        if not choice:
            raise RuntimeError("Pick which system this game is for")
        if not choice["installed"]:
            job = hub.start_job("install", choice["app"])
        else:
            job = None
        rec = queue_custom(custom_key("rom", str(f)), {
            "name": title, "exe": str(hub.BIN / choice["app"]), "dir": str(f.parent),
            "options": f'"{f}"', "art": title, "tag": hub.SYSTEM_NAMES.get(choice["system"], "Games"),
            "kind": "rom", "app": choice["app"]})
        rec["installing"] = job["id"] if job else ""
        return rec
    raise RuntimeError(info["note"] or "Can't add that file")


def added_games() -> dict:
    """What you put in Steam through Loadout (Add a game, Heroic games)."""
    s = hub.read_json(hub.STEAM_FILE, dict)
    made, owed = s.get("made", {}), s.get("owed", [])
    games = []
    for key, rec in s.get("custom", {}).items():
        a = f"custom:{key}"
        if a in made or a in owed:
            games.append({"key": key, "name": rec["name"], "kind": rec.get("kind", "linux"),
                          "path": rec.get("options", "").strip('"') if rec.get("kind") == "rom" else rec["exe"],
                          "appid": made.get(a), "app": rec.get("app", ""), "proton": rec.get("compat", "")})
    return {"games": sorted(games, key=lambda g: g["name"].lower())}


def remove_added(key: str) -> dict:
    """Take an added game out of Steam (its files stay where they are)."""
    hub.drop_shortcut(f"custom:{key}")

    def change(s):
        a = f"custom:{key}"
        if a not in s.get("made", {}):
            s.get("custom", {}).pop(key, None)
    hub.update_json(hub.STEAM_FILE, change)
    return {"ok": True}


def compat_done(key: str) -> dict:
    def change(s):
        c = s.get("custom", {}).get(key)
        if c:
            c["compat_done"] = True
    hub.update_json(hub.STEAM_FILE, change)
    return {"ok": True}


# ------------------------------------------------------------ artwork ----
STEAM_CDN = "https://shared.steamstatic.com/store_item_assets/steam/apps/{id}/{file}"
ART_FILES = [(0, "library_600x900_2x.jpg"), (1, "library_hero.jpg"), (2, "logo.png"), (3, "header.jpg")]


def art(title: str) -> dict:
    """Artwork from the Steam store when the game is sold there (most PC games,
    many console ports): the closest title match, or nothing. "hub:<id>" is a
    catalog app's own artwork instead."""
    if title.startswith("hub:"):
        assets = [{"type": a["type"], "ext": a["ext"],
                   "data": base64.b64encode(Path(a["path"]).read_bytes()).decode()}
                  for a in hub.app_art(title[4:])]
        return {"found": bool(assets), "assets": assets}
    q = urllib.parse.quote(title)
    try:
        res = hub.http_json(f"https://store.steampowered.com/api/storesearch/?term={q}&l=english&cc=US")
    except Exception:
        return {"found": False}
    items = (res or {}).get("items") or []
    norm = lambda t: re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()  # noqa: E731
    best, score = None, 0.0
    for it in items[:8]:
        r = difflib.SequenceMatcher(None, norm(title), norm(it.get("name", ""))).ratio()
        if r > score:
            best, score = it, r
    if not best or score < 0.72:
        return {"found": False}
    cache = hub.CACHE / "art" / str(best["id"])
    cache.mkdir(parents=True, exist_ok=True)
    assets = []
    for asset, name in ART_FILES:
        dest = cache / name
        if not dest.exists():
            try:
                req = urllib.request.Request(STEAM_CDN.format(id=best["id"], file=name),
                                             headers={"User-Agent": "Loadout"})
                with urllib.request.urlopen(req, timeout=20) as r, open(dest, "wb") as fh:
                    shutil.copyfileobj(r, fh)
            except Exception:
                dest.unlink(missing_ok=True)
                continue
        assets.append({"type": asset, "ext": name.rsplit(".", 1)[1],
                       "data": base64.b64encode(dest.read_bytes()).decode()})
    return {"found": bool(assets), "steam_name": best.get("name"), "steam_id": best["id"], "assets": assets}


# ------------------------------------------------------- Heroic games ----
HEROIC = hub.HOME / ".config" / "heroic"


def store_games() -> dict:
    """What Heroic installed from Epic, GOG and Amazon, with the .exe Steam
    should start; and whether each is in the Steam library already."""
    made = hub.read_json(hub.STEAM_FILE, dict)
    custom = made.get("custom", {})
    games = []

    def add(store, gid, title, folder, exe):
        if not exe:
            return
        key = custom_key("store", store, gid)
        full = Path(folder) / exe if not Path(exe).is_absolute() else Path(exe)
        games.append({"store": store, "id": gid, "title": title, "folder": str(folder), "exe": str(full),
                      "in_steam": f"custom:{key}" in made.get("made", {}) or f"custom:{key}" in made.get("owed", []),
                      "windows": full.suffix.lower() == ".exe"})

    epic = hub.read_json(HEROIC / "legendaryConfig/legendary/installed.json", dict)
    for gid, g in (epic or {}).items():
        add("epic", gid, g.get("title", gid), g.get("install_path", ""), g.get("executable", ""))
    gog = hub.read_json(HEROIC / "gog_store/installed.json", dict)
    for g in (gog or {}).get("installed", []):
        folder = g.get("install_path", "")
        info = hub.read_json(Path(folder) / f"goggame-{g.get('appName')}.info", dict) if folder else {}
        task = next((t for t in info.get("playTasks", []) if t.get("isPrimary")), None) if info else None
        add("gog", g.get("appName", ""), g.get("title") or info.get("name", g.get("appName", "")),
            folder, (task or {}).get("path", ""))
    amazon = hub.read_json(HEROIC / "nile_config/nile/installed.json", list)
    lib = {x.get("product", {}).get("id"): x for x in hub.read_json(HEROIC / "nile_config/nile/library.json", list) or []}
    for g in amazon or []:
        folder = g.get("path", "")
        fuel = hub.read_json(Path(folder) / "fuel.json", dict) if folder else {}
        exe = ((fuel.get("Main") or {}).get("Command")) or ""
        title = (lib.get(g.get("id"), {}).get("product", {}) or {}).get("title", g.get("id", ""))
        add("amazon", g.get("id", ""), title, folder, exe)
    return {"heroic": HEROIC.is_dir(), "games": games}


def add_store_game(store: str, gid: str, proton: str = "") -> dict:
    g = next((x for x in store_games()["games"] if x["store"] == store and x["id"] == gid), None)
    if not g:
        raise RuntimeError("Heroic doesn't list that game as installed")
    exe = Path(g["exe"])
    return queue_custom(custom_key("store", store, gid), {
        "name": g["title"], "exe": str(exe), "dir": str(exe.parent), "options": "",
        "compat": (proton or DEFAULT_PROTON) if g["windows"] else "", "art": g["title"],
        "tag": {"epic": "Epic Games", "gog": "GOG", "amazon": "Amazon Games"}[store], "kind": "store"})


# -------------------------------------------------------------- sizes ----
def sizes() -> dict:
    sizes_ = {}
    flat = {}
    try:
        r = subprocess.run(["flatpak", "list", "--app", "--columns=application,size"],
                           capture_output=True, text=True, timeout=30)
        for line in r.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) == 2:
                flat[parts[0]] = parts[1]
    except (OSError, subprocess.TimeoutExpired):
        pass
    for app_id, rec in hub.installed_db().items():
        if rec.get("how") == "flatpak" and rec.get("ref") in flat:
            sizes_[app_id] = flat[rec["ref"]]
        elif rec.get("how") == "file" and rec.get("file"):
            f = hub.APPS / rec["file"]
            target = f if f.is_file() else None
            n = f.stat().st_size if target else sum(x.stat().st_size for x in files_in(f, 6)) if f.is_dir() else 0
            sizes_[app_id] = f"{n / 1e9:.1f} GB" if n >= 1e9 else f"{n / 1e6:.0f} MB"
    return {"sizes": sizes_}


# ---------------------------------------------------------------- CLI ----
def flag(rest: list[str], name: str) -> str:
    if name in rest:
        i = rest.index(name)
        if i + 1 < len(rest):
            v = rest[i + 1]
            del rest[i:i + 2]
            return v
    return ""


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 0
    cmd, rest = argv[0], list(argv[1:])
    if cmd == "discover":
        out(discover())
    elif cmd == "bios":
        out(bios(rest[0]))
    elif cmd == "bundles":
        out({"bundles": bundles()})
    elif cmd == "bundle":
        out(install_bundle(rest[0]))
    elif cmd == "inspect":
        out(inspect(rest[0]))
    elif cmd == "add-game":
        as_, name, app, proton = flag(rest, "--as"), flag(rest, "--name"), flag(rest, "--app"), flag(rest, "--proton")
        out(add_game(rest[0], as_, name, app, proton))
    elif cmd == "art":
        out(art(" ".join(rest)))
    elif cmd == "store-games":
        out(store_games())
    elif cmd == "add-store-game":
        proton = flag(rest, "--proton")
        out(add_store_game(rest[0], rest[1], proton))
    elif cmd == "added":
        out(added_games())
    elif cmd == "remove-added":
        out(remove_added(rest[0]))
    elif cmd == "compat-done":
        out(compat_done(rest[0]))
    elif cmd == "sizes":
        out(sizes())
    else:
        return hub.main(argv)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (KeyError, RuntimeError, ValueError, IndexError) as exc:
        print(json.dumps({"error": str(exc).strip("'")}))
        sys.exit(1)
