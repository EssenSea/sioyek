# sioyek CMake build system

This directory contains sioyek's **CMake build, packaging, testing and CI
infrastructure**. It is designed to be:

* **modular** – each concern lives in its own module (`Sioyek*.cmake`);
* **robust across distros** – dependency resolution handles CMake config
  packages, Find modules and pkg-config;
* **reusable by downstream packagers** – a single, complete install contract;
* **verifiable** – a deterministic contract test suite runs via CTest.

> Historical note: the project originally built with qmake. CMake is now the
> primary system; the qmake files still exist for the legacy release scripts.

---

## 1. Layout

```
cmake/
├── README.md                 (this file)
├── SioyekBuildTypes.cmake    optimization level, strip, LTO, ccache, unity
├── SioyekDependencies.cmake  unified resolver (config -> module -> pkg-config)
├── SioyekMupdf.cmake         mupdf consumption contract (system|vendored)
├── SioyekSQLite.cmake        SQLite consumption contract (system|vendored)
├── SioyekInstall.cmake       authoritative install manifest
├── SioyekPackaging.cmake     CPack configuration
├── SioyekTesting.cmake       CTest registration
├── SioyekWarnings.cmake      warning policy + third-party isolation
└── tests/                    contract regression tests (bash)
```

---

## 1b. Repository build layout (where everything lives)

CMake is the source of truth for the build. The pieces that matter:

* `CMakeLists.txt` — top-level project definition (Qt6 target, warnings, install).
* `CMakePresets.json` — the supported configure/build/package presets
  (`linux-release`, `linux-debug`, `linux-relwithdebinfo`, `linux-portable`,
  `linux-appimage`, `linux-vendored`, `linux-ci`, plus `macos-*` / `windows-*`).
  Preset schema v6 means **CMake >= 3.25** when using presets; a direct
  `cmake -S . -B build` still works with CMake >= 3.16.
* `Makefile` — a thin, hand-written, **tracked** wrapper around the presets.
  Targets: `build`, `test`, `install`, `package`, `appimage`, `format`,
  `format-check`, `lint`, `deps`, `clean`, `distclean`, `clean-build`,
  `clean-deps`, `clean-stage`, `clean-packages`, `clean-in-source`,
  `list-presets`, `help`. A git-ignored `local.mk` can override `PRESET`,
  `CMAKE_EXTRA_FLAGS`, `PREFIX`, `DESTDIR`, `JOBS`, ... (see
  `contrib/local.mk.example`). **The Makefile is authored and tracked: no clean
  target may ever delete it** (see §5).
* `cmake/Sioyek*.cmake` — modular concerns: `BuildTypes` (optimization, strip,
  LTO, ccache, unity), `Dependencies` (unified config/module/pkg-config
  resolver), `Mupdf` and `SQLite` (consumption contracts), `Install` (the
  authoritative install manifest), `Packaging` (CPack), `Testing` (CTest
  registration), `Warnings`, `Clean`.
* `cmake/tests/` — self-contained bash *contract* tests, registered with CTest
  as `contract.*` and runnable via `cmake/tests/run_all.sh`.
* `.github/workflows/` — `cmake_build.yml` (contract tests + gcc/clang build
  matrix) and the release pipelines `build_and_release.yml` /
  `preview_release.yml`.

### Upstream topology: `mupdf/` and `zlib/` are submodules

`mupdf` and `zlib` are **first-level directories of the upstream repository**
(they appear at the top of `upstream/main` and `upstream/development`), but they
are **git submodules**, not directly-tracked trees:

* `mupdf/` -> `https://github.com/ArtifexSoftware/mupdf` (the rendering core),
* `zlib/`  -> `https://github.com/madler/zlib`.

`git ls-files` contains **no** `mupdf/**` or `zlib/**` entries — only the
submodule pointers in `.gitmodules`. That is why, e.g., a checkout shows them as
directories at the root while `git diff` never reports their *contents* as
changes: they move as pinned commits.

Implications for build/CI work:

* `git submodule update --init --recursive` is required before a vendored build
  (mupdf's own thirdparty submodules are needed too).
* **Treat the submodules as read-only inputs.** Never build in-tree inside
  `mupdf/` or `zlib/` from CMake; direct outputs into the build directory
  (`OUT=<build-dir>/mupdf-out`). Clean legacy in-tree residue only via
  `clean-deps` (see §5) — never delete submodule sources.

---

## 2. Quick start

### Makefile wrapper (recommended for everyday use)

A thin, Makefile-conventional wrapper is provided at the repository root; it
just drives the CMake presets:

```sh
make                        # build (default PRESET=linux-release)
make PRESET=linux-vendored  # build a specific preset
make test                   # build + run CTest
make install DESTDIR=/tmp/stage
make distclean              # remove build/ and all generated artifacts
make clean-build            # remove the whole build/ tree (all presets)
make help                   # list all targets
```

A git-ignored `local.mk` (see `contrib/local.mk.example`) can override `PRESET`,
`CMAKE_EXTRA_FLAGS`, `PREFIX`, `DESTDIR`, `JOBS`, ...

### Direct CMake

```sh
# Configure + build + test (vendored mupdf, reproducible):
git submodule update --init --recursive
cmake --preset linux-vendored
cmake --build --preset linux-vendored -j"$(nproc)"
ctest --test-dir build/linux-vendored --output-on-failure

# Or, without presets:
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"
ctest --test-dir build --output-on-failure
```

---

## 3. Modules in detail

### 3.1 `SioyekBuildTypes.cmake`

Controls build type, optimization and binary size.

| Option | Default | Effect |
|---|---|---|
| `SIOYEK_STRIP_ON_INSTALL` | `OFF` | strip the installed binary |
| `SIOYEK_PACKAGE_STRIP` | `OFF` | strip binaries inside CPack packages |
| `SIOYEK_ENABLE_LTO` | `OFF` | interprocedural optimization |
| `SIOYEK_ENABLE_CCACHE` | `AUTO` | use ccache/sccache if present **and its cache dir is writable**; `AUTO` silently falls back (with a warning) on an unusable cache, `ON` fails fast with guidance, `OFF` disables |
| `SIOYEK_UNITY_BUILD` | `OFF` | CMake unity build (fewer TUs) |
| `SIOYEK_SIZE_OPTIMIZATIONS` | `ON` | `-ffunction-sections -fdata-sections` + `--gc-sections --as-needed` |
| `SIOYEK_HIDDEN_VISIBILITY` | `OFF` | `-fvisibility=hidden -fvisibility-inlines-hidden` |

#### Additional optimizations

* **LTO** (`SIOYEK_ENABLE_LTO`): enabled by default for Release-like builds
  (Release / MinSizeRel / RelWithDebInfo), automatically skipped for Debug and
  when the toolchain does not support it (`check_ipo_supported`).
* **Hidden visibility** (`SIOYEK_HIDDEN_VISIBILITY`, default OFF): mainly
  benefits shared libraries/DLLs. On an executable the measured gain was
  **zero**; it is exposed as opt-in.
* **Vendored SQLite trimming** (`SIOYEK_SQLITE_TRIM`, default ON, see
  `SioyekSQLite.cmake`): sets only `SQLITE_DQS=0` (disable the double-quoted
  string misfeature) on the vendored amalgamation. `SQLITE_OMIT_*` macros are
  **deliberately not used**: they remove function *definitions* that the SQL
  parser still *calls*, which under LTO produces undefined references at link
  time (`sqlite3Alter*`, `sqlite3Analyze`, `sqlite3Attach/Detach`,
  `sqlite3VtabArg*`). `SQLITE_OMIT_AUTOINCREMENT` would also break sioyek,
  which uses `AUTOINCREMENT`.

#### Measured size impact (this host, system mupdf, stripped install)

| Configuration | Installed size |
|---|---|
| `-O3`, no LTO, no section GC | 5,292,616 B |
| `-O2` + section GC + as-needed | 4,764,032 B |
| `-O2` + section GC + **LTO** | **4,567,056 B** |
| `-O2` + section GC + LTO + hidden visibility | 4,567,056 B (no change) |

> Host/compiler/toolchain dependent; illustrative only. LTO roughly added
> ~1 minute of build time on this host.

**Optimization level.** Release uses **`-O2`** (not CMake's default `-O3`):
`-O3` is more aggressive about inlining/unrolling, tends to *increase* code
size and compile time, and gives marginal gains for this codebase. This is
applied only for single-config generators and only when the user has not
overridden `CMAKE_*_FLAGS_RELEASE`.

### 3.2 `SioyekDependencies.cmake`

A single resolver `sioyek_find_dependency(NAME ... PKG_NAMES ... OUT_TARGET ...
OUT_VERSION ...)` that tries, in order:

1. `find_package(<Name>)` (CMake config package or Find module);
2. `pkg-config` via `pkg_check_modules`.

It returns a normalized imported target. This matters because distributions
ship dependencies in different forms (e.g. a `pkg-config` file on one distro, a
`CMake` config package on another).

### 3.3 `SioyekMupdf.cmake`

Chooses the mupdf source:

* **system** when the system version is in the verified range
  `[1.26.11, 1.27)`;
* **system** in the extended range `[1.27, 1.29)` **only** when
  `SIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF=ON`;
* **vendored** otherwise (built from the `mupdf/` submodule).

Options: `SIOYEK_USE_SYSTEM_MUPDF` = `AUTO|ON|OFF` (default `AUTO`).

#### Font embedding (vendored)

mupdf embeds several font groups. Object-file sizes measured on this host:

| Group | Files | Size |
|---|---|---|
| CJK | `han/*.ttc` + `droid/*.ttf` | ~31.9 MB |
| Noto | `noto/*.otf|ttf` | ~12.8 MB |
| SIL | `sil/*.cff` | ~0.2 MB |

For a static (vendored) build these dominate the binary size (~44 MB stripped).

`SIOYEK_MUPDF_UNEMBED_FONTS` (vendored only) selects which groups to drop. Note
the underlying mupdf macros: `-DTOFU_CJK` drops han+droid, whereas `-DTOFU`
drops **only** noto+sil — so `ALL` passes both (`-DTOFU -DTOFU_CJK`) to drop
every group.

| Value | Drops (groups) | Stripped size (this host) |
|---|---|---|
| `OFF` (default) | none | ~44 MB |
| `CJK` | han + droid | **~22.5 MB (measured)** |
| `CJK_LANG` | han only | not measured |
| `ALL` | han + droid + noto + sil | ~9–10 MB (estimated) |

> Unembedding relies on system fonts at runtime for the dropped glyphs.
> Only the `CJK` value was rebuilt and measured end-to-end here; `ALL` is a
> size estimate from the object sizes above (a full rebuild was not completed).

For the **vendored** route the module:
* locates GNU make (`gmake`/`make`) and **fails fast** if absent;
* resolves **HarfBuzz** (required because mupdf is built with
  `USE_SYSTEM_HARFBUZZ=yes`) and **fails fast** if absent;
* drives mupdf's own Makefile via `ExternalProject` to build
  `libmupdf.a`, `libmupdf-third.a`, `libmupdf-threads.a`.

#### Vendored build robustness

mupdf's Makefile builds each object with a recipe that lazily creates the
object's directory and writes a `-MMD` dependency file:
`mkdir -p $(dir $@) ; cc -MMD -o $@ -c $<`. When that tree is created for the
first time under parallelism, the `-MMD` write can race the directory creation
and fail intermittently with:

```
cc: fatal error: opening dependency file .../mupdf-out/thirdparty/brotli/.../x.d:
No such file or directory
```

`SioyekMupdf.cmake` avoids this by generating a small build script
(`<build-dir>/sioyek_mupdf_build.sh`) and running it via
`cmake -E env MAKEFLAGS= MFLAGS= GNUMAKEFLAGS= MAKELEVEL= /bin/sh <script>`:

1. the script **pre-creates the whole output directory tree** (derived from the
   mupdf source layout, so it stays correct as mupdf evolves) — making the
   per-object `mkdir -p` a no-op;
2. the make environment variables are **cleared**, so the requested `-j` is
   authoritative and no outer job-server leaks in;
3. `libs` and `libmupdf-threads` are built in a **single** make invocation
   (they share the third-party object list).

The generated script is inspectable and is covered by `test_mupdf_contract.sh`.

#### Parallelism for the vendored mupdf build

mupdf is built with its own GNU make, so it cannot observe the parallelism of
the outer build. In particular, **`cmake --build --preset <p> -j<N>` does not
propagate `<N>` to mupdf**: that `-j` is a cmake *client* option that only
governs the underlying generator (ninja/make) and is neither exported as a
CMake variable nor placed in the environment of the custom commands. Ninja
also schedules through its own job pool and does not advertise its parallelism
to child processes.

The `-j` used for mupdf is therefore resolved at **configure time**, in this
priority order:

| Source | How to use it |
|---|---|
| `SIOYEK_MUPDF_JOBS` (environment) | `SIOYEK_MUPDF_JOBS=8 cmake --preset linux-vendored` |
| `CMAKE_BUILD_PARALLEL_LEVEL` (variable or environment) | `-DCMAKE_BUILD_PARALLEL_LEVEL=8`, or `CMAKE_BUILD_PARALLEL_LEVEL=8 cmake ...` |
| auto-detected CPU count | the default (`CMake`'s `ProcessorCount`) |

So `CMAKE_BUILD_PARALLEL_LEVEL` in the environment is the closest thing to
"inheriting" the outer `-j`, since cmake honours it as the default parallelism
of `cmake --build` as well. The resolved value is printed at configure time and
baked into the generated build script. Integrations (CI, packagers) can set
`SIOYEK_MUPDF_JOBS` directly.

### 3.4 `SioyekSQLite.cmake`

Chooses the SQLite source. sioyek only uses six long-stable SQLite APIs, so a
**compile probe** (`try_compile`) is used instead of a strict version range:
if the probe passes, the system library is used; otherwise the vendored
amalgamation is compiled. Option: `SIOYEK_USE_SYSTEM_SQLITE` = `AUTO|ON|OFF`.

### 3.5 `SioyekInstall.cmake`

The **authoritative install manifest**, matching the runtime path lookup in
`pdf_viewer/main.cpp`.

| File | standard layout | portable layout |
|---|---|---|
| executable | `bin/` | `bin/` |
| shaders, tutorial | `share/sioyek/` | `bin/` |
| keys/prefs | `/etc/sioyek/` (absolute) | `bin/` |
| desktop/icon/man | system locations | (n/a) |

Option: `SIOYEK_INSTALL_LAYOUT` = `standard|portable`.

Respects `DESTDIR` and `CMAKE_INSTALL_PREFIX`; downstream packagers can run
`DESTDIR=<stage> cmake --install <builddir>` and get a complete tree.

#### Why default configs go to `etc/sioyek` (and what that implies)

The install location is chosen to **match the application's existing runtime
path logic** in `pdf_viewer/main.cpp` (the `LINUX_STANDARD_PATHS` branch), which
reads the default configuration from `/etc/sioyek` and read-only resources from
`/usr/share/sioyek`. The install contract therefore places:

* `keys.config`, `prefs.config` -> `CMAKE_INSTALL_FULL_SYSCONFDIR/sioyek`,
  i.e. the **absolute** `/etc/sioyek` when the prefix is `/usr`;
* shaders, tutorial -> `<datadir>/sioyek` (e.g. `/usr/share/sioyek`).

Implications to be aware of:

* The build system **does not** change the program's runtime path logic. If you
  install with a prefix other than the one the binary expects (e.g.
  `-DCMAKE_INSTALL_PREFIX=/usr/local` while the binary looks under `/usr`),
  resource lookup will not match. Use a matching prefix (the presets set
  `/usr`).
* The config destination uses the **absolute** sysconfdir
  (`CMAKE_INSTALL_FULL_SYSCONFDIR`), not the prefix-relative one. With the
  conventional `-DCMAKE_INSTALL_PREFIX=/usr`, using the relative form would
  install to `/usr/etc/sioyek` — which the binary (which reads the absolute
  `/etc/sioyek`) never looks at, silently disabling the default config. Absolute
  destinations remain fully staged under `DESTDIR`.
* User-specific configuration is separate: it lives under
  `$XDG_CONFIG_HOME/sioyek` (usually `~/.config/sioyek`) and is created by Qt at
  runtime, so it never needs to be installed.

### 3.6 `SioyekPackaging.cmake`

CPack configuration. `SIOYEK_PACKAGE_FORMATS` selects generators
(default `DEB;RPM;TGZ`). `SIOYEK_PACKAGE_STRIP` adds `CPACK_STRIP_FILES`.
AppImage is **not** a CPack generator; it is built by `make appimage` (see the
Makefile).

### 3.7 `SioyekTesting.cmake`

Registers the contract tests with CTest (`SIOYEK_ENABLE_TESTS`, default `ON`).
Run them with `ctest --test-dir <builddir>`.

### 3.8 `SioyekWarnings.cmake`

* compiler-specific flags are probed before use (fixes GCC "unrecognized
  option" noise);
* third-party sources (`sqlite3.c`, `shell.c`, `synctex/*.c`, `fzf`) and Qt
  generated units are downgraded to `-w`;
* two tri-state options control diagnostics for **sioyek's own code**:

| Option | Values | Default | Effect |
|---|---|---|---|
| `SIOYEK_STRICT_NON_THIRD_PARTY_WARN` | `AUTO`/`ON`/`OFF` | `AUTO` | `-Wall -Wextra` on the project's own translation units |
| `SIOYEK_WERROR_RETURN_TYPE` | `AUTO`/`ON`/`OFF` | `AUTO` | promote `-Wreturn-type` to an error (`-Werror=return-type`) |

`AUTO` enables the option for **Debug-like** build types (`CMAKE_BUILD_TYPE`
matching `Debug`), and leaves it off otherwise (so release/distro builds keep
full control of their own `CFLAGS`/`CXXFLAGS`). The `linux-debug`,
`macos-debug` and `windows-debug` presets set both to `ON`.

#### Why `-Werror=return-type`

A non-void function that falls off its end without returning is undefined
behaviour. GCC 15 enables `-Wreturn-type` by default, which is how it surfaced
in `config.cpp: get_type_string()` (an `if`-ladder without a trailing `return`).
Promoting it to an error catches this class of
defect at build time. It is deliberately narrow: enabling `-Werror` for *all*
of `-Wall -Wextra` would fail on hundreds of style warnings
(`-Wsign-compare`, `-Wunused-parameter`, ...), so only the UB-class warning is
promoted.

> Turning `SIOYEK_WERROR_RETURN_TYPE=OFF` (or building a release preset) keeps
> the same diagnostic as a warning without breaking the build.

---

## 4. Presets

Run `cmake --list-presets` to see all. Summary:

| Preset | Type | Strip | Notes |
|---|---|---|---|
| `linux-release` | Release | yes | standard distro build |
| `linux-debug` | Debug | no | symbols kept |
| `linux-relwithdebinfo` | RelWithDebInfo | no | `-O2 -g` |
| `linux-portable` | Release | yes | resources beside binary, self-contained Qt |
| `linux-appimage` | Release | yes | self-contained; LTO |
| `linux-vendored` | Release | yes | vendored mupdf/sqlite (reproducible) |
| `linux-ci` | Release | no | fast CI build |
| `macos-release` / `macos-debug` | | | |
| `windows-release` / `windows-debug` | | | MSVC |

---

## 5. Clean-up

There are two complementary clean mechanisms: the **Makefile** (synchronous,
run outside CMake) and the **CMake targets** (`SioyekClean.cmake`, safe to run
while CMake/ninja is active).

### 5.1 Makefile (recommended; synchronous)

```sh
make clean           # remove objects of the current build dir (keep config)
make distclean       # full clean: the ENTIRE build/ tree + stage/ + packages + leftovers + deps
make clean-build     # remove the whole build/ tree (all presets) + dependency residue
make clean-deps      # dependency/submodule build residue only (mupdf, zlib)
make clean-stage     # remove stage/ only
make clean-packages  # remove CPack/AppImage artifacts only
make clean-in-source # remove accidental in-source CMake files only
```

`make distclean` is the full, synchronous clean (the traditional `distclean`
semantics): it removes the **entire `build/` tree** (all presets), `stage/`,
`sioyek-release/`, `.qt/`, `.deps/`, packaging artifacts, legacy qmake outputs
(`*.o`, `moc_*`, `qrc_*`, a root `sioyek` binary, `sioyek_log.txt`, ...),
in-source CMake leftovers (`CMakeFiles/`, `Testing/`, `CMakeCache.txt`, ...)
and **dependency/submodule build residue** (`mupdf/build`, `mupdf/generated`,
`zlib/build`). It **never** removes the hand-written top-level Makefile or any
source file.

> **Dependency residue.** The vendored mupdf is built with its *own* GNU make.
> CMake directs the final archives into `<build>/mupdf-out`, but mupdf's make —
> and the legacy qmake scripts — also create in-tree intermediates under
> `mupdf/build/` and `mupdf/generated/`. Those are invisible to git (the mupdf
> submodule ignores them) but must be cleaned explicitly, which is what
> `clean-deps` (and therefore `distclean` / `clean-build`) does. This mirrors
> neovim's `distclean`, which removes its `.deps` build directory.

> Earlier versions of `make distclean` removed only the current `PRESET`'s build
> directory, which left other preset directories behind — that is why it is now
> a full clean. To remove only `build/` while keeping other artifacts, use
> `make clean-build`.

### 5.2 CMake targets (SioyekClean.cmake)

Available in any configured build dir (`cmake --build <dir> --target <t>`):

| Target | Removes |
|---|---|
| `clean-stage` | staged install output (`stage/`) |
| `clean-packages` | CPack/AppImage artifacts |
| `clean-in-source` | accidental in-source CMake leftovers |
| `clean-deps` | dependency/submodule build residue (`mupdf/build`, `mupdf/generated`, `zlib/build`) |
| `clean-all` / `distclean` | the above **plus the current build directory** |
| `clean-build` | the **entire** top-level `build/` tree **plus dependency residue** |

> **Safety contract.** `SioyekClean.cmake` keeps an explicit
> `_sioyek_protected_files` list (top-level `Makefile`, `CMakeLists.txt`,
> `CMakePresets.json`) and *asserts at configure time* that none of them appears
> in a deletion list — configuration fails fast otherwise. This is a regression
> guard: an earlier revision listed the tracked top-level `Makefile` as an
> "accidental in-source CMake file" and deleted it. `test_clean_contract.sh`
> reproduces that layout and fails if the Makefile does not survive.

The CMake `clean-all`/`distclean` remove the build directory by **scheduling the
removal in a detached background process** ~1 s after the build tool returns:
a target cannot synchronously delete its own working directory (ninja/make fail
to write their log; `rm -rf .` errors). The Makefile targets above do the same
removal synchronously, which is why they are preferred for interactive use.

> The legacy `scripts/clean.sh` has been removed; its behavior is fully provided
> by `make distclean`.

## 6. CI

`.github/workflows/cmake_build.yml` runs two jobs:

* **contract-tests** – runs `cmake/tests/run_all.sh` and CTest; fast, no
  submodules.
* **cmake-build** – real build with the `linux-vendored` preset, on a
  **gcc + clang matrix**, including a staged install and an `ldd` smoke test.

Environment notes recorded in the workflow header:
* `actions/checkout@v5` (Node 20 deprecation);
* Qt 6.7.2 installed explicitly (Ubuntu 24.04 ships 6.4.2 < required 6.5);
* system mupdf on Ubuntu is 1.23.10 (< verified minimum), so the system route
  is **not** built in CI.

`.github/workflows/build_and_release.yml` (and its `preview_release.yml` twin)
carry the **release** pipelines. In addition to the legacy qmake jobs
(`build-linux` / `build-mac` / `build-mac-arm` / `build-windows`, unchanged
artifact names), a **`build-linux-cmake`** job validates the modern CMake
system end to end: it configures/builds the `linux-portable` preset, runs the
CTest contract suite, stages an install, and ships a portable bundle
(`sioyek-release-linux-cmake.zip`). Keeping both means the CMake route is
continuously exercised without altering the existing release artifact
contract.

---

## 7. Contract tests

`cmake/tests/` contains self-contained bash tests; each builds a *minimal*
CMake project and asserts one aspect of the automation facility. They never
touch the real source tree except through the modules under test, and they do
not require submodules or a full build.

| Suite | What it verifies |
|---|---|
| `test_mupdf_contract.sh` | mupdf version → system/vendored decision matrix; vendored build-script generation (dir pre-create + env clearing) |
| `test_sqlite_contract.sh` | SQLite probe → system/vendored decision matrix |
| `test_install_contract.sh` | install layout paths (standard/portable) |
| `test_buildtypes_contract.sh` | `-O2` (not `-O3`), LTO default, strip toggles, size opts, ccache OFF, and ccache writability handling (AUTO fallback / ON fail-fast) |
| `test_clean_contract.sh` | clean-* targets exist; `clean-in-source` removes leftovers but **not** authored files (incl. the hand-written `Makefile` / `CMakePresets.json`); `clean-deps` removes submodule residue; `clean-stage` |
| `test_packaging_contract.sh` | CPack config generated; name/version/contact; `CPACK_STRIP_FILES` driven by `SIOYEK_PACKAGE_STRIP` |
| `test_warnings_contract.sh` | tri-state strict warnings (`AUTO` on Debug) and `-Werror=return-type`; third-party downgrade to `-w`; clang-only flag not applied under GCC |
| `test_presets.sh` | preset presence/validity; every preset referenced by a CI workflow resolves; `clean-deps` is defined |

`run_all.sh` runs all suites (currently **8 suites / 88 assertions**).
`SIOYEK_TEST_VERBOSE=1` prints diagnostics on failures.

Coverage map (facility module → suite):

| Module | Covered by |
|---|---|
| `SioyekMupdf.cmake` | `test_mupdf_contract.sh` |
| `SioyekSQLite.cmake` | `test_sqlite_contract.sh` |
| `SioyekInstall.cmake` | `test_install_contract.sh` |
| `SioyekBuildTypes.cmake` | `test_buildtypes_contract.sh` |
| `SioyekClean.cmake` | `test_clean_contract.sh` |
| `SioyekPackaging.cmake` | `test_packaging_contract.sh` |
| `SioyekWarnings.cmake` | `test_warnings_contract.sh` |
| `CMakePresets.json` | `test_presets.sh` |
| `SioyekDependencies.cmake` | exercised via the mupdf/sqlite suites |
| `SioyekTesting.cmake` | exercised by running CTest itself |

---

## 7b. Working conventions for build/CI changes

These are the rules that keep the automation module-safe and distro-friendly.
They apply to human and automated contributors alike.

### Scope

* **Do not change functional application code** when the task is about the
  build/CI machinery. Restrict edits to `Makefile`, `cmake/**`,
  `CMakeLists.txt`, `CMakePresets.json`, `.github/workflows/**`, `.gitignore`
  and build-system documentation unless explicitly asked otherwise.

### Options and naming

* All CMake options are `SIOYEK_*`-prefixed and documented here.
* Prefer the `ninja` generator (the presets use it) and Ninja's built-in
  parallelism; do not pass `-j` when Ninja is in use.
* Release binaries keep symbols unless `SIOYEK_STRIP_ON_INSTALL` /
  `SIOYEK_PACKAGE_STRIP` is set; CI and distro packaging normally do **not**
  strip (downstream packagers strip themselves).

### Invariants (each is guarded by a contract test)

| Invariant | Guarded by |
|---|---|
| Authored/tracked files are never deleted by a clean target (`_sioyek_protected_files`, configure-time assertion) | `test_clean_contract.sh` |
| `clean-deps` removes only submodule build residue, never sources | `test_clean_contract.sh` |
| Vendored mupdf build runs the generated script (dir pre-create + cleared make env) | `test_mupdf_contract.sh` |
| Install uses the **absolute** sysconfdir (`CMAKE_INSTALL_FULL_SYSCONFDIR`), matching the runtime `/etc/sioyek` | `test_install_contract.sh` |
| ccache is used only when its cache is writable; `AUTO` falls back, `ON` fails fast | `test_buildtypes_contract.sh` |
| Every preset referenced by CI exists and resolves | `test_presets.sh` |

When adding or changing a clean/build/test facility, **add or extend the
matching `cmake/tests/test_*_contract.sh`** so the behavior is regression-tested.

### Distro-friendliness principles

* **Build offline.** No network access at build time (the vendored route uses
  the submodule + its own make, no downloads).
* **Prefer system dependencies for packaging** (`SIOYEK_USE_SYSTEM_MUPDF=ON`,
  `SIOYEK_USE_SYSTEM_SQLITE=ON`) so packages link `libmupdf.so`/`libsqlite3.so`
  instead of bundling.
* **Absolute sysconfdir.** The install contract must place default config at
  `CMAKE_INSTALL_FULL_SYSCONFDIR/sioyek` (i.e. `/etc/sioyek` with
  `-DCMAKE_INSTALL_PREFIX=/usr`), matching the runtime lookup in
  `pdf_viewer/main.cpp`. The prefix-relative `CMAKE_INSTALL_SYSCONFDIR` would
  produce `/usr/etc/sioyek`, which the binary never reads, silently disabling
  the shipped defaults. An absolute destination is still staged correctly under
  `DESTDIR`.
* Keep the install contract (`cmake/SioyekInstall.cmake`) in sync with the
  runtime path logic; do not hardcode paths in the modules.

### Verifying changes

```sh
# Fast, no submodules needed: the full contract suite.
bash cmake/tests/run_all.sh

# Real build of the reproducible vendored route, then the CTest suite.
cmake --preset linux-vendored
cmake --build --preset linux-vendored -j"$(nproc)"
ctest --test-dir build/linux-vendored --output-on-failure

# Wrapper entry points.
make help
make test PRESET=linux-vendored
```

---

## 8. Verification status (IMPORTANT: what is and is not tested)

### Verified on this host (Fedora-like, GCC 15, Qt 6.11, system mupdf 1.28.2)
* [x] Configure with both source routes (system + vendored).
* [x] **Real compile + link** using the **system** mupdf route.
* [x] `ctest` runs all 8 contract suites (76 assertions) — pass.
* [x] Staged install layout (standard).
* [x] Strip-on-install and CPack strip produce `stripped` binaries.
* [x] `-O2` + size optimizations reduce the stripped binary (~0.5 MB here).
* [x] `ldd` smoke test logic (no unresolved dynamic deps).
* [x] **Vendored mupdf build end-to-end** on this host (after populating
      submodules): links successfully; binary ~45 MB unstripped (fonts embedded).

### NOT verified on this host (rely on CI or require specific environments)
* [ ] **Vendored mupdf build on CI** — performed by CI with
      `submodules: recursive`; verified locally on this host once the submodules
      were populated (see below).
* [ ] **AppImage generation** (`make appimage`) — needs
      `linuxdeploy` + Qt plugin (network download) and was **not executed**.
* [ ] **CPack DEB/RPM** were generated earlier only in a limited form; RPM
      needs `rpmbuild` (not present on this host).
* [ ] **macOS and Windows** presets/paths — not built on this host.
* [ ] **clang** build — only gcc was used locally; clang runs in CI matrix.
* [ ] **LTO** — moved to default for Release; measured on this host for the
      **system** route, but not on the vendored route.
* [x] **Vendored SQLite trimming** — reduced to `SQLITE_DQS=0` after
      `SQLITE_OMIT_*` was found to break the LTO link; the vendored build
      succeeds with it.
* [x] **Font unembedding `CJK`** (`SIOYEK_MUPDF_UNEMBED_FONTS=CJK`) — rebuilt and
      measured end-to-end: stripped vendored binary ~22.5 MB. The flags reach
      mupdf's make via `XCFLAGS`.
* [ ] **Font unembedding `ALL`** — object sizes measured; the combined
      `-DTOFU -DTOFU_CJK` flags are wired, but a full rebuild was not completed
      (estimated ~9–10 MB).
* [ ] **Clean targets** `clean-packages` / `clean-stage` / `clean-all` — only
      `clean-in-source` was exercised locally.
* [ ] **ccache** — AUTO detection only; not benchmarked.
* [ ] **Runtime behavior** — no GUI/functional test is run; CI only performs a
      link/load smoke test.
* [ ] **Downstream packagers** — not re-run with the new contract.

### Known limitations
* The utf8cpp warnings (deprecated `std::iterator`) cannot be isolated without
  changing include paths; they are not third-party-isolated (see
  `SioyekWarnings.cmake`).
* Strip uses the host `strip`; cross-compilation would need a target `strip`.
* `-march=native` is intentionally **not** used (distribution safety).
* PGO is not implemented.
