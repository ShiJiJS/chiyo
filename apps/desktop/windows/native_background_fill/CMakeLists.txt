cmake_minimum_required(VERSION 3.14)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(chiyo_native_background_fill LANGUAGES CXX)
  enable_testing()
endif()

add_library(native_background_target STATIC target.cpp discovery.cpp)
target_compile_features(native_background_target PUBLIC cxx_std_17)
target_compile_definitions(native_background_target PUBLIC UNICODE _UNICODE NOMINMAX)
target_compile_options(native_background_target PRIVATE /W4 /WX /EHsc /utf-8)
target_include_directories(native_background_target PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(native_background_target PUBLIC user32 ole32 oleaut32 advapi32 bcrypt wtsapi32)

# Standalone platform work only. Packaging and public host wiring are separate.
option(CHIYO_NATIVE_BACKGROUND_BUILD_BROKER "Build the private App helper" OFF)
if(CHIYO_NATIVE_BACKGROUND_BUILD_BROKER)
  add_executable(native_background_broker WIN32 broker_main.cpp)
  target_compile_features(native_background_broker PRIVATE cxx_std_17)
  target_compile_options(native_background_broker PRIVATE /W4 /WX /EHsc /utf-8)
  target_link_libraries(native_background_broker PRIVATE native_background_target windowsapp)
  set_target_properties(native_background_broker PROPERTIES OUTPUT_NAME "info-native-background-broker")
endif()

add_subdirectory(tests)
