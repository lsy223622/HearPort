cmake_minimum_required(VERSION 3.24)

project(HearPort VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(HEARPORT_BUILD_WINDOWS "Build the Windows sender" ON)
option(HEARPORT_BUILD_REFERENCE_TESTS "Expose reference-test helper targets" ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(FindHearPortDependencies)
include(CTest)

add_library(hearport_protocol_artifacts INTERFACE)
target_include_directories(
  hearport_protocol_artifacts
  INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/protocol"
)

add_subdirectory(core)
add_subdirectory(security)

if(BUILD_TESTING)
  add_test(
    NAME hearport_reference_protocol_constants
    COMMAND ${CMAKE_COMMAND} -E env
      "PYTHONPATH=${CMAKE_CURRENT_SOURCE_DIR}"
      python -m unittest tests.reference.test_protocol_constants -v
  )
endif()

if(WIN32 AND HEARPORT_BUILD_WINDOWS)
  add_subdirectory(windows)
endif()

if(BUILD_TESTING)
  set(hearport_test_directories core security)
  if(WIN32 AND HEARPORT_BUILD_WINDOWS)
    list(APPEND hearport_test_directories windows)
  endif()
  foreach(directory IN LISTS hearport_test_directories)
    get_property(targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
    foreach(target IN LISTS targets)
      if(target MATCHES "_tests$")
        if(MSVC)
          target_compile_options(${target} PRIVATE /UNDEBUG)
        else()
          target_compile_options(${target} PRIVATE -UNDEBUG)
        endif()
      endif()
    endforeach()
  endforeach()
endif()
