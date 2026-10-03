# =============================================================================
# cmake/options.mk -- `make options` help for the friendly build options
#
# The option table and its translation live in cmake/parse-build-options.sh
# (single source of truth), which ./configure also uses. This fragment only
# renders `make options` from that table; it defines no translation of its own.
#
# The Makefile remains a thin wrapper over CMake: everything these options do is
# expressible directly in CMake, e.g.
#   cmake --preset <p> -DSIOYEK_ENABLE_LTO=ON -DCMAKE_INSTALL_PREFIX=/usr
# =============================================================================

SIOYEK_PARSE_OPTIONS := $(CURDIR)/cmake/parse-build-options.sh

# ---- options: friendly help (generated from the shared table) ----------------
options:
	@echo 'Friendly options for ./configure (recorded in config.mk), shown with'
	@echo 'their equivalent CMake variables:'
	@echo ''
	@echo 'Installation directories (--<name>=DIR):'
	@$(SIOYEK_PARSE_OPTIONS) --list-dirs | sed 's/^/  --/;s/:/=DIR  ->  /'
	@echo ''
	@echo 'Features:'
	@$(SIOYEK_PARSE_OPTIONS) --list | awk -F: '{printf "  --enable-%s / --with-%s -> %s\n", $$1, $$1, $$2}'
	@echo ''
	@echo 'Every feature accepts --enable-X / --disable-X / --with-X / --without-X'
	@echo '(autoconf: --with-X == --enable-X); --enable-X=VALUE sets a value.'
	@echo ''
	@echo 'Equivalent with pure CMake:'
	@echo '  cmake --preset <preset> -DSIOYEK_ENABLE_LTO=ON -DCMAKE_INSTALL_PREFIX=/usr'
	@echo ''
	@echo 'Usage:'
	@echo '  ./configure --enable-lto --disable-tests --with-system-mupdf'
	@echo '  make            # or a per-preset target, e.g. make linux-portable'
