# HearPort v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the HearPort v1 Windows-to-iPad low-latency speaker system defined by `plans/HearPort-Design-Spec-v1.md`, including the interoperable wire format, realtime buffering core, platform adapters, security flow, diagnostics, and verification assets.

**Architecture:** Keep a small platform-independent C++ core for wire validation, packet ordering, jitter/render buffering, concealment, and drift control. The Windows sender adapts WASAPI Loopback and a QUIC implementation to that core; the iPad receiver adapts Network.framework QUIC and AVAudioSession/Audio Unit. Control messages are generated from one canonical protobuf schema, and all platform-independent behavior has deterministic tests before platform integration.

**Tech Stack:** C++20, CMake/CTest, Protobuf, MsQuic on Windows, WASAPI, Swift 5.9+, Swift Package Manager, Network.framework QUIC, AVAudioSession/Audio Unit, CryptoKit/Keychain, Windows CNG/DPAPI, Python 3.11 reference/conformance harness.

**Spec:** `plans/HearPort-Design-Spec-v1.md`; normative interfaces: `plans/HearPort-Protocol-v1.md`, `plans/HearPort-Security-v1.md`, and `plans/hearport-v1.proto`.

## Global Constraints

- The canonical audio profile is 48,000 Hz, two channels, IEEE-754 Float32 little-endian, interleaved L/R.
- Each AUDIO application datagram is exactly 968 bytes: big-endian non-zero `stream_id`, big-endian `sequence`, and 960 PCM bytes for 120 frames.
- The QUIC ALPN is `hearport/1`; iPad is the client, Windows is the server, and the default UDP port is 52137.
- Exactly one client-initiated bidirectional reliable control stream is used; control frames are `uint32_be length || serialized ControlEnvelope`, with length in 1..65536.
- QUIC DATAGRAM is required; AUDIO MUST NOT fall back to a reliable stream, raw UDP, or TCP.
- The realtime capture/render paths must use bounded work and must not perform uncontrolled blocking or unbounded allocation.
- The receiver keeps distinct jitter and render buffers, treats stale/duplicate/old-stream audio as discardable input, and uses silence concealment for missing packets.
- Drift correction is slow, bounded, buffer-fill-driven, and frozen or reset during idle/rebuffer, underflow, interruption, or insufficient valid audio.
- Release builds require authenticated connections; development authentication stubs are test-only and cannot be the release default.
- First pairing uses the Security v1 SPAKE2 P-256/SHA-256/HKDF/HMAC profile and a random six-digit PIN; remembered authentication uses pinned Windows SPKI plus a fresh nonce and HMAC.
- Manual hostname/IP plus port remains the minimum connection path; discovery and onboarding do not enter the media wire protocol.
- No virtual audio device, Opus, FEC, multi-receiver sync, Internet relay, adaptive latency protocol, or cross-device absolute clock protocol is added to v1.

## Review Focus

- A 968-byte payload arriving with one byte missing or extra must be rejected without closing the QUIC connection; the protocol test owns this malformed-input case.
- Sequence numbers around `0xffffffff -> 0` must order correctly and must not classify a valid wrapped packet as late; the sequence/jitter task owns this case.
- A pending stream must discard AUDIO before its matching `StartStreamAck` is written, and old-stream packets must remain harmless after restart; the session task owns this case.
- Long absence of AUDIO must enter local silent-playback/rebuffer without manufacturing 400 loss events per second and must freeze drift estimation; the receiver lifecycle task owns this case.
- Pairing/authentication failures, SPKI mismatch, malformed points, replayed nonce responses, and the sixth failed attempt in one pairing window must fail closed without saving trust material; the security task owns these cases.

---

### Task 1: Repository skeleton and canonical protocol artifacts

**Files:**
- Create: `CMakeLists.txt`
- Create: `cmake/FindHearPortDependencies.cmake`
- Create: `protocol/hearport-v1.proto`
- Create: `protocol/README.md`
- Create: `tests/reference/test_protocol_constants.py`
- Modify: `.gitignore`
- Modify: `README.md`

**Interfaces:**
- Consumes: the exact constants and schema from the three v1 normative documents.
- Produces: `HEARPORT_PROTOCOL_VERSION`, `HEARPORT_AUDIO_DATAGRAM_BYTES`, `HEARPORT_AUDIO_FRAMES`, `HEARPORT_CONTROL_MESSAGE_MAX`, the tracked canonical `.proto`, and a Python test command that can run without C++/Swift toolchains.

- [ ] **Step 1: Write the failing reference test**

Create `tests/reference/test_protocol_constants.py` with assertions for the ALPN, port, PCM profile, datagram layout, stream/sequence rules, and control frame maximum. Load constants from `protocol/protocol_constants.json`; the first run must fail because the manifest does not exist.

- [ ] **Step 2: Run the reference test to verify it fails**

Run: `python -m unittest tests.reference.test_protocol_constants -v`

Expected: FAIL with a missing `protocol/protocol_constants.json` or equivalent missing-artifact error, not an import or syntax error.

- [ ] **Step 3: Add the minimum repository skeleton**

Add the exact schema copied from `plans/hearport-v1.proto`, a machine-readable `protocol/protocol_constants.json`, root CMake options for `HEARPORT_BUILD_WINDOWS` and `HEARPORT_BUILD_IOS_TESTS`, and README build/verification boundaries. Add `protocol/` and `docs/` to `.gitignore` only where generated files are intentionally excluded; keep the canonical schema and source files tracked.

- [ ] **Step 4: Run the reference test to verify it passes**

Run: `python -m unittest tests.reference.test_protocol_constants -v`

Expected: PASS for every constant assertion with zero failures.

- [ ] **Step 5: Commit**

```text
git add CMakeLists.txt cmake protocol tests/reference README.md .gitignore
git commit -m "build: add HearPort v1 protocol skeleton"
```

### Task 2: Wire framing and AUDIO datagram codec

**Files:**
- Create: `core/include/hearport/wire/control_framing.h`
- Create: `core/src/wire/control_framing.cpp`
- Create: `core/include/hearport/wire/audio_datagram.h`
- Create: `core/src/wire/audio_datagram.cpp`
- Create: `core/tests/wire_codec_tests.cpp`
- Create: `tests/reference/test_wire_codec.py`
- Modify: `CMakeLists.txt`

**Interfaces:**
- Consumes: Task 1 constants and canonical schema.
- Produces: `hearport::wire::EncodeControlFrame`, `hearport::wire::ControlFrameDecoder`, `hearport::wire::EncodeAudioDatagram`, `hearport::wire::DecodeAudioDatagram`, and a fixed-size `AudioDatagram` value type.

Required signatures:

```cpp
namespace hearport::wire {
std::vector<std::byte> EncodeControlFrame(std::span<const std::byte> payload);
class ControlFrameDecoder {
 public:
  explicit ControlFrameDecoder(std::size_t max_message = 65536);
  bool Push(std::span<const std::byte> bytes,
            std::vector<std::vector<std::byte>>& complete_messages);
};
struct AudioDatagram {
  std::uint32_t stream_id;
  std::uint32_t sequence;
  std::array<std::byte, 960> pcm;
};
std::array<std::byte, 968> EncodeAudioDatagram(const AudioDatagram& packet);
std::optional<AudioDatagram> DecodeAudioDatagram(std::span<const std::byte> bytes);
}
```

- [ ] **Step 1: Write failing C++ and Python tests**

Cover big-endian length/header encoding, fragmented control frames, multiple frames in one input, zero/oversize lengths, exact 968-byte audio packets, wrong-size rejection, stream zero rejection, and lossless PCM bytes.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m unittest tests.reference.test_wire_codec -v`

Expected: FAIL because the reference codec module and production codec do not exist. If a C++ compiler is available, also run the focused CTest target and expect compilation failure for the missing headers.

- [ ] **Step 3: Implement the minimum codecs**

Use explicit byte shifts and `std::span`; reject malformed sizes before allocation; retain incomplete input in a bounded decoder buffer; never close a session for malformed AUDIO. Do not serialize protobuf fields by hand here: this layer only frames already serialized envelope bytes.

- [ ] **Step 4: Run focused tests and the full available suite**

Run: `python -m unittest tests.reference.test_wire_codec tests.reference.test_protocol_constants -v`

Expected: all Python wire tests pass. When CMake/CTest is available, the native `hearport_wire_codec_tests` target must also pass with zero failures.

- [ ] **Step 5: Commit**

```text
git add core CMakeLists.txt tests/reference
git commit -m "feat: implement HearPort v1 wire codecs"
```

### Task 3: Portable realtime core

**Files:**
- Create: `core/include/hearport/sequence.h`
- Create: `core/include/hearport/jitter_buffer.h`
- Create: `core/src/jitter_buffer.cpp`
- Create: `core/include/hearport/render_ring_buffer.h`
- Create: `core/src/render_ring_buffer.cpp`
- Create: `core/include/hearport/drift_controller.h`
- Create: `core/src/drift_controller.cpp`
- Create: `core/include/hearport/diagnostics.h`
- Create: `core/src/diagnostics.cpp`
- Create: `core/tests/realtime_core_tests.cpp`
- Create: `tests/reference/test_realtime_core.py`

**Interfaces:**
- Consumes: `AudioDatagram` and modular sequence rules from Task 2.
- Produces:

```cpp
enum class PacketDisposition { accepted, duplicate, late, wrong_stream, malformed };
enum class PlaybackMode { pending, buffering, playing, silent_rebuffer };
class JitterBuffer {
 public:
  JitterBuffer(std::uint32_t stream_id, std::size_t capacity_packets,
               std::size_t target_packets);
  PacketDisposition Insert(const wire::AudioDatagram& packet);
  std::optional<wire::AudioDatagram> ConsumeNext();
  std::array<std::byte, 960> ConcealMissing();
  void EnterSilentRebuffer();
  void Reset(std::uint32_t stream_id);
  PlaybackMode mode() const;
  std::size_t fill_packets() const;
};
class RenderRingBuffer { /* bounded producer/consumer PCM API */ };
class DriftController {
 public:
  double Update(std::size_t fill_frames, bool valid_audio, double nominal_ratio);
  void Freeze();
  void Reset();
};
```

- [ ] **Step 1: Write failing behavior tests**

Test modular ordering and wrap, duplicate/late/old-stream classification, startup target depth, missing-packet zero concealment with edge ramp, bounded ring overflow/underflow counters, silent rebuffer statistics, and a positive/negative ppm drift sequence whose correction remains bounded and low-pass filtered.

- [ ] **Step 2: Run tests to verify they fail**

Run: `python -m unittest tests.reference.test_realtime_core -v`

Expected: FAIL because the reference core is not implemented. Run the native focused target too when a compiler is available; it must fail for missing production symbols before implementation.

- [ ] **Step 3: Implement the smallest portable core**

Use a bounded ordered container for jitter packets, modular sequence comparison, explicit playback cursor advancement, and separate render storage. Concealment must never reinsert packets. The drift controller must clamp correction, smooth fill error, and ignore invalid-audio/silent-rebuffer samples.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python -m unittest tests.reference.test_realtime_core -v`

Expected: all model tests pass. Native CTest must pass when the toolchain exists.

- [ ] **Step 5: Commit**

```text
git add core tests/reference CMakeLists.txt
git commit -m "feat: add bounded realtime buffer core"
```

### Task 4: Control/session lifecycle and diagnostics

**Files:**
- Create: `core/include/hearport/session_state.h`
- Create: `core/src/session_state.cpp`
- Create: `core/include/hearport/control_messages.h`
- Create: `core/src/control_messages.cpp`
- Create: `core/tests/session_state_tests.cpp`
- Create: `tests/fixtures/control_messages.json`
- Create: `tests/reference/test_session_state.py`

**Interfaces:**
- Consumes: generated protobuf `ControlEnvelope`, Task 2 framing, and Task 3 jitter buffer.
- Produces: a state machine that accepts only `ConnectRequest` first, gates `SessionReady`, creates pending stream on `StartStream`, sends/accepts matching `StartStreamAck`, starts AUDIO only after the ACK is written, and replaces the stream on capture reset.

- [ ] **Step 1: Write failing state tests**

Test first-message enforcement, invalid auth mode/peer-id lengths, pending AUDIO discard, matching and mismatching ACKs, old stream discard after restart, malformed control envelope handling, and classification into fatal connection error vs stream restart vs local recoverable event.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python -m unittest tests.reference.test_session_state -v`

Expected: FAIL for missing state-machine implementation.

- [ ] **Step 3: Implement the state machine**

Generate language bindings from the canonical `.proto` at build time. Keep state transitions explicit and reject empty/unknown/illegal envelope messages with `ERROR_CODE_PROTOCOL`; do not add capability negotiation, telemetry messages, or additional streams.

- [ ] **Step 4: Run focused and full tests**

Run: `python -m unittest discover -s tests -v`

Expected: every reference test passes. Native protocol/session CTest targets must pass where supported.

- [ ] **Step 5: Commit**

```text
git add core tests CMakeLists.txt
git commit -m "feat: add control and media stream lifecycle"
```

### Task 5: Windows sender

**Files:**
- Create: `windows/CMakeLists.txt`
- Create: `windows/include/hearport/windows/wasapi_capture.h`
- Create: `windows/src/wasapi_capture.cpp`
- Create: `windows/include/hearport/windows/pcm_normalizer.h`
- Create: `windows/src/pcm_normalizer.cpp`
- Create: `windows/include/hearport/windows/quic_server.h`
- Create: `windows/src/quic_server_msquic.cpp`
- Create: `windows/include/hearport/windows/sender_service.h`
- Create: `windows/src/sender_service.cpp`
- Create: `windows/src/main.cpp`
- Create: `windows/tests/pcm_normalizer_tests.cpp`
- Modify: `CMakeLists.txt`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 2 wire codec and Task 4 authenticated session state.
- Produces: a Windows server that listens on the configured UDP port, accepts one receiver, captures shared-mode WASAPI Loopback, converts to canonical PCM, batches exactly 120 frames, and sends only after matching `StartStreamAck`.

- [ ] **Step 1: Write failing Windows-independent capture/normalizer tests**

Test mono/44.1 kHz/24-bit and stereo/48 kHz/Float32 input conversion into canonical interleaved Float32, exact 120-frame batching, bounded queue backpressure, and endpoint-reset notification.

- [ ] **Step 2: Run the focused tests to verify they fail**

Run: `python -m unittest tests.reference.test_windows_normalizer -v`

Expected: FAIL because no normalizer reference implementation exists.

- [ ] **Step 3: Implement the sender**

Keep WASAPI event-thread work bounded to packet drain, conversion, and bounded queue write. Move protobuf, QUIC sends, logging, and blocking operations to a worker. Use MsQuic with ALPN `hearport/1`, DATAGRAM capability validation, 0-RTT disabled, and no reliable media fallback. Use Windows protected storage for certificate/private-key and remembered credential material.

- [ ] **Step 4: Run tests/build checks**

Run: `python -m unittest discover -s tests -v`; when the Windows toolchain and MsQuic are present, run `cmake --preset windows-release`, `cmake --build --preset windows-release`, and `ctest --preset windows-release --output-on-failure`.

Expected: reference tests pass. Native build/test results must be reported separately and must not be inferred from Python tests.

- [ ] **Step 5: Commit**

```text
git add windows core CMakeLists.txt README.md tests
git commit -m "feat: add Windows WASAPI QUIC sender"
```

### Task 6: iPad receiver and audio lifecycle

**Files:**
- Create: `ios/HearPortReceiver/Package.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/ReceiverModels.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/ControlFraming.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/AudioDatagram.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/JitterBuffer.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/RenderRingBuffer.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/DriftController.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/QuicReceiver.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/AudioSessionController.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/HearPortApp.swift`
- Create: `ios/HearPortReceiver/Tests/HearPortReceiverTests/*.swift`
- Create: `ios/HearPortReceiver/Resources/Info.plist`
- Create: `ios/HearPortReceiver/Resources/HearPort.entitlements`

**Interfaces:**
- Consumes: canonical `.proto`, Task 2/3/4 behavior, and manual endpoint/latency profile input.
- Produces: an iPadOS 16+ receiver that uses Network.framework QUIC as client, keeps exactly one control stream, validates 968-byte datagrams, maintains local silence during idle, and drives the current two-channel output route.

- [ ] **Step 1: Write failing Swift package tests**

Test byte-order/framing, datagram validation, sequence wrap, pending-stream gating, jitter/loss/late behavior, drift freeze during silent rebuffer, and receiver reset on AVAudioSession route/interruption events.

- [ ] **Step 2: Run Swift tests to verify they fail**

Run: `swift test --package-path ios/HearPortReceiver`

Expected: FAIL or report unavailable Swift/Xcode toolchain before production Swift implementation exists. A missing-toolchain result is an environment limitation, not a passing test.

- [ ] **Step 3: Implement the receiver**

Use Network.framework `NWProtocolQUIC`/datagram APIs, configure `AVAudioSession` for playback, build a two-layer jitter/render pipeline, output local zero PCM during silent-rebuffer, and discard stale buffered audio after route/interruption recovery. Do not claim background duration beyond real-device evidence.

- [ ] **Step 4: Run the Swift package tests and the Python conformance suite**

Run: `swift test --package-path ios/HearPortReceiver`; then `python -m unittest discover -s tests -v`.

Expected: Swift tests pass on macOS with the required SDK; otherwise record the exact unavailable-toolchain result. Python conformance remains green.

- [ ] **Step 5: Commit**

```text
git add ios tests
git commit -m "feat: add iPad QUIC audio receiver"
```

### Task 7: v1 security and protected credentials

**Files:**
- Create: `security/include/hearport/security/pairing.h`
- Create: `security/src/pairing.cpp`
- Create: `security/include/hearport/security/remembered_auth.h`
- Create: `security/src/remembered_auth.cpp`
- Create: `security/tests/security_vector_tests.cpp`
- Create: `tests/fixtures/security_vectors.json`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/Pairing.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/KeychainStore.swift`
- Create: `windows/src/credential_store.cpp`
- Create: `docs/security-implementation.md`

**Interfaces:**
- Consumes: Task 4 control states and the exact Security v1 document.
- Produces: PIN-to-scalar/golden-vector helpers, SPAKE2 exchange through a maintained P-256 implementation, SPKI binding, remembered HMAC challenge/response, protected Windows/iPad credential storage, pairing-window rate limiting, and release-build authentication gating.

- [ ] **Step 1: Write failing security vector tests**

Cover PIN leading zero, PIN-to-scalar vector, transcript/SPKI binding, successful and failed confirmation, invalid/out-of-group points, wrong secret, peer-id mismatch, replayed nonce response, fifth/sixth pairing-window failures, and no trust material after failure.

- [ ] **Step 2: Run security tests to verify they fail**

Run: `python -m unittest tests.reference.test_security_vectors -v`

Expected: FAIL because the shared vector implementation is absent.

- [ ] **Step 3: Implement the security boundary**

Use a maintained RFC 9382 SPAKE2 implementation rather than hand-written elliptic-curve formulas; bind `HearPort-Windows-v1 || 0x00 || windows_spki_sha256` and `HearPort-Receiver-v1` exactly as specified; use constant-time HMAC comparison; generate fresh 32-byte nonces; store private material only through CNG/DPAPI and Keychain; make pairing explicit and close the window after five failures. Keep any development stub behind a non-release compile-time configuration.

- [ ] **Step 4: Run security vectors and full available tests**

Run: `python -m unittest discover -s tests -v`; when native dependencies are available, run the C++ security vector target and Swift security tests.

Expected: every vector passes; no test may pass by accepting an unknown certificate globally or by downgrading remembered-auth failure into pairing.

- [ ] **Step 5: Commit**

```text
git add security windows ios tests docs/security-implementation.md
git commit -m "feat: add HearPort v1 pairing and remembered authentication"
```

### Task 8: Product diagnostics, discovery, packaging, and validation record

**Files:**
- Create: `diagnostics/README.md`
- Create: `diagnostics/schemas/sender-events.json`
- Create: `diagnostics/schemas/receiver-events.json`
- Create: `windows/installer/README.md`
- Create: `ios/HearPortReceiver/Resources/Localizable.strings`
- Create: `docs/validation-matrix.md`
- Modify: `README.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: all platform events and counters from Tasks 3–7.
- Produces: local structured logs for capture/source format, stream/sequence, RTT if available, loss/late/duplicate, buffer fills, underrun/overflow, ratio, route/interruption, reset, and authentication state; manual endpoint remains usable when Bonjour is unavailable.

- [ ] **Step 1: Write failing validation-matrix checks**

Add a Python checker that requires every design requirement to have one of `automated`, `native-build`, `real-device`, `network-soak`, or `not-available` evidence and rejects missing rows or claims that a fixture proves real-device behavior.

- [ ] **Step 2: Run the checker to verify it fails**

Run: `python -m unittest tests.reference.test_validation_matrix -v`

Expected: FAIL because the validation matrix and evidence rows are not present.

- [ ] **Step 3: Add diagnostics, onboarding, and the evidence matrix**

Keep diagnostics local and structured; do not add a telemetry stream. Document Windows Firewall/manual endpoint guidance, Bonjour as optional product path, release security defaults, and the exact real-device scenarios for foreground, lock screen, background, interruption, route change, endpoint reset, network impairment, and two-hour/overnight stability.

- [ ] **Step 4: Run final available verification**

Run: `python -m unittest discover -s tests -v`; run `git diff --check`; run native Windows/Swift builds and tests if their toolchains are present; inspect the final diff for generated secrets, insecure defaults, unintended protocol features, and ignored canonical artifacts.

Expected: Python suite and diff check pass. Any unavailable native or real-device checks remain explicitly marked as such in `docs/validation-matrix.md`.

- [ ] **Step 5: Commit**

```text
git add diagnostics windows/installer ios README.md docs .gitignore tests
git commit -m "docs: add HearPort diagnostics and validation matrix"
```

## Completion Contract

- Every task above has a red test run, a minimal implementation, a green targeted run, and a full available-suite run recorded in the SDD ledger.
- The canonical `.proto` and protocol constants are tracked and are the single source for C++ and Swift generation.
- No release default accepts unauthenticated connections or globally trusts unknown certificates.
- Native builds/tests are reported only from fresh command output; Python/reference tests are not presented as proof of WASAPI, QUIC, iPad audio, background, or real Wi-Fi behavior.
- The final branch review checks all five Review Focus cases and the requirements in the v1 design/protocol/security documents.
