# =============================================================================
# sioyek top-level Makefile
#
# A thin, Makefile-conventional wrapper around the CMake presets. CMake remains
# the source of truth; this offers familiar names for common actions.
#
# Examples:
#   make                       # build (default: linux-release preset)
#   make PRESET=linux-vendored
#   make test
#   make install DESTDIR=/tmp/stage
#   make distclean             # remove build/ and all generated artifacts
#   make help                  # list targets
#
# See cmake/README.md for the full build system documentation.
# =============================================================================

# ---- Platform detection (neovim-style) -------------------------------------
ifeq ($(OS),Windows_NT)
  UNIX_LIKE := FALSE
else
  UNIX_LIKE := TRUE
endif

ifeq ($(UNIX_LIKE),FALSE)
  SHELL := powershell.exe
  .SHELLFLAGS := -NoProfile -NoLogo
  RM := remove-item -force
  CMAKE := cmake
  NPROC := $(NUMBER_OF_PROCESSORS)
else
  RM := rm -rf
  CMAKE := $(shell command -v cmake3 2>/dev/null || command -v cmake)
  NPROC := $(shell (command -v nproc >/dev/null 2>&1 && nproc) \
                 || (command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu) \
                 || echo 1)
endif

# ---- Configuration ---------------------------------------------------------
# Default preset; override with e.g. `make PRESET=linux-vendored`.
PRESET ?= linux-release

# Build dir (matches the preset binaryDir; see CMakePresets.json).
BUILD_DIR ?= build/$(PRESET)

# Extra CMake configure flags, e.g.
#   make CMAKE_EXTRA_FLAGS='-DSIOYEK_MUPDF_UNEMBED_FONTS=CJK'
CMAKE_EXTRA_FLAGS ?=

# Install staging dir; DESTDIR is honored by CMake's install step.
DESTDIR ?=
PREFIX ?=
JOBS ?= $(NPROC)

# Untracked local overrides (like neovim's local.mk).
-include local.mk

.PHONY: all build configure phony-configure test install package appimage \
        format format-check lint deps checkprefix \
        clean distclean clean-build clean-deps clean-stage clean-packages clean-in-source \
        list-presets help

# ---- Build ------------------------------------------------------------------
all: build

build: configure
	$(CMAKE) --build --preset $(PRESET) -j$(JOBS)

configure:
	$(CMAKE) --preset $(PRESET) $(CMAKE_EXTRA_FLAGS)

# ---- Test -------------------------------------------------------------------
test: configure
	$(CMAKE) --build --preset $(PRESET) -j$(JOBS)
	ctest --test-dir $(BUILD_DIR) --output-on-failure

# ---- Install / package ------------------------------------------------------
install: configure
	$(CMAKE) --build --preset $(PRESET) -j$(JOBS)
	DESTDIR='$(DESTDIR)' $(CMAKE) --install $(BUILD_DIR) \
	    $(if $(PREFIX),--prefix $(PREFIX),)

package: configure
	$(CMAKE) --build --preset $(PRESET) -j$(JOBS)
	cd $(BUILD_DIR) && cpack

# ---- AppImage ---------------------------------------------------------------
# Build a self-contained AppImage. Reuses the install contract so the packaged
# contents match `cmake --install`. linuxdeploy (+ its Qt plugin) is downloaded
# on demand into build/tools.
APPIMAGE_PRESET  ?= linux-appimage
APPIMAGE_BUILD   ?= build/$(APPIMAGE_PRESET)
APPIMAGE_DIR     ?= build/appimage
APPDIR           ?= $(APPIMAGE_DIR)/AppDir
TOOLS_DIR        ?= build/tools
LINUXDEPLOY_URL  ?= https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20240109-1/linuxdeploy-x86_64.AppImage
LINUXDEPLOY_QT_URL ?= https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20240109-1/linuxdeploy-plugin-qt-x86_64.AppImage

appimage:
	@echo "==> Configure/build ($(APPIMAGE_PRESET))"
	$(CMAKE) --preset $(APPIMAGE_PRESET) $(CMAKE_EXTRA_FLAGS)
	$(CMAKE) --build --preset $(APPIMAGE_PRESET) -j$(JOBS)
	@echo "==> Stage install into AppDir"
	rm -rf "$(APPDIR)"
	DESTDIR="$(CURDIR)/$(APPDIR)" $(CMAKE) --install "$(APPIMAGE_BUILD)"
	@if [ -d "$(APPDIR)/usr/local" ] && [ ! -e "$(APPDIR)/usr/bin" ]; then \
	mv "$(APPDIR)/usr/local"/* "$(APPDIR)/usr/" 2>/dev/null || true; \
	rmdir "$(APPDIR)/usr/local" 2>/dev/null || true; \
	fi
	@echo "==> Fetch linuxdeploy if needed"
	mkdir -p "$(TOOLS_DIR)"
	@if [ ! -x "$(TOOLS_DIR)/linuxdeploy-x86_64.AppImage" ]; then \
	wget -q -O "$(TOOLS_DIR)/linuxdeploy-x86_64.AppImage" $(LINUXDEPLOY_URL); \
	chmod +x "$(TOOLS_DIR)/linuxdeploy-x86_64.AppImage"; \
	fi
	@if [ ! -x "$(TOOLS_DIR)/linuxdeploy-plugin-qt-x86_64.AppImage" ]; then \
	wget -q -O "$(TOOLS_DIR)/linuxdeploy-plugin-qt-x86_64.AppImage" $(LINUXDEPLOY_QT_URL); \
	chmod +x "$(TOOLS_DIR)/linuxdeploy-plugin-qt-x86_64.AppImage"; \
	fi
	@echo "==> Build AppImage"
	mkdir -p "$(APPIMAGE_DIR)"
	cd "$(TOOLS_DIR)" && \
	QML_SOURCES_PATHS="$(CURDIR)/pdf_viewer/touchui" \
	./linuxdeploy-x86_64.AppImage \
	--appdir "$(CURDIR)/$(APPDIR)" \
	--desktop-file "$(CURDIR)/$(APPDIR)/usr/share/applications/sioyek.desktop" \
	--icon-file "$(CURDIR)/$(APPDIR)/usr/share/pixmaps/sioyek-icon-linux.png" \
	--plugin qt \
	--output appimage
	mv -f "$(TOOLS_DIR)"/*.AppImage "$(APPIMAGE_DIR)/" 2>/dev/null || true
	@echo "==> Done. AppImage in $(APPIMAGE_DIR)"

# ---- Code quality -----------------------------------------------------------
# Format source with clang-format (uses .clang-format at the repo root).
FORMAT_PATHS ?= pdf_viewer
format:
	@if command -v clang-format >/dev/null 2>&1; then \
	    find $(FORMAT_PATHS) \( -name '*.cpp' -o -name '*.h' -o -name '*.c' \) | \
	        xargs clang-format -i; \
	    echo "clang-format applied to $(FORMAT_PATHS)"; \
	else echo "clang-format not found"; exit 1; fi

# Check formatting without changing files (non-zero if not formatted).
format-check:
	@if command -v clang-format >/dev/null 2>&1; then \
	    find $(FORMAT_PATHS) \( -name '*.cpp' -o -name '*.h' -o -name '*.c' \) | \
	        xargs clang-format --dry-run --Werror; \
	else echo "clang-format not found"; exit 1; fi

# Static analysis with clang-tidy (needs a configured build dir for flags).
lint: $(BUILD_DIR)/.ran-cmake
	@if command -v clang-tidy >/dev/null 2>&1; then \
	    find pdf_viewer -name '*.cpp' | \
	        xargs clang-tidy -p $(BUILD_DIR); \
	else echo "clang-tidy not found"; exit 1; fi

# ---- Dependency / sanity helpers -------------------------------------------
# Fetch the vendored mupdf submodules (and their nested thirdparty modules).
deps:
	git submodule update --init --recursive

# Warn if CMAKE_INSTALL_PREFIX differs from the cached value (neovim-style).
checkprefix:
	@if [ -f "$(BUILD_DIR)/CMakeCache.txt" ] && [ -n "$(PREFIX)" ]; then \
	    cached=$$(grep '^CMAKE_INSTALL_PREFIX:' "$(BUILD_DIR)/CMakeCache.txt" | cut -d= -f2); \
	    if [ "$$cached" != "$(PREFIX)" ]; then \
	        echo "warning: PREFIX '$(PREFIX)' != cached '$$cached'; re-run 'make configure'"; \
	    fi \
	fi

# ---- Clean ------------------------------------------------------------------
# clean: remove compiled objects of the current build dir (keeps configuration).
clean:
	@if [ -d "$(BUILD_DIR)" ]; then $(CMAKE) --build $(BUILD_DIR) --target clean; fi

# distclean: remove ALL build output: the entire build/ tree (every preset),
# stage/, packaging artifacts and in-source CMake leftovers. This is the
# Makefile-equivalent of the traditional `make distclean`. It never removes
# the hand-written Makefile or any source file.
distclean: clean-deps
	$(RM) build stage sioyek-release .qt .deps
	$(RM) *.AppImage *.deb *.rpm *.tar.gz 2>/dev/null || true
	$(RM) *.o moc_*.cpp moc_*.h qrc_*.cpp ui_*.h 2>/dev/null || true
	$(RM) sioyek sioyek_log.txt sioyek_autogen sioyek.app lib_debug lib_release 2>/dev/null || true
	$(RM) CMakeFiles Testing 2>/dev/null || true
	$(RM) CMakeCache.txt cmake_install.cmake install_manifest.txt CTestTestfile.cmake CPackConfig.cmake CPackSourceConfig.cmake 2>/dev/null || true

# clean-build: remove the ENTIRE build/ tree (all presets) + dependency residue.
clean-build: clean-deps
	$(RM) build

# clean-deps: dependency/submodule in-tree build residue only (mupdf, zlib).
# The CMake clean targets remove these too; this mirrors that behavior for the
# Makefile entry point. Submodule *sources* are never touched.
clean-deps:
	$(RM) mupdf/build mupdf/generated zlib/build

clean-stage:
	$(RM) stage

clean-packages:
	$(RM) build/appimage
	$(RM) *.AppImage *.deb *.rpm *.tar.gz 2>/dev/null || true
	$(RM) *.o moc_*.cpp moc_*.h qrc_*.cpp ui_*.h 2>/dev/null || true
	$(RM) sioyek sioyek_log.txt sioyek_autogen sioyek.app lib_debug lib_release 2>/dev/null || true

clean-in-source:
	$(RM) CMakeFiles Testing
	$(RM) CMakeCache.txt cmake_install.cmake install_manifest.txt CTestTestfile.cmake 2>/dev/null || true
	$(RM) CPackConfig.cmake CPackSourceConfig.cmake 2>/dev/null || true

# ---- Help -------------------------------------------------------------------
list-presets:
	$(CMAKE) --list-presets

help:
	@echo 'sioyek Make targets:'
	@echo '  make [PRESET=...]         build (default PRESET=linux-release)'
	@echo '  make test                 build and run CTest'
	@echo '  make install DESTDIR=...  build and staged install'
	@echo '  make package              build and run CPack'
	@echo '  make appimage             build an AppImage'
	@echo '  make clean                remove objects of the current build dir'
	@echo '  make distclean            remove ALL build output (build/ + stage/ + packages + deps)'
	@echo '  make clean-build          remove the whole build/ tree (all presets)'
	@echo '  make clean-deps           remove dependency/submodule build residue (mupdf, zlib)'
	@echo '  make format               clang-format the source tree'
	@echo '  make format-check         verify formatting (no changes)'
	@echo '  make lint                 clang-tidy analysis'
	@echo '  make deps                 fetch mupdf submodules'
	@echo '  make list-presets         list available CMake presets'
	@echo ''
	@echo 'Variables: PRESET BUILD_DIR CMAKE_EXTRA_FLAGS DESTDIR PREFIX JOBS'
