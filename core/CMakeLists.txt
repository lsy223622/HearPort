add_library(hearport_core STATIC
  src/drift_controller.cpp
  src/jitter_buffer.cpp
  src/render_ring_buffer.cpp
  src/wire/audio_datagram.cpp
  src/wire/control_framing.cpp
)

target_include_directories(hearport_core PUBLIC include)
target_compile_features(hearport_core PUBLIC cxx_std_20)

if(BUILD_TESTING)
  add_executable(hearport_wire_codec_tests tests/wire_codec_tests.cpp)
  target_link_libraries(hearport_wire_codec_tests PRIVATE hearport_core)
  add_test(NAME hearport_wire_codec_tests COMMAND hearport_wire_codec_tests)

  add_executable(hearport_realtime_core_tests tests/realtime_core_tests.cpp)
  target_link_libraries(hearport_realtime_core_tests PRIVATE hearport_core)
  add_test(NAME hearport_realtime_core_tests COMMAND hearport_realtime_core_tests)
endif()
