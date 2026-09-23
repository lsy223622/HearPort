add_library(hearport_windows_audio STATIC
  src/packetizer.cpp
  src/pcm_normalizer.cpp
)

target_include_directories(hearport_windows_audio PUBLIC include)
target_link_libraries(hearport_windows_audio PUBLIC hearport_core)
target_compile_features(hearport_windows_audio PUBLIC cxx_std_20)

if(BUILD_TESTING)
  add_executable(hearport_windows_audio_tests tests/pcm_normalizer_tests.cpp)
  target_link_libraries(hearport_windows_audio_tests PRIVATE hearport_windows_audio)
  add_test(NAME hearport_windows_audio_tests COMMAND hearport_windows_audio_tests)
endif()

find_path(HEARPORT_MSQUIC_INCLUDE_DIR msquic.h)
find_library(HEARPORT_MSQUIC_LIBRARY NAMES msquic MsQuic)

add_library(hearport_windows_platform STATIC
  src/audio_metrics.cpp
  src/credential_store.cpp
  src/debug_session_trace.cpp
  src/debug_report_store.cpp
  src/diagnostic_logger.cpp
  src/quic_server_msquic.cpp
  src/sender_options.cpp
  src/sender_authentication.cpp
  src/sender_service.cpp
  src/wasapi_capture.cpp
)
target_include_directories(hearport_windows_platform PUBLIC include)
target_link_libraries(hearport_windows_platform PUBLIC hearport_windows_audio hearport_security)
target_compile_features(hearport_windows_platform PUBLIC cxx_std_20)

if(HEARPORT_MSQUIC_INCLUDE_DIR AND HEARPORT_MSQUIC_LIBRARY)
  target_compile_definitions(hearport_windows_platform PRIVATE HEARPORT_HAS_MSQUIC=1)
  target_include_directories(hearport_windows_platform PRIVATE
    "${HEARPORT_MSQUIC_INCLUDE_DIR}")
  target_link_libraries(hearport_windows_platform PRIVATE
    "${HEARPORT_MSQUIC_LIBRARY}")
else()
  target_compile_definitions(hearport_windows_platform PRIVATE HEARPORT_HAS_MSQUIC=0)
endif()

target_link_libraries(hearport_windows_platform PRIVATE ole32 avrt advapi32 crypt32)

add_executable(hearport_sender src/main.cpp)
target_link_libraries(hearport_sender PRIVATE hearport_windows_platform)

if(BUILD_TESTING)
  add_executable(hearport_debug_session_trace_tests
    tests/debug_session_trace_tests.cpp)
  target_link_libraries(hearport_debug_session_trace_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_debug_session_trace_tests
           COMMAND hearport_debug_session_trace_tests)

  add_executable(hearport_sender_options_tests tests/sender_options_tests.cpp)
  target_link_libraries(hearport_sender_options_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_sender_options_tests COMMAND hearport_sender_options_tests)

  add_executable(hearport_diagnostic_logger_tests tests/diagnostic_logger_tests.cpp)
  target_link_libraries(hearport_diagnostic_logger_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_diagnostic_logger_tests COMMAND hearport_diagnostic_logger_tests)

  add_executable(hearport_debug_report_store_tests tests/debug_report_store_tests.cpp)
  target_link_libraries(hearport_debug_report_store_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_debug_report_store_tests COMMAND hearport_debug_report_store_tests)

  add_executable(hearport_windows_audio_metrics_tests tests/audio_metrics_tests.cpp)
  target_link_libraries(hearport_windows_audio_metrics_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_windows_audio_metrics_tests
           COMMAND hearport_windows_audio_metrics_tests)
endif()
