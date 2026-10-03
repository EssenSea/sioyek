#!/usr/bin/env bash
# =============================================================================
# resolve_preset_bindir.sh <preset-name>
# Print the binaryDir of a CMake configure preset, following the inherits chain
# and expanding ${sourceDir} / ${presetName}. Used by CI to locate the build dir
# without hardcoding it.
# =============================================================================
set -eu

PRESET="${1:?usage: resolve_preset_bindir.sh <preset-name>}"
PRESETS_FILE="${2:-CMakePresets.json}"

python3 - "$PRESET" "$PRESETS_FILE" <<'PYEOF'
import json, sys

preset_name, presets_file = sys.argv[1], sys.argv[2]
with open(presets_file) as f:
    data = json.load(f)

presets = {p["name"]: p for p in data.get("configurePresets", [])}

def resolve(name, key):
    seen = set()
    while name and name not in seen:
        seen.add(name)
        p = presets.get(name, {})
        if key in p:
            return p[key]
        name = p.get("inherits")
    return None

bd = resolve(preset_name, "binaryDir")
if bd is None:
    sys.exit("no binaryDir found for preset %s" % preset_name)
bd = bd.replace("${sourceDir}", ".").replace("${presetName}", preset_name)
print(bd)
PYEOF
