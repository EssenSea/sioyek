# =============================================================================
# cmake/options.mk -- friendly --enable/--disable/--with option translation
#
# Included by the top-level Makefile. Translates autoconf-style flags passed in
# EXTRA_CMAKE_ARGS into -DSIOYEK_* CMake cache variables, so users do not have to
# remember the CMake spelling. The actual parsing lives in
# cmake/parse-build-options.sh (single source of truth, unit-testable).
#
# Usage:
#   make build EXTRA_CMAKE_ARGS="--enable-lto"
#   make build EXTRA_CMAKE_ARGS="--disable-tests --without-system-mupdf"
#   make build EXTRA_CMAKE_ARGS="--with-mupdf-unembed-fonts=ALL"
#   make build EXTRA_CMAKE_ARGS="--with-install-layout=portable"
#   make options          # list all friendly flags
#
# Features may omit the leading "--" (enable-lto). Raw -D flags pass through.
# Unknown options are an error pointing at `make options`.
# =============================================================================

SIOYEK_PARSE_OPTIONS := $(CURDIR)/cmake/parse-build-options.sh

# Translate EXTRA_CMAKE_ARGS -> -D flags. `$(shell ...)` runs at parse time; an
# unknown option makes the script exit 2 and print a diagnostic to stderr.
SIOYEK_OPTION_FLAGS := $(shell $(SIOYEK_PARSE_OPTIONS) $(EXTRA_CMAKE_ARGS) 2>&1)

# If the parser failed, SIOYEK_OPTION_FLAGS holds the error text; surface it.
ifneq (,$(findstring error:,$(SIOYEK_OPTION_FLAGS)))
$(error $(subst $(newline), ,$(SIOYEK_OPTION_FLAGS)))
endif

# ---- options: friendly help --------------------------------------------------
options:
	@echo 'Friendly build options for ./configure (and make options):'
	@echo ''
	@echo '  --enable-X / --disable-X / --with-X / --without-X   (all equivalent,'
	@echo '  per autoconf: --with-X == --enable-X, --without-X == --disable-X).'
	@echo '  --enable-X=VALUE also accepted; yes/on/1 -> ON, no/off/0 -> OFF.'
	@echo ''
	@echo '  Booleans:'
	@printf '    %-42s %s\n' '--enable-lto / --disable-lto' 'SIOYEK_ENABLE_LTO'
	@printf '    %-42s %s\n' '--enable-tests / --disable-tests' 'SIOYEK_ENABLE_TESTS'
	@printf '    %-42s %s\n' '--enable-ccache / --disable-ccache' 'SIOYEK_ENABLE_CCACHE'
	@printf '    %-42s %s\n' '--enable-unity-build / --disable-unity-build' 'SIOYEK_UNITY_BUILD'
	@printf '    %-42s %s\n' '--enable-size-optimizations / --disable-size-optimizations' 'SIOYEK_SIZE_OPTIMIZATIONS'
	@printf '    %-42s %s\n' '--enable-hidden-visibility / --disable-hidden-visibility' 'SIOYEK_HIDDEN_VISIBILITY'
	@printf '    %-42s %s\n' '--enable-strip-on-install / --disable-strip-on-install' 'SIOYEK_STRIP_ON_INSTALL'
	@printf '    %-42s %s\n' '--enable-package-strip / --disable-package-strip' 'SIOYEK_PACKAGE_STRIP'
	@printf '    %-42s %s\n' '--enable-install-qt-deploy / --disable-install-qt-deploy' 'SIOYEK_INSTALL_QT_DEPLOY'
	@printf '    %-42s %s\n' '--enable-sqlite-trim / --disable-sqlite-trim' 'SIOYEK_SQLITE_TRIM'
	@printf '    %-42s %s\n' '--enable-strict-warnings / --disable-strict-warnings' 'SIOYEK_STRICT_NON_THIRD_PARTY_WARN'
	@printf '    %-42s %s\n' '--enable-werror-return-type / --disable-werror-return-type' 'SIOYEK_WERROR_RETURN_TYPE'
	@printf '    %-42s %s\n' '--enable-allow-unverified-system-mupdf / --disable-allow-unverified-system-mupdf' 'SIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF'
	@echo ''
	@echo '  Tri-state (AUTO|ON|OFF):'
	@printf '    %-42s %s\n' '--with-system-mupdf / --without-system-mupdf' 'SIOYEK_USE_SYSTEM_MUPDF'
	@printf '    %-42s %s\n' '--with-system-sqlite / --without-system-sqlite' 'SIOYEK_USE_SYSTEM_SQLITE'
	@echo ''
	@echo '  Value options:'
	@printf '    %-42s %s\n' '--with-install-layout=VALUE' 'SIOYEK_INSTALL_LAYOUT'
	@printf '    %-42s %s\n' '--with-mupdf-unembed-fonts=VALUE' 'SIOYEK_MUPDF_UNEMBED_FONTS'
	@printf '    %-42s %s\n' '--with-package-formats=VALUE' 'SIOYEK_PACKAGE_FORMATS'
	@echo ''
	@echo 'Raw -D flags are passed through. Options are recorded by ./configure:'
	@echo '  ./configure --enable-lto --disable-tests --with-system-mupdf'
	@echo '  make            # or a per-preset target, e.g. make linux-portable'
