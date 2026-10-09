#!/usr/bin/env python3
"""Minimal Android boot image (header v0) writer for ROCKNIX ABL.

Same layout ROCKNIX produces with AOSP mkbootimg.py:
  --kernel_offset 0 --ramdisk_offset 0 --tags_offset 0 --header_version 0
  (base 0x10000000), ramdisk = b"dummy", os_version 12.0.0.
ABL decompresses the gzip kernel and scans the DTBs appended after it.

Without --ramdisk it writes that dummy ramdisk (the initramfs is then built
into the kernel, EMBED_INITRAMFS in soc.env).
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import os
import struct
from pathlib import Path

BOOT_MAGIC = b"ANDROID!"
BASE = 0x10000000


def pad(data: bytes, page: int) -> bytes:
    rem = len(data) % page
    return data if rem == 0 else data + b"\0" * (page - rem)


def os_version_field(major: int, minor: int, patch: int, year: int, month: int) -> int:
    ver = (major << 14) | (minor << 7) | patch
    lvl = ((year - 2000) << 4) | month
    return (ver << 11) | lvl


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk")
    ap.add_argument("--cmdline", default="")
    ap.add_argument("--pagesize", type=int, default=2048)
    ap.add_argument("--kernel-addr", type=lambda v: int(v, 0), default=BASE)
    ap.add_argument("--ramdisk-addr", type=lambda v: int(v, 0), default=BASE)
    ap.add_argument("--tags-addr", type=lambda v: int(v, 0), default=BASE)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    kernel = Path(a.kernel).read_bytes()
    ramdisk = Path(a.ramdisk).read_bytes() if a.ramdisk else b"dummy"
    cmd = a.cmdline.encode("ascii")
    if len(cmd) >= 512:
        raise SystemExit(f"cmdline too long ({len(cmd)} >= 512)")

    if "SOURCE_DATE_EPOCH" in os.environ:
        today = datetime.datetime.fromtimestamp(
            int(os.environ["SOURCE_DATE_EPOCH"]), tz=datetime.timezone.utc
        ).date()
    else:
        today = datetime.date.today()
    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, b""):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))

    hdr = struct.pack(
        "<8s10I16s512s32s1024s",
        BOOT_MAGIC,
        len(kernel), a.kernel_addr,    # kernel size / addr
        len(ramdisk), a.ramdisk_addr,  # ramdisk size / addr
        0, BASE + 0x00F00000,          # second size / addr
        a.tags_addr,                   # tags addr
        a.pagesize,
        0,                             # header_version
        os_version_field(12, 0, 0, today.year, today.month),
        b"",                           # name
        cmd,
        sha.digest().ljust(32, b"\0"),
        b"",                           # extra cmdline
    )
    img = pad(hdr, a.pagesize) + pad(kernel, a.pagesize) + pad(ramdisk, a.pagesize)
    Path(a.out).write_bytes(img)
    print(f"{a.out}: {len(img)} bytes, kernel {len(kernel)}, cmdline {len(cmd)} chars")


if __name__ == "__main__":
    main()
