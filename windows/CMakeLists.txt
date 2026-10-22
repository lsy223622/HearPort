include(HearPortOpus)

add_library(hearport_windows_audio STATIC
  src/packetizer.cpp
  src/pcm_normalizer.cpp
)

target_include_directories(hearport_windows_audio PUBLIC include)
target_link_libraries(hearport_windows_audio PUBLIC hearport_core)
target_compile_features(hearport_windows_audio PUBLIC cxx_std_20)

if(BUILD_TESTING)
  add_executable(hearport_audio_deadline_tests tests/audio_deadline_tests.cpp)
  target_link_libraries(hearport_audio_deadline_tests PRIVATE hearport_windows_audio)
  add_test(NAME hearport_audio_deadline_tests COMMAND hearport_audio_deadline_tests)
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
  src/network_probe.cpp
  src/calibration.cpp
  src/music_file.cpp
  src/live_audio_encoder.cpp
  src/quic_server_msquic.cpp
  src/sender_options.cpp
  src/auto_start.cpp
  src/sender_authentication.cpp
  src/sender_service.cpp
  src/usb_tunnel.cpp
  src/sender_host.cpp
  src/service_discovery.cpp
  src/wasapi_capture.cpp
)
target_include_directories(hearport_windows_platform PUBLIC include)
target_link_libraries(hearport_windows_platform PUBLIC hearport_windows_audio hearport_security hearport_opus_bridge)
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

target_link_libraries(hearport_windows_platform PRIVATE ole32 avrt advapi32 crypt32 mfplat mfreadwrite mfuuid ws2_32 xmllite shlwapi dnsapi shell32)

add_executable(hearport_sender src/main.cpp)
target_link_libraries(hearport_sender PRIVATE hearport_windows_platform)

enable_language(RC)
add_executable(hearport_sender_gui WIN32
  src/gui_main.cpp
  src/sender_certificate.cpp
  src/gui_resources.rc
)
target_include_directories(hearport_sender_gui PRIVATE src)
target_compile_definitions(hearport_sender_gui PRIVATE UNICODE _UNICODE)
target_link_libraries(hearport_sender_gui PRIVATE
  hearport_windows_platform ncrypt crypt32 advapi32
  comctl32 comdlg32 shell32 ole32 user32 gdi32 iphlpapi dwmapi uxtheme
)
if(MSVC)
  target_compile_options(hearport_sender_gui PRIVATE /utf-8)
  target_link_options(hearport_sender_gui PRIVATE /MANIFEST:NO)
endif()
if(MINGW)
  target_link_options(hearport_sender_gui PRIVATE -municode)
endif()

if(HEARPORT_MSQUIC_INCLUDE_DIR AND HEARPORT_MSQUIC_LIBRARY)
  get_filename_component(_msquic_library_dir "${HEARPORT_MSQUIC_LIBRARY}" DIRECTORY)
  find_file(HEARPORT_MSQUIC_DLL NAMES msquic.dll
    HINTS "${_msquic_library_dir}/../bin" NO_DEFAULT_PATH)
  if(NOT HEARPORT_MSQUIC_DLL)
    message(FATAL_ERROR "msquic.dll was not found beside ${HEARPORT_MSQUIC_LIBRARY}")
  endif()
  foreach(sender IN ITEMS hearport_sender hearport_sender_gui)
    add_custom_command(TARGET ${sender} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${HEARPORT_MSQUIC_DLL}" "$<TARGET_FILE_DIR:${sender}>"
      VERBATIM)
  endforeach()
endif()

if(BUILD_TESTING)
  add_executable(hearport_auto_start_tests tests/auto_start_tests.cpp)
  target_link_libraries(hearport_auto_start_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_auto_start_tests COMMAND hearport_auto_start_tests)
  add_executable(hearport_opus_codec_tests tests/opus_codec_tests.cpp)
  target_link_libraries(hearport_opus_codec_tests PRIVATE hearport_opus_bridge)
  add_test(NAME hearport_opus_codec_tests COMMAND hearport_opus_codec_tests)
  add_executable(hearport_live_audio_encoder_tests tests/live_audio_encoder_tests.cpp)
  target_link_libraries(hearport_live_audio_encoder_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_live_audio_encoder_tests COMMAND hearport_live_audio_encoder_tests)
  add_executable(hearport_shared_pairing_tests tests/shared_pairing_tests.cpp)
  target_link_libraries(hearport_shared_pairing_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_shared_pairing_tests COMMAND hearport_shared_pairing_tests)
  add_executable(hearport_usb_tunnel_tests tests/usb_tunnel_tests.cpp)
  target_link_libraries(hearport_usb_tunnel_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_usb_tunnel_tests COMMAND hearport_usb_tunnel_tests)
  add_executable(hearport_connection_selection_tests tests/connection_selection_tests.cpp)
  target_link_libraries(hearport_connection_selection_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_connection_selection_tests COMMAND hearport_connection_selection_tests)
  add_executable(hearport_calibration_tests tests/calibration_tests.cpp)
  target_link_libraries(hearport_calibration_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_calibration_tests COMMAND hearport_calibration_tests)
  add_executable(hearport_music_file_tests tests/music_file_tests.cpp)
  target_compile_definitions(hearport_music_file_tests PRIVATE NOMINMAX)
  target_link_libraries(hearport_music_file_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_music_file_tests COMMAND hearport_music_file_tests)
  add_executable(hearport_debug_session_trace_tests
    tests/debug_session_trace_tests.cpp)
  target_link_libraries(hearport_debug_session_trace_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_debug_session_trace_tests
           COMMAND hearport_debug_session_trace_tests)

  add_executable(hearport_network_probe_tests tests/network_probe_tests.cpp)
  target_link_libraries(hearport_network_probe_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_network_probe_tests COMMAND hearport_network_probe_tests)

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

  add_executable(hearport_reliable_audio_lag_tests
    tests/reliable_audio_lag_tests.cpp)
  target_link_libraries(hearport_reliable_audio_lag_tests PRIVATE hearport_windows_platform)
  add_test(NAME hearport_reliable_audio_lag_tests
           COMMAND hearport_reliable_audio_lag_tests)
endif()
