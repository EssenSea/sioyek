#!/usr/bin/env python3
"""Fail when a self-contained preset enables Qt cmake-side deployment.

WHY: SIOYEK_INSTALL_QT_DEPLOY=ON runs Qt own deployment helper, which rewrites
the RUNPATH of every Qt plugin it finds and aborts the ENTIRE install when one
cannot be patched. Both self-contained presets used to enable it and therefore
could not complete "cmake --install" at all -- linux-portable and linux-appimage
were unusable and nothing tested that.

Those presets must instead get their Qt runtime from the system (portable) or
from linuxdeploy --plugin qt (AppImage).
"""
import json, sys

SELF_CONTAINED = ("linux-portable", "linux-appimage")

doc = json.load(open(sys.argv[1]))
offenders = [
    p["name"]
    for p in doc.get("configurePresets", [])
    if p.get("name") in SELF_CONTAINED
    and p.get("cacheVariables", {}).get("SIOYEK_INSTALL_QT_DEPLOY") == "ON"
]
if offenders:
    print("these presets enable the cmake-side Qt deployment, which cannot complete:")
    for name in offenders:
        print(f"  {name}")
    sys.exit(1)
print("self-contained presets do not request the cmake-side Qt deployment")
