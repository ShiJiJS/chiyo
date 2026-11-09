cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "backup_files.cpp"
  "owner_pdf_renderer.cpp"
  "owner_pdf_previews.cpp"
  "owner_file_opener.cpp"
  "owner_file_open_channel.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "comdlg32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "bcrypt.lib" "advapi32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Native adapter contract check; explicitly built with --target notification_queue_test.
add_executable(notification_queue_test EXCLUDE_FROM_ALL "notification_queue_test.cpp")
apply_standard_settings(notification_queue_test)
target_compile_options(notification_queue_test PRIVATE /utf-8)

add_executable(owner_pdf_renderer_test EXCLUDE_FROM_ALL "owner_pdf_renderer_test.cpp" "owner_pdf_renderer.cpp")
apply_standard_settings(owner_pdf_renderer_test)
target_compile_definitions(owner_pdf_renderer_test PRIVATE NOMINMAX)
target_compile_options(owner_pdf_renderer_test PRIVATE /utf-8)
target_link_libraries(owner_pdf_renderer_test PRIVATE windowsapp.lib)
set_target_properties(owner_pdf_renderer_test PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/owner-pdf-check")

add_executable(owner_file_opener_test EXCLUDE_FROM_ALL "owner_file_opener_test.cpp" "owner_file_opener.cpp")
apply_standard_settings(owner_file_opener_test)
target_compile_definitions(owner_file_opener_test PRIVATE NOMINMAX)
target_compile_options(owner_file_opener_test PRIVATE /utf-8)
target_link_libraries(owner_file_opener_test PRIVATE bcrypt.lib advapi32.lib)
set_target_properties(owner_file_opener_test PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/owner-file-check")

add_executable(desktop_control_fixture EXCLUDE_FROM_ALL "desktop_control_fixture.cpp")
apply_standard_settings(desktop_control_fixture)
set_target_properties(desktop_control_fixture PROPERTIES
  OUTPUT_NAME "info_desktop"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/control-fixture")
