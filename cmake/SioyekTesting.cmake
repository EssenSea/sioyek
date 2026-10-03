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

# Individual contract test suites
set(_sioyek_contract_tests
    mupdf_contract
    sqlite_contract
    install_contract
    buildtypes_contract
    clean_contract
    packaging_contract
    warnings_contract
    presets
)

foreach(_t IN LISTS _sioyek_contract_tests)
    set(_script "${_sioyek_test_dir}/test_${_t}.sh")
    if(EXISTS "${_script}")
        add_test(
            NAME "contract.${_t}"
            COMMAND bash "${_script}"
        )
        set_tests_properties("contract.${_t}" PROPERTIES
            WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
            TIMEOUT 300
        )
    endif()
endforeach()

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

message(STATUS "sioyek: CTest contract tests registered (SIOYEK_ENABLE_TESTS=ON)")
