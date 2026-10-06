#!/usr/bin/env python3
"""Build a konkr-update package (manifest + `.tar.gz`) directly from a release
image, so full-image releases that only ship split `.7z` parts (no separate
`.tar.gz` update package) can still be installed in place through the
SteamOS Update app, without a manual reflash.

Reads its input from a release image -- still split into `.7z` parts, or
already extracted to a plain `.img` -- by loop-mounting the image's
ROCKNIX/STORAGE/HOME partitions (the same partition layout and labels the
UFS internal installer uses; see external-and-mods/ufs-install/README.md and
ufs-partition.py's OURS = ("ROCKNIX", "STORAGE", "HOME")). The resulting
package has the exact same shape scripts/build-update-package.py produces
from a completed build tree, so it goes through konkr-update.py's existing
`stage` command unchanged.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('konkr_update', HERE / 'konkr-update.py')
_updater = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_updater)
FORMAT = _updater.FORMAT
SOC_MODELS = _updater.SOC_MODELS


def run(*args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def digest(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(4 << 20), b''): h.update(b)
    return h.hexdigest()


def verify_checksums(parts, sums_file):
    """Verify each part against a sibling SHA256SUMS file, when there is one.

    This is the integrity check for this path: the official release page
    publishes SHA256SUMS for the `.7z` parts, there is no separate official
    checksum for the package this script derives from them.
    """
    if not sums_file.is_file(): return
    wanted = {}
    for line in sums_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'): continue
        sha, name = line.split(maxsplit=1)
        wanted[name.lstrip('*')] = sha.lower()
    missing = [p.name for p in parts if p.name not in wanted]
    if missing: raise ValueError(f'SHA256SUMS has no entry for: {", ".join(missing)}')
    for part in parts:
        if digest(part) != wanted[part.name]:
            raise ValueError(f'checksum mismatch: {part.name}')


def locate_parts(first_part):
    m = re.match(r'(.+\.7z)\.\d{3}$', first_part.name)
    if not m: return [first_part]
    pattern = re.sub(r'\.\d{3}$', '.*', first_part.name)
    return sorted(first_part.parent.glob(pattern))


def extract_image(source, work):
    """Join/extract `.7z` parts (or pass through a plain `.img`) into `work`."""
    source = Path(source).resolve()
    if source.suffix == '.img': return source
    sevenzip = shutil.which('7z') or shutil.which('7zz') or shutil.which('7za')
    if not sevenzip: raise ValueError('7z is not installed')
    parts = locate_parts(source)
    verify_checksums(parts, source.parent / 'SHA256SUMS')
    run(sevenzip, 'x', f'-o{work}', '-y', str(parts[0]))
    images = list(work.glob('*.img'))
    if len(images) != 1: raise ValueError(f'expected exactly one .img in the archive, found {len(images)}')
    return images[0]


def attach_loop(image):
    return run('losetup', '--find', '--show', '--partscan', '--read-only', str(image),
               capture_output=True, text=True).stdout.strip()


def partition_by_label(loopdev, label):
    """Find a partition by GPT PARTLABEL, then by filesystem LABEL, then by
    position (ROCKNIX=1, STORAGE=2, HOME=3), matching how the boot hook finds
    them on GPT internal installs and MBR SD-card images alike."""
    out = run('lsblk', '-Ppno', 'NAME,TYPE,PARTLABEL,LABEL', loopdev, capture_output=True, text=True).stdout
    parts = [dict(re.findall(r'(\w+)="([^"]*)"', line)) for line in out.splitlines()]
    parts = [p for p in parts if p.get('TYPE') == 'part']
    for key in ('PARTLABEL', 'LABEL'):
        hit = [p['NAME'] for p in parts if p.get(key, '').upper() == label]
        if len(hit) == 1: return hit[0]
    index = {'ROCKNIX': 1, 'STORAGE': 2, 'HOME': 3}[label]
    hit = [p['NAME'] for p in parts if re.search(rf'p{index}$', p['NAME'])]
    return hit[0] if len(hit) == 1 else None


def copy_tree(src, dst):
    dst.mkdir(parents=True, exist_ok=True)
    # Host SELinux labels are not part of the image (and can't be stripped on
    # SELinux hosts); keep everything else, including file capabilities.
    run('rsync', '-aHAX', '--numeric-ids', '--filter=-x security.selinux', str(src) + '/', str(dst) + '/')


def build(args):
    if os.geteuid() != 0: raise ValueError('building the package needs administrator access')
    if args.soc not in SOC_MODELS: raise ValueError(f'unknown SoC {args.soc!r}')
    output = Path(args.output).resolve()
    # The extracted image is ~16 GB; /tmp is usually a small tmpfs, so work
    # next to the source (e.g. the SD card the release was downloaded to).
    workdir = Path(args.workdir).resolve() if args.workdir else Path(args.source).resolve().parent
    with tempfile.TemporaryDirectory(prefix='.konkr-image-', dir=workdir) as temp:
        work = Path(temp)
        image = extract_image(args.source, work)
        loopdev = attach_loop(image)
        mounts = {}
        try:
            for label in ('ROCKNIX', 'STORAGE', 'HOME'):
                part = partition_by_label(loopdev, label)
                if not part: raise ValueError(f'image has no {label} partition')
                mp = work / f'mnt-{label.lower()}'; mp.mkdir()
                run('mount', '-o', 'ro', part, str(mp))
                mounts[label] = mp
            stage = work / 'stage'
            for rel in ('usr', 'opt', 'etc', 'var/lib/overlays/etc/upper'):
                src = mounts['STORAGE'] / rel
                if src.exists(): copy_tree(src, stage / 'root' / rel)
            for name in ('konkr-control', 'decky-lsfg-vk'):
                src = mounts['HOME'] / 'steamos/homebrew/plugins' / name
                if not src.is_dir(): raise ValueError(f'image is missing the {name} Decky plugin')
                copy_tree(src, stage / 'home/steamos/homebrew/plugins' / name)
            kernel = mounts['ROCKNIX'] / 'KERNEL'
            if not kernel.is_file(): raise ValueError('image has no boot KERNEL')
            (stage / 'boot').mkdir(parents=True, exist_ok=True)
            shutil.copy2(kernel, stage / 'boot/KERNEL')
            files = {}
            for p in sorted(stage.rglob('*')):
                if not p.is_file() or p.is_symlink(): continue
                files[str(p.relative_to(stage))] = digest(p)
            (stage / 'manifest.json').write_text(json.dumps({'format': FORMAT, 'architecture': 'aarch64',
                'devices': SOC_MODELS[args.soc], 'version': args.version, 'files': files}, indent=2))
            part_tar = output.with_name(output.name + '.part')
            run('tar', '--xattrs', '--xattrs-exclude=security.selinux', '--acls', '--numeric-owner', '-czf', str(part_tar),
                '-C', str(stage), 'manifest.json', 'root', 'home', 'boot')
            os.replace(part_tar, output)
        finally:
            for mp in mounts.values(): subprocess.run(['umount', str(mp)], check=False)
            subprocess.run(['losetup', '-d', loopdev], check=False)
    print(output, digest(output))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('source', help='first `.7z` part, or a plain `.img`')
    ap.add_argument('--soc', required=True, choices=sorted(SOC_MODELS))
    ap.add_argument('--version', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--workdir', help='scratch directory with room for the extracted image '
                    '(default: the source\'s directory)')
    args = ap.parse_args()
    try:
        build(args)
    except Exception as e:
        print('ERROR:', e, file=sys.stderr); return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
