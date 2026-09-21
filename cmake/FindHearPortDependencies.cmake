include_guard(GLOBAL)

option(HEARPORT_ENABLE_PROTOBUF "Generate control bindings from hearport-v1.proto" ON)
option(HEARPORT_ENABLE_MSQUIC "Build the Windows MsQuic adapter when available" ON)

if(HEARPORT_ENABLE_PROTOBUF)
  find_package(Protobuf QUIET)
endif()

if(WIN32 AND HEARPORT_ENABLE_MSQUIC)
  find_package(MsQuic CONFIG QUIET)
endif()
