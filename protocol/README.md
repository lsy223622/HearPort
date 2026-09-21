# HearPort v1 protocol artifacts

`hearport-v1.proto` is the canonical control-plane schema for both the C++
sender and the Swift receiver. It is copied from the normative v1 design
documents and must be used as the input to each platform's protobuf code
generator; field numbers must not be re-created independently in platform
code.

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
