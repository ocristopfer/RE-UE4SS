# Linux port tests, run by ctest (and by .github/workflows/linux-ci.yml). They need no game: the
# integration tests on real dedicated servers (tests/linux/integration) run by hand, on a machine
# with the servers installed.

add_executable(linux_itanium_abi_test itanium_abi_test.cpp)
target_include_directories(linux_itanium_abi_test PRIVATE "${CMAKE_SOURCE_DIR}/deps/first/Unreal/include")
target_link_libraries(linux_itanium_abi_test PRIVATE String Zydis)
add_test(NAME linux.itanium_abi COMMAND linux_itanium_abi_test)

add_executable(linux_scanner_selfscan_test scanner_selfscan_test.cpp)
target_link_libraries(linux_scanner_selfscan_test PRIVATE SinglePassSigScanner Helpers)
add_test(NAME linux.scanner_selfscan COMMAND linux_scanner_selfscan_test)

if(TARGET UE4SS)
    add_test(NAME linux.exports COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/check_exports.sh" "$<TARGET_FILE:UE4SS>")
    add_test(NAME linux.preload_inert COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/check_preload_inert.sh" "$<TARGET_FILE:UE4SS>")
    add_test(NAME linux.target_startup COMMAND bash "${CMAKE_CURRENT_SOURCE_DIR}/check_target_startup.sh" "$<TARGET_FILE:UE4SS>"
             "${CMAKE_SOURCE_DIR}/assets/UE4SS-settings.ini")
endif()
