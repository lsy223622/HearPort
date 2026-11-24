# HearPort v1 Wire Protocol

## Canonical Artifacts & Codecs

- **`hearport-v1.proto`**: Source of truth for control-plane field numbers and message semantics across both endpoints.
- **`protocol_constants.json`**: Normative v1 wire constants and capability bit assignments verified by `tests/reference/test_protocol_constants.py`.
- **Schema-shaped codecs**: Both the C++ sender (`core/src/wire/control_message.cpp`) and Swift receiver (`ControlMessages.swift`) implement dependency-free protobuf wire codecs matching `hearport-v1.proto`. Platform builds may only swap in generated protobuf bindings if the serialized byte output remains identical.

---

## Baseline Wire Constants

| Parameter | Value | Notes |
| --- | --- | --- |
| ALPN | `hearport/1` | Negotiated on both LAN and USB QUIC connections |
| Default UDP Port | `52137` | Configurable in Windows settings / CLI |
| Fixed Audio Format | 48 kHz stereo `Float32LE` PCM | Baseline `AUDIO` datagram format |
| Audio Datagram Size | 120 frames · 960 PCM bytes · **968 B** total payload | Application payload size (excludes QUIC `DATAGRAM` and IP headers) |
| Max Control Message | 64 KiB | Maximum serialized `ControlEnvelope` length |

---

## Live Audio Format Negotiation

### Live Opus (`capability bit 512`)

When both peers advertise bit `512`, `AudioSetup` carries fields `5–8`:
- `codec`: `0` (Float32 PCM) or `1` (Opus)
- `bitrate`: `192000` or `256000` bps
- `frame_count`: `120`, `240`, or `480` frames
- `lookahead`: codec lookahead frames (echoed back by the sender after creating the encoder)

PCM omits fields `5–8`. The receiver requests its format before `StartStreamAck`, and peers without bit `512` keep the baseline PCM contract. Diagnostic matrices still negotiate baseline PCM here and pick their test format separately.

- **Wire format**: Uses timed record **kind `5`** and `u16`-length Reliable framing.
- **Timeline**: Logical sequence numbers still increment per **120 source frames** (so a 480-frame Opus packet advances the sequence by `4`). Capture timestamps include encoder lookahead within the same end-to-end delay budget, and the receiver splits decoded frames back onto the 120-frame playback grid.
- **State preservation**: Reliable Opus keeps decoder state across bounded pending-window losses instead of replacing the stream at the live edge.

### Variable PCM (`capability bit 4096`)

Coordinated receivers can advertise bit `4096` in `ConnectRequest` to accept variable sample-rate/bit-depth PCM during ordinary playback:

- **Wire format**: Uses timed record **kind `7`** while preserving the 120-frame / 48 kHz timeline in the timed header.
- **Payload layout**: Big-endian `u16` sample rate (`8000–48000 Hz`) + `u8` valid bit depth (`8–32` bits) + interleaved signed little-endian stereo PCM in the smallest whole-byte container (`Float32LE` when 32-bit).
- **Block sizing**: Block `source_frame / 120` carries the difference between consecutive cumulative sample counts at 400 blocks/s, rounded down.
- **Coexistence**: Reliable timed streams parse kind `7` alongside fixed-size kind `0`. Senders may still emit kind `0` for 48 kHz stereo `Float32LE` and keep it for peers without bit `4096`.

---

## USB Framing (`HPUQ`)

Over USB (`usbmux`), encrypted QUIC packets are wrapped in `HPUQ` frames with an 8-byte header:

| Offset | Size | Field | Description |
| --- | ---: | --- | --- |
| `0` | 4 B | Magic | ASCII `HPUQ` |
| `4` | 1 B | Version | `1` |
| `5` | 1 B | Flags | `0` = QUIC packet · `1` = Peer SPKI discovery frame |
| `6` | 2 B | Payload Length | Big-endian `u16` (`1–65535` bytes) |

- **Flag `0`**: Carries one complete encrypted QUIC packet (`1–65535` bytes).
- **Flag `1`**: Sent first by the Windows sender on every new USB connection. Contains **64 ASCII hex characters** representing its certificate SPKI SHA-256 (matching Bonjour TXT `id`). The receiver consumes this frame locally without forwarding it to UDP and uses full identity matching to group USB and LAN routes under one PC.
- **Trust boundary**: Discovery metadata is public and unauthenticated; QUIC TLS certificate pinning and application pairing/HMAC remain authoritative for identity.

---

## Calibration & Compression Diagnostics Extensions

### Receiver-Initiated Environment Calibration

On an authenticated ordinary audio stream, the receiver may send a `ProbeManifest` requesting LAN calibration:
- **Payload**: Calibration version `4`, kind `6`, matching stream ID (`u32` BE), duration (`u16`: `30`, `60`, or `120` seconds), and ceiling (`u16`: `20..2000` ms).
- **Rules**: The manifest envelope's stream ID must match; active diagnostic sessions and duplicate requests are rejected. When accepted, the Windows GUI schedules a restart into LAN calibration mode, and a remembered receiver reconnects using the calibration handshake. Sending a request does not guarantee calibration completes.

### Compression Diagnostics (`capability bit 256`)

Feature bit `256` enables synthetic load and real-music compression comparison sessions (`DiagnosticsStart` allows `60–86400` seconds; neither extension changes ordinary PCM defaults):

- **Music manifests (version `4`, 24 bytes big-endian)**:

| Offset | Field | Encoding / Notes |
| --- | --- | --- |
| `0–3` | `version`, `index`, `count`, `flags` | 4 × `u8` (`version = 4`, `count = 32`, `flags = 2` adaptive Datagram or `3` adaptive Reliable) |
| `4–5` | `seconds` | `u16` |
| `6–7` | `profile`, `repeat` | 2 × `u8` (`0`/`1` = Float32/PCM16 @ 120f; `2–4` = Opus 192 kbps @ 120/240/480f; `5–7` = Opus 256 kbps @ 120/240/480f; 2 repeats) |
| `8–15` | `first_sequence`, `generation` | 2 × `u32` |
| `16–23` | `frames`, `bitrate_kbps`, `lookahead`, `reserved` | 4 × `u16` (`reserved = 0`) |

- **Timed audio records**: Keep the 32-byte timed header; kind `5` identifies Opus (`120`/`240`/`480` frames, payload up to 992 bytes) and kind `6` identifies PCM16 (`120` stereo frames in 480 LE bytes). Sequence coordinates remain 120 frames (480-frame packets advance by `4`). Reliable music v4 uses the stream/generation preface followed by `u16` length-prefixed timed records rather than ordinary fixed-size reliable records.
- **Synthetic manifests (version `3`)**: Run 40 rounds using the exact payload/rate profiles defined in `network_probe.h` and `CoordinatedProbePlan`.
