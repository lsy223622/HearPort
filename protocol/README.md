# HearPort v1 protocol artifacts

`hearport-v1.proto` is the canonical control-plane schema for both the C++
sender and the Swift receiver. It is copied from the normative v1 design
documents and remains the source of truth for field numbers and message
semantics. The repository uses a dependency-free, schema-shaped codec in
`core/wire/control_message.cpp` and `ControlMessages.swift` so the reference
and Windows builds do not silently fall back to ad-hoc JSON or a second wire
format; platform builds may replace that adapter with generated protobuf
bindings only when the serialized bytes remain identical.

`protocol_constants.json` contains the fixed v1 wire constants used by the
build and reference tests:

- `hearport/1` ALPN;
- UDP port `52137` by default;
- 48 kHz, stereo, Float32LE PCM;
- 120 frames and 960 PCM bytes per AUDIO application datagram;
- 968 bytes for the complete AUDIO application payload;
- 64 KiB maximum serialized control message.

The 968-byte value is the HearPort application payload size, not the total
QUIC DATAGRAM frame or IP packet size.
