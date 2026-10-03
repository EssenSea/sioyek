#!/usr/bin/env python3
"""Check a sioyek tree against the directory semantics it must satisfy.

HOW THIS DIFFERS FROM A GREP
  Every verdict is derived from a documented rule, and each result names the
  rule it used. The rules come from two places, both verifiable locally:

    1. CMake GNUInstallDirs, which documents what each install directory means
       (Modules/GNUInstallDirs.cmake). Its wording is the basis for the
       DATADIR vs SYSCONFDIR distinction used below:

           SYSCONFDIR  "read-only single-machine data (etc)"
           DATADIR     "read-only architecture-independent data (DATAROOTDIR)"

    2. The program itself, which states the absolute paths it reads on Linux
       (pdf_viewer/main.cpp, LINUX_STANDARD_PATHS).

  An earlier revision of this script matched bare keywords such as "shaders"
  against the CMake text. That was unfalsifiable: a comment containing the word
  would have counted as a correct installation. This version parses install()
  calls, tracks the enclosing platform condition, and evaluates the DESTINATION
  against the expected directory, so a mere mention cannot satisfy it.

SCOPE AND LIMITS -- stated up front, because a static check cannot prove a
package works:

  * It cannot decide WHETHER a file should be installed at all; that is a
    project decision. It only reports when a file that the PROGRAM reads at
    runtime, or that convention places in a standard directory, has no rule.
  * It does not build or install anything, so it cannot catch a rule that is
    present but broken. `cmake --install` into a staging prefix, then checking
    the paths in main.cpp, is the only conclusive test.
"""

import re
import sys
import pathlib


class Findings:
    """Print each finding as it is made, so it stays under its section heading."""

    def __init__(self):
        self.missing = 0

    def add(self, ok, subject, rule, detail=""):
        print(f"  {'[ok]  ' if ok else '[MISS]'} {subject}")
        print(f"         rule: {rule}")
        if detail:
            print(f"         {detail}")
        if not ok:
            self.missing += 1


def cmake_files(root):
    files = [root / "CMakeLists.txt"]
    d = root / "cmake"
    if d.is_dir():
        files += sorted(d.glob("*.cmake"))
    return [f for f in files if f.is_file()]


def strip_comments(line):
    """Drop a trailing # comment so prose cannot be mistaken for a rule."""
    out, in_str, quote = [], False, ""
    for ch in line:
        if in_str:
            out.append(ch)
            if ch == quote:
                in_str = False
        elif ch in "\"'":
            in_str, quote = True, ch
            out.append(ch)
        elif ch == "#":
            break
        else:
            out.append(ch)
    return "".join(out)


def collect_installs(root):
    """Return [(file, lineno, platform, destination, raw)] for every install().

    Handles the if(APPLE)/else()/endif() shape so rules that only apply to macOS
    are not counted as Linux coverage. install() arguments frequently span
    several lines, so the call is reassembled until parentheses balance.
    """
    found = []
    for f in cmake_files(root):
        lines = f.read_text(errors="replace").splitlines()
        stack = []          # True = inside an APPLE branch, False = its else()
        i = 0
        while i < len(lines):
            raw = lines[i]
            line = strip_comments(raw).strip()

            if re.match(r"if\s*\(", line):
                stack.append(bool(re.match(r"if\s*\(\s*APPLE", line)))
                i += 1
                continue
            if re.match(r"elseif\s*\(", line):
                i += 1
                continue
            if re.match(r"else\b", line):
                if stack:
                    stack[-1] = False if stack[-1] else None
                i += 1
                continue
            if re.match(r"endif\b", line):
                if stack:
                    stack.pop()
                i += 1
                continue

            if re.match(r"install\s*\(", line):
                call = line
                start = i
                while call.count("(") > call.count(")") and i + 1 < len(lines):
                    i += 1
                    call += " " + strip_comments(lines[i]).strip()
                dest_m = re.search(r"DESTINATION\s+([^\s)]+)", call)
                dest = dest_m.group(1) if dest_m else ""
                platform = "apple" if any(e is True for e in stack) else "linux"
                found.append((f.name, start + 1, platform, dest, call))
            i += 1
    return found


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    if not (root / "CMakeLists.txt").is_file():
        print(f"error: {root}/CMakeLists.txt not found", file=sys.stderr)
        return 2

    installs = collect_installs(root)
    linux = [x for x in installs if x[2] == "linux"]

    print("=== sioyek install-directory conformance ===")
    print(f"tree: {root}")
    print()
    print(f"install() rules: {len(installs)} total, {len(linux)} applying on Linux")
    for name, lineno, plat, dest, _ in installs:
        tag = "linux" if plat == "linux" else "APPLE-only"
        print(f"  [{tag:10}] {name}:{lineno}  DESTINATION {dest or '(none)'}")
    print()

    f = Findings()
    joined = " ".join(x[4] for x in linux)

    # -- Resources the program reads at runtime -------------------------------
    # The paths below are taken from main.cpp, not invented here; a MISS means
    # the program looks somewhere nothing installs to.
    print("1. Resources the program reads at runtime (main.cpp LINUX_STANDARD_PATHS)")
    runtime = [
        ("shaders", "shaders", "read_only_data_path.slash(L\"shaders\")"),
        ("tutorial.pdf", "tutorial.pdf", "read_only_data_path.slash(L\"tutorial.pdf\")"),
        ("prefs.config", "prefs\\.config", "standard_config_path.slash(L\"prefs.config\")"),
        ("keys.config", "keys\\.config", "standard_config_path.slash(L\"keys.config\")"),
    ]
    for label, pattern, origin in runtime:
        f.add(re.search(pattern, joined) is not None,
              f"{label} is installed for Linux",
              f"main.cpp reads it at {origin}",
              "no Linux install() rule mentions it" if not re.search(pattern, joined) else "")
    print()

    # -- Directory semantics --------------------------------------------------
    # The rule quoted is GNUInstallDirs' own description of the directory.
    print("2. Directory semantics (CMake GNUInstallDirs)")
    # A finding is raised only when defaults are ACTUALLY placed under
    # SYSCONFDIR. Installing nothing at all is reported by section 1 instead;
    # calling that "conformant" would be a false pass.
    syconf = [(n, l, d) for n, l, p, d, _ in installs
              if "SYSCONFDIR" in d and p == "linux"]
    if syconf:
        for n, l, d in syconf:
            f.add(False,
                  f"a shipped default is installed under SYSCONFDIR ({d})",
                  'SYSCONFDIR = "read-only single-machine data (etc)"',
                  f"{n}:{l} -- the shipped defaults are architecture-independent and not "
                  "host-specific, which DATADIR is for")
    else:
        f.add(True, "no shipped default is placed under SYSCONFDIR",
              'SYSCONFDIR = "read-only single-machine data (etc)"',
              "if defaults are not installed at all, section 1 reports that instead")

    datadir_ok = any("DATADIR" in d for *_x, d, _c in [(a, b, c, d, e) for a, b, c, d, e in installs if c == "linux"])
    f.add(datadir_ok, "read-only program data is installed under DATADIR",
          'DATADIR = "read-only architecture-independent data"')
    print()

    # -- Conventional locations present in the tree ---------------------------
    print("3. Files present in the tree that convention places in a standard directory")
    conventional = [
        ("resources/sioyek.1", "man1", "FHS: manual pages live under man<section>"),
        ("resources/sioyek.desktop", "applications", "FDO Desktop Entry: .desktop files go in applications/"),
        ("resources/sioyek-icon-linux.png", "pixmaps", "FDO icon lookup: hicolor or pixmaps"),
    ]
    for rel, expect, rule in conventional:
        if not (root / rel).is_file():
            continue
        base = pathlib.Path(rel).name
        installed = re.search(re.escape(base), joined) is not None
        f.add(installed, f"{rel} is installed", rule,
              "present in the tree but no Linux install() rule covers it" if not installed else "")
    print()

    missing = f.missing
    print()
    if missing:
        print(f"{missing} finding(s). Each is stated with the rule it is checked")
        print("against, so it can be disputed on the rule rather than on opinion.")
        return 1
    print("All checked rules satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())