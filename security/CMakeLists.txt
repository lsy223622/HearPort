set(HEARPORT_SPAKE2_PROVIDER_INCLUDE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/spake2-provider/include")

find_program(HEARPORT_CARGO_EXECUTABLE cargo)
set(HEARPORT_HAS_SPAKE2_PROVIDER OFF)

if(HEARPORT_CARGO_EXECUTABLE)
  if(WIN32)
    set(HEARPORT_SPAKE2_PROVIDER_LIBRARY
        "${CMAKE_CURRENT_BINARY_DIR}/spake2-provider-target/release/hearport_spake2_provider.lib")
  else()
    set(HEARPORT_SPAKE2_PROVIDER_LIBRARY
        "${CMAKE_CURRENT_BINARY_DIR}/spake2-provider-target/release/libhearport_spake2_provider.a")
  endif()
  add_custom_command(
    OUTPUT "${HEARPORT_SPAKE2_PROVIDER_LIBRARY}"
    COMMAND "${HEARPORT_CARGO_EXECUTABLE}" build --release
            --manifest-path "${CMAKE_CURRENT_SOURCE_DIR}/spake2-provider/Cargo.toml"
            --target-dir "${CMAKE_CURRENT_BINARY_DIR}/spake2-provider-target"
    DEPENDS
      "${CMAKE_CURRENT_SOURCE_DIR}/spake2-provider/Cargo.toml"
      "${CMAKE_CURRENT_SOURCE_DIR}/spake2-provider/src/lib.rs"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/spake2-provider"
    VERBATIM)
  add_custom_target(hearport_spake2_provider_build
                    DEPENDS "${HEARPORT_SPAKE2_PROVIDER_LIBRARY}")
  add_library(hearport_spake2_provider STATIC IMPORTED GLOBAL)
  set_target_properties(
    hearport_spake2_provider
    PROPERTIES IMPORTED_LOCATION "${HEARPORT_SPAKE2_PROVIDER_LIBRARY}"
               INTERFACE_INCLUDE_DIRECTORIES "${HEARPORT_SPAKE2_PROVIDER_INCLUDE_DIR}")
  if(WIN32)
    set_property(
      TARGET hearport_spake2_provider
      APPEND
      PROPERTY INTERFACE_LINK_LIBRARIES "ws2_32;userenv;ntdll")
  endif()
  add_dependencies(hearport_spake2_provider hearport_spake2_provider_build)
  set(HEARPORT_HAS_SPAKE2_PROVIDER ON)
endif()

add_library(hearport_security STATIC
  src/pairing.cpp
  src/remembered_auth.cpp
)
target_include_directories(
  hearport_security
  PUBLIC include
  PRIVATE "${HEARPORT_SPAKE2_PROVIDER_INCLUDE_DIR}")
target_compile_features(hearport_security PUBLIC cxx_std_20)
target_compile_definitions(
  hearport_security PRIVATE
  HEARPORT_HAS_SPAKE2_PROVIDER=$<BOOL:${HEARPORT_HAS_SPAKE2_PROVIDER}>)
if(HEARPORT_HAS_SPAKE2_PROVIDER)
  target_link_libraries(hearport_security PRIVATE hearport_spake2_provider)
endif()

if(BUILD_TESTING)
  add_executable(hearport_security_tests tests/security_vector_tests.cpp)
  target_link_libraries(hearport_security_tests PRIVATE hearport_security)
  add_test(NAME hearport_security_tests COMMAND hearport_security_tests)
endif()
