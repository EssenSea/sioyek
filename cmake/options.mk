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
	@echo 'Friendly build options (pass via EXTRA_CMAKE_ARGS="..."):'
	@echo ''
	@echo '  --enable-X / --disable-X                 (booleans -> -DSIOYEK_*=ON/OFF)'
	@printf '    %-40s %s\n' '--enable-lto'                    'SIOYEK_ENABLE_LTO'
	@printf '    %-40s %s\n' '--disable-tests'                  'SIOYEK_ENABLE_TESTS'
	@printf '    %-40s %s\n' '--enable-ccache'                  'SIOYEK_ENABLE_CCACHE'
	@printf '    %-40s %s\n' '--enable-unity-build'             'SIOYEK_UNITY_BUILD'
	@printf '    %-40s %s\n' '--disable-size-optimizations'     'SIOYEK_SIZE_OPTIMIZATIONS'
	@printf '    %-40s %s\n' '--enable-hidden-visibility'       'SIOYEK_HIDDEN_VISIBILITY'
	@printf '    %-40s %s\n' '--enable-strip-on-install'        'SIOYEK_STRIP_ON_INSTALL'
	@printf '    %-40s %s\n' '--enable-package-strip'           'SIOYEK_PACKAGE_STRIP'
	@printf '    %-40s %s\n' '--enable-install-qt-deploy'       'SIOYEK_INSTALL_QT_DEPLOY'
	@printf '    %-40s %s\n' '--disable-sqlite-trim'            'SIOYEK_SQLITE_TRIM'
	@printf '    %-40s %s\n' '--enable-strict-warnings'         'SIOYEK_STRICT_NON_THIRD_PARTY_WARN'
	@printf '    %-40s %s\n' '--enable-werror-return-type'      'SIOYEK_WERROR_RETURN_TYPE'
	@printf '    %-40s %s\n' '--enable-allow-unverified-system-mupdf' 'SIOYEK_ALLOW_UNVERIFIED_SYSTEM_MUPDF'
	@echo ''
	@echo '  --with-X / --without-X / --with-X=VALUE  (tri-state -> ON/OFF/VALUE)'
	@printf '    %-40s %s\n' '--with-system-mupdf'              'SIOYEK_USE_SYSTEM_MUPDF'
	@printf '    %-40s %s\n' '--with-system-sqlite'             'SIOYEK_USE_SYSTEM_SQLITE'
	@echo ''
	@echo '  --with-X=VALUE                           (value -> -DSIOYEK_*=VALUE)'
	@printf '    %-40s %s\n' '--with-install-layout=portable'   'SIOYEK_INSTALL_LAYOUT (standard|portable)'
	@printf '    %-40s %s\n' '--with-mupdf-unembed-fonts=CJK'   'SIOYEK_MUPDF_UNEMBED_FONTS (OFF|CJK|CJK_LANG|ALL)'
	@printf '    %-40s %s\n' '--with-package-formats=TGZ'       'SIOYEK_PACKAGE_FORMATS'
	@echo ''
	@echo 'Raw -D flags are still accepted and passed through.'
	@echo ''
	@echo 'Examples:'
	@echo '  make build EXTRA_CMAKE_ARGS="--enable-lto --disable-tests"'
	@echo '  make build EXTRA_CMAKE_ARGS="--with-system-mupdf --with-install-layout=portable"'
	@echo '  make install DESTDIR=/tmp/stage EXTRA_CMAKE_ARGS="--enable-strip-on-install"'
