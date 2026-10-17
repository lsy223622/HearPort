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

USB carries complete encrypted QUIC packets in `HPUQ` frames: four ASCII magic
bytes, version `1`, one flag byte, and a two-byte big-endian payload length.
Flag `0` contains one QUIC packet (1–65535 bytes). On each USB connection the
Windows sender first sends a flag `1` frame containing exactly 64 ASCII hex
characters: its certificate SPKI SHA-256, also published as the Bonjour TXT
`id`. The receiver consumes that discovery frame without forwarding it to UDP.
Only matching full identities group USB and LAN routes as one computer.
Discovery metadata is public and unauthenticated; QUIC TLS certificate pinning
and pairing still establish the peer identity.

### Receiver-initiated environment calibration

On an authenticated ordinary audio stream, a receiver may send a ProbeManifest containing calibration version 4, kind 6, the current stream ID (u32 big endian), seconds (u16, 30/60/120), and ceiling milliseconds (u16, 20..2000). The manifest envelope stream ID must match. Diagnostic sessions and duplicate requests are rejected. The GUI schedules a restart into the existing LAN calibration mode; a receiver with saved pairing reconnects and uses the ordinary calibration handshake. A sent request is not a completed calibration.
