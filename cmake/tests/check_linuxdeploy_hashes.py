#!/usr/bin/env python3
"""Verify the linuxdeploy integrity hashes recorded in cmake/SioyekAppImage.cmake.

A blank, truncated or duplicated value cannot be correct. A TRUNCATED DOWNLOAD
produces a well-formed sha256 that is simply wrong, which is how a bad value was
recorded once -- making every AppImage build fail at the integrity check with no
obvious cause. This checks the shape of the values; only a real download can
confirm a hash matches the asset.
"""
import re, sys, pathlib

src = pathlib.Path(sys.argv[1]).read_text()
found = re.findall(
    r"set\(SIOYEK_LINUXDEPLOY(_QT)?_SHA256\s+\"([0-9a-f]*)\"",
    src,
)
if len(found) != 2:
    print(f"expected 2 hash definitions, found {len(found)}")
    sys.exit(1)
hashes = [value for _, value in found]
for name, h in zip(("linuxdeploy", "linuxdeploy-qt"), hashes):
    if len(h) != 64:
        print(f"{name}: hash is {len(h)} chars, expected 64 (blank or truncated?)")
        sys.exit(1)
if hashes[0] == hashes[1]:
    print("both hashes are identical; at least one must be wrong")
    sys.exit(1)
print("both hashes are full-length and distinct")
