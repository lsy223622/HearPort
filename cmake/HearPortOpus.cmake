include_guard(GLOBAL)

set(HEARPORT_OPUS_SOURCE_DIR
    "${PROJECT_SOURCE_DIR}/ios/HearPortReceiver/Vendor/opus"
    CACHE PATH "Pinned Opus source tree fetched by scripts/fetch_opus.py")

if(NOT EXISTS "${HEARPORT_OPUS_SOURCE_DIR}/CMakeLists.txt")
  message(FATAL_ERROR
    "Pinned Opus source is missing. Run: python scripts/fetch_opus.py")
endif()

set(OPUS_BUILD_SHARED_LIBRARY OFF CACHE BOOL "" FORCE)
if(DEFINED BUILD_SHARED_LIBS)
  set(_HEARPORT_SAVED_BUILD_SHARED_LIBS "${BUILD_SHARED_LIBS}")
  set(_HEARPORT_HAD_BUILD_SHARED_LIBS TRUE)
endif()
set(BUILD_SHARED_LIBS OFF)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_CUSTOM_MODES OFF CACHE BOOL "" FORCE)
set(OPUS_DEEP_PLC OFF CACHE BOOL "" FORCE)
set(OPUS_DRED OFF CACHE BOOL "" FORCE)
set(OPUS_OSCE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)

if(DEFINED BUILD_TESTING)
  set(_HEARPORT_SAVED_BUILD_TESTING "${BUILD_TESTING}")
  set(_HEARPORT_HAD_BUILD_TESTING TRUE)
endif()
set(BUILD_TESTING OFF)
add_subdirectory(
  "${HEARPORT_OPUS_SOURCE_DIR}"
  "${CMAKE_BINARY_DIR}/hearport-opus"
  EXCLUDE_FROM_ALL)
if(_HEARPORT_HAD_BUILD_TESTING)
  set(BUILD_TESTING "${_HEARPORT_SAVED_BUILD_TESTING}")
else()
  unset(BUILD_TESTING)
endif()
if(_HEARPORT_HAD_BUILD_SHARED_LIBS)
  set(BUILD_SHARED_LIBS "${_HEARPORT_SAVED_BUILD_SHARED_LIBS}")
else()
  unset(BUILD_SHARED_LIBS)
endif()

if(NOT TARGET opus)
  message(FATAL_ERROR "The pinned Opus CMake project did not create target opus")
endif()

add_library(hearport_opus_bridge STATIC
  "${PROJECT_SOURCE_DIR}/ios/HearPortReceiver/Sources/HearPortOpusBridge/OpusBridge.c")
target_include_directories(hearport_opus_bridge
  PUBLIC "${PROJECT_SOURCE_DIR}/ios/HearPortReceiver/Sources/HearPortOpusBridge/include")
target_link_libraries(hearport_opus_bridge PUBLIC opus)
target_compile_features(hearport_opus_bridge PRIVATE c_std_11)
set_target_properties(hearport_opus_bridge PROPERTIES POSITION_INDEPENDENT_CODE ON)
