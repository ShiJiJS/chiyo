add_executable(native_background_fixture WIN32 fixture_main.cpp)
target_compile_features(native_background_fixture PRIVATE cxx_std_17)
target_compile_definitions(native_background_fixture PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(native_background_fixture PRIVATE /W4 /WX /EHsc /utf-8)
target_link_libraries(native_background_fixture PRIVATE user32 shell32 windowsapp)

set(CSC "$ENV{WINDIR}/Microsoft.NET/Framework64/v4.0.30319/csc.exe")
set(FRAMEWORK "$ENV{WINDIR}/Microsoft.NET/Framework64/v4.0.30319")
file(TO_NATIVE_PATH "${FRAMEWORK}" FRAMEWORK_NATIVE)
file(TO_NATIVE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/managed_fixture.cs" MANAGED_SOURCE)
set(MANAGED_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/managed/native-managed-fixture.exe")
file(TO_NATIVE_PATH "${MANAGED_OUTPUT}" MANAGED_OUTPUT_NATIVE)
add_custom_command(OUTPUT "${MANAGED_OUTPUT}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/managed"
  COMMAND "${CMAKE_COMMAND}" -E env "LIB=" "${CSC}" /nologo /target:exe /platform:x64 "/out:${MANAGED_OUTPUT_NATIVE}"
    "/reference:${FRAMEWORK_NATIVE}\\System.dll"
    "/reference:${FRAMEWORK_NATIVE}\\System.Core.dll"
    "/reference:${FRAMEWORK_NATIVE}\\System.Web.Extensions.dll"
    "/reference:${FRAMEWORK_NATIVE}\\System.Xaml.dll"
    "/reference:${FRAMEWORK_NATIVE}\\System.Windows.Forms.dll"
    "/reference:${FRAMEWORK_NATIVE}\\System.Drawing.dll"
    "/reference:${FRAMEWORK_NATIVE}\\WPF\\WindowsBase.dll"
    "/reference:${FRAMEWORK_NATIVE}\\WPF\\PresentationCore.dll"
    "/reference:${FRAMEWORK_NATIVE}\\WPF\\PresentationFramework.dll"
    "/reference:${FRAMEWORK_NATIVE}\\WPF\\UIAutomationTypes.dll"
    "${MANAGED_SOURCE}"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/managed_fixture.exe.config"
    "${MANAGED_OUTPUT}.config"
  DEPENDS managed_fixture.cs managed_fixture.exe.config VERBATIM)
add_custom_target(native_background_managed_fixture DEPENDS "${MANAGED_OUTPUT}")

set(CAPABILITY_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/managed/native-capability-fixture.exe")
file(TO_NATIVE_PATH "${CAPABILITY_OUTPUT}" CAPABILITY_OUTPUT_NATIVE)
file(TO_NATIVE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/capability_fixture.cs" CAPABILITY_SOURCE)
add_custom_command(OUTPUT "${CAPABILITY_OUTPUT}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/managed"
  COMMAND "${CMAKE_COMMAND}" -E env "LIB=" "${CSC}" /nologo /target:exe /platform:x64 "/out:${CAPABILITY_OUTPUT_NATIVE}"
    "/reference:${FRAMEWORK_NATIVE}\\System.dll"
    "/reference:${FRAMEWORK_NATIVE}\\System.Drawing.dll"
    "/reference:${FRAMEWORK_NATIVE}\\System.Windows.Forms.dll"
    "/reference:${FRAMEWORK_NATIVE}\\WPF\\WindowsBase.dll"
    "/reference:${FRAMEWORK_NATIVE}\\WPF\\UIAutomationTypes.dll"
    "/reference:${FRAMEWORK_NATIVE}\\WPF\\UIAutomationProvider.dll"
    "${CAPABILITY_SOURCE}"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/managed_fixture.exe.config" "${CAPABILITY_OUTPUT}.config"
  DEPENDS capability_fixture.cs managed_fixture.exe.config VERBATIM)
add_custom_target(native_background_capability_fixture DEPENDS "${CAPABILITY_OUTPUT}")

add_executable(native_background_target_test target_test.cpp)
target_compile_features(native_background_target_test PRIVATE cxx_std_17)
target_compile_options(native_background_target_test PRIVATE /W4 /WX /EHsc /utf-8)
target_link_libraries(native_background_target_test PRIVATE native_background_target)
add_dependencies(native_background_target_test native_background_fixture native_background_managed_fixture native_background_capability_fixture)
add_test(NAME native_background_target COMMAND native_background_target_test
  "$<TARGET_FILE:native_background_fixture>" "${MANAGED_OUTPUT}")
set_tests_properties(native_background_target PROPERTIES TIMEOUT 180)
add_test(NAME native_background_limits COMMAND native_background_target_test
  "$<TARGET_FILE:native_background_fixture>" "${MANAGED_OUTPUT}" limits)
set_tests_properties(native_background_limits PROPERTIES TIMEOUT 60)
add_test(NAME native_background_capabilities COMMAND native_background_target_test
  "$<TARGET_FILE:native_background_fixture>" "${MANAGED_OUTPUT}" "${CAPABILITY_OUTPUT}" capabilities)
set_tests_properties(native_background_capabilities PROPERTIES TIMEOUT 180)
