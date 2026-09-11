#!/usr/bin/env python3
"""Generate hicolor icon PNGs from Obsidian's 512x512 resources/icon.png.

Usage: mkicons.py <icon.png> <destdir>
Writes <destdir>/usr/share/icons/hicolor/<N>x<N>/apps/obsidian.png for
the same sizes upstream's amd64 .deb ships.
"""
import os
import sys

from PIL import Image

SIZES = (16, 24, 32, 48, 64, 128, 256, 512)

src, dest = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
for n in SIZES:
    d = os.path.join(dest, "usr/share/icons/hicolor/%dx%d/apps" % (n, n))
    os.makedirs(d, exist_ok=True)
    out = im if im.size == (n, n) else im.resize((n, n), Image.LANCZOS)
    out.save(os.path.join(d, "obsidian.png"), optimize=True)
    print("icon %dx%d" % (n, n))
