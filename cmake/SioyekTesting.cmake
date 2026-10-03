#[[============================================================================
  SioyekTesting.cmake
  ---------------------------------------------------------------------------
  CTest registration: hooks the contract regression tests into CTest so that
  `ctest` runs them in one go.

  Can be disabled with -DSIOYEK_ENABLE_TESTS=OFF (default ON).
============================================================================]]#

include_guard(GLOBAL)

option(SIOYEK_ENABLE_TESTS "Enable contract regression tests via CTest." ON)

if(NOT SIOYEK_ENABLE_TESTS)
    message(STATUS "sioyek: CTest contract tests disabled (SIOYEK_ENABLE_TESTS=OFF)")
    return()
endif()

enable_testing()

set(_sioyek_test_dir "${CMAKE_CURRENT_SOURCE_DIR}/cmake/tests")

# Individual contract test suites.
#
# The suite list is DISCOVERED from the filesystem (cmake/tests/test_*.sh)
# rather than hard-coded here.
#
# WHY (this was a real, silent failure): the list used to be written out by hand
# in this file *and* again in cmake/tests/run_all.sh. The two copies drifted --
# run_all.sh ran nine suites while this file registered eight, so
# test_make_options_contract.sh (the largest suite, 53 assertions) NEVER ran
# under `ctest`, which is exactly what CI invokes. A hand-maintained list is a
# second source of truth for something the filesystem already knows, so it is
# gone; adding cmake/tests/test_<name>.sh now registers itself with CTest and
# with run_all.sh alike.
#
# A missing/renamed suite is no longer skipped silently either: the previously
# unconditional `if(EXISTS ...)` guard swallowed typos, so a suite could vanish
# without any signal. Discovery plus an explicit empty-list check makes an
# accidental deletion a visible configuration error.
file(GLOB _sioyek_contract_scripts CONFIGURE_DEPENDS
    "${_sioyek_test_dir}/test_*.sh")

if(NOT _sioyek_contract_scripts)
    message(WARNING
        "sioyek: no contract test scripts were found in ${_sioyek_test_dir} "
        "(expected test_*.sh). The contract regression suite is not being run.")
endif()

foreach(_script IN LISTS _sioyek_contract_scripts)
    # test_<name>.sh  ->  contract.<name>
    get_filename_component(_base "${_script}" NAME_WE)
    string(REGEX REPLACE "^test_" "" _name "${_base}")
    add_test(
        NAME "contract.${_name}"
        COMMAND bash "${_script}"
    )
    set_tests_properties("contract.${_name}" PROPERTIES
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        TIMEOUT 300
    )
endforeach()

list(LENGTH _sioyek_contract_scripts _sioyek_contract_count)

# Aggregate entry point (optional): run everything at once
if(EXISTS "${_sioyek_test_dir}/run_all.sh")
    add_test(
        NAME "contract.all"
        COMMAND bash "${_sioyek_test_dir}/run_all.sh"
    )
    set_tests_properties("contract.all" PROPERTIES
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        TIMEOUT 600
    )
endif()

message(STATUS
    "sioyek: CTest contract tests registered (SIOYEK_ENABLE_TESTS=ON, "
    "${_sioyek_contract_count} suites discovered in cmake/tests)")
