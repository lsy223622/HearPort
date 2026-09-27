# Reliable Audio Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, bounded-lag reliable QUIC audio mode for same-LAN A/B listening while preserving existing DATAGRAM playback.

**Architecture:** The iPad requests reliable audio with a feature bit; the sender echoes acceptance. Audio records remain fixed 968-byte frames over a server-initiated unidirectional QUIC stream, prefaced by session stream ID and generation. Periodic receiver progress over the existing control stream makes the sender abandon a stale audio generation and resume at live capture; the iPad retains its lock-free render ring and jitter-buffer trimming.

**Tech Stack:** C++20, MsQuic, Swift 5.9, Network.framework, AVAudioEngine, CMake/CTest, Swift Package/Xcode GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-27-reliable-audio-mode-design.md`

## Global Constraints

- Low latency remains the default, with its present DATAGRAM and 4–128-packet choices untouched.
- Stability mode uses a fixed 64-packet (160 ms) target, not a 0.5–1 s buffer; no end-to-end acoustic-latency guarantee is inferred.
- Audio remains 48 kHz float32 stereo, 120 frames/2.5 ms, fixed 968-byte records; no codec, FEC, or custom packet retransmission.
- Authentication, control stream, `StartStream`/`StartStreamAck`, diagnostic upload, and lock-free render callback remain intact.
- The sender restarts a reliable audio generation only after two current-generation progress reports showing more than 80 packets of lag, with at least 500 ms between restarts.
- Preserve unrelated changes, especially the existing untracked `docs/superpowers/plans/2026-09-26-hearport-audio-root-cause.md`.

## Review Focus

- A new iPad requesting Stability against an old sender must fail visibly, never silently play DATAGRAM audio (Task 3 test).
- An old iPad against a new sender must continue to receive DATAGRAM audio (Task 3 test).
- Partial/coalesced reliable-stream reads, including a partial preface or record, must not inject malformed PCM (Task 2 test).
- Stale audio-progress reports or UInt32 sequence wrap must not trigger an erroneous restart (Task 2 test).
- Stream reset, timed diagnostic upload, and disconnect must not leave stale callbacks or reinterpret `SEND_COMPLETE` as peer delivery (Tasks 4–5 tests/review).

---

### Task 1: Protocol negotiation and progress message

**Files:** Modify `protocol/hearport-v1.proto`, `core/include/hearport/wire/control_message.h`, `core/src/wire/control_message.cpp`, `core/tests/control_message_tests.cpp`, `ios/HearPortReceiver/Sources/HearPortReceiver/ControlMessages.swift`, `ios/HearPortReceiver/Tests/HearPortReceiverTests/ReceiverCoreTests.swift`, and existing cross-language reference fixtures only where they cover control messages.

**Interfaces:** Produce `kFeatureReliableAudio = 2`, `ControlFeature.reliableAudio = 2`, and `AudioProgress(stream_id, generation, optional latest_received_sequence)` at ControlEnvelope field 39. Add C++ envelope fields `audio_generation`, `audio_sequence`, and `has_audio_sequence` and Swift `.audioProgress(streamID:generation:latestReceivedSequence:)`; reject zero IDs/generations and unexpected fields.

- [ ] Write C++ and Swift codec tests for request/accept bits, progress with sequence zero, absent sequence, malformed zero generation, unknown-feature tolerance, and field 39 byte agreement. Name the behavior each test protects.
- [ ] Run the focused C++ control test and observe a missing-feature failure before code changes. Swift test RED requires a macOS runner; do not push a deliberately broken main solely for RED.
- [ ] Implement the schema and the two hand-written codecs, preserving all existing field encodings.
- [ ] Run focused C++ codec tests and compare Swift fixture bytes with the reference fixture. Expected: no old fixture changes and new cases round-trip.
- [ ] Review/commit only Task 1 files.

### Task 2: Pure record assembly and bounded-lag decision

**Files:** Create `ios/HearPortReceiver/Sources/HearPortReceiver/ReliableAudioRecords.swift` and `windows/include/hearport/windows/reliable_audio_lag.h` plus matching small C++ source if required; modify `ios/HearPortReceiver/Tests/HearPortReceiverTests/QuicTransportTests.swift`, add `windows/tests/reliable_audio_lag_tests.cpp`, and register that test in `windows/CMakeLists.txt`.

**Interfaces:** Swift `ReliableAudioRecords.append(_ bytes: Data) throws -> [AudioDatagram]` consumes 8-byte big-endian `(streamID,generation)` preface then 968-byte records across arbitrary read boundaries; expose validated `streamID` and `generation`. C++ `ReliableAudioLag::Observe(streamID, generation, latestReceivedSequence, latestProducedSequence, now)` returns whether a restart is due, with a separate reset after restart; 80-packet, 2-report, 500-ms policy and wrap-safe distance.

- [ ] Write tests for one-byte splits, joined records, wrong stream ID, zero generation, partial EOF, 80 versus 81 packets, two-report rule, stale generation, silence, cooldown, and wrap.
- [ ] Run local C++ lag test RED, then implement the two small components without Network.framework or MsQuic dependencies.
- [ ] Run local C++ lag test GREEN and focused existing core tests. Swift parser tests will run in Actions.
- [ ] Review/commit only Task 2 files.

### Task 3: Mode selection and receiver control

**Files:** Modify `ios/HearPortReceiver/Sources/HearPortReceiver/HearPortApp.swift`, `ReceiverControlSession.swift`, `QuicReceiver.swift`, and relevant existing Swift tests; modify `windows/src/sender_authentication.cpp`, its header, and targeted C++ authentication tests where they exist.

**Interfaces:** iPad persists a `Low latency`/`Stability` selection, fixed Stability target 64, requests feature bit 2, requires it in SessionReady, and sends at most one outstanding AudioProgress every 100 ms only while reliable media is active. Sender selects the mode from the request and echoes the bit, leaving old-client DATAGRAM behavior unchanged. Receiver has a method to reset audio buffering for a new reliable generation without resetting authentication or timed diagnostics.

- [ ] Add tests for both compatibility directions, explicit unsupported-Stability error, mode-specific buffer target, progress lifecycle, and new-generation receiver reset. Run applicable local C++ test RED.
- [ ] Implement the mode picker and negotiation; wire progress timer to the current stream/generation and cleanly cancel it on disconnect.
- [ ] Run targeted C++ tests GREEN; defer Swift execution to Actions but inspect compile-facing signatures against the Swift tests.
- [ ] Review/commit only Task 3 files.

### Task 4: Windows reliable send and live-edge restart

**Files:** Modify `windows/include/hearport/windows/quic_server.h`, `windows/src/quic_server_msquic.cpp`, `windows/include/hearport/windows/sender_service.h`, `windows/src/sender_service.cpp`, and targeted Windows tests.

**Interfaces:** `QuicServer` can start/abort a server-initiated unidirectional audio generation and send the same encoded 968-byte audio record over it; DATAGRAM path remains available. `SenderService` records latest produced sequence, observes AudioProgress, and on a lag decision clears unsent application audio and begins the next generation without changing authenticated application stream ID or diagnostic-session ID.

- [ ] Add a test for queue/lag restart behavior using the Task 2 policy and existing service seams; do not add a generalized transport abstraction solely for a test. Run RED where locally testable.
- [ ] Implement MsQuic stream ownership, preface, send-buffer lifetime, shutdown callbacks, and bounded queue; log open/abort/failure/restart outside capture and render callbacks.
- [ ] Implement sender mode dispatch and progress handling; keep datagram metrics distinct from reliable stream send completion.
- [ ] Build Debug MsQuic sender with `cmake --build out/build/vs2022-x64-msquic-vs --config Debug`, then run focused `ctest --test-dir out/build/vs2022-x64-msquic-vs -C Debug --output-on-failure`. Expected: build exits 0 and relevant tests pass.
- [ ] Review/commit only Task 4 files.

### Task 5: iPad incoming stream and interoperability

**Files:** Modify `ios/HearPortReceiver/Sources/HearPortReceiver/QuicReceiver.swift`, `ios/HearPortReceiver/Tests/HearPortReceiverTests/QuicTransportTests.swift`, `tests/integration/quic_echo_server.py`, and only directly required tests/diagnostic summaries.

**Interfaces:** `HearPortQuicTransport` accepts a server-initiated unidirectional audio stream only in negotiated Stability mode, assembles fixed records via Task 2, passes each to the existing receiver pipeline, replaces an older generation, and rejects malformed/stale streams without blocking the audio callback. Set `initialMaxStreamsUnidirectional` high enough for bounded replacement; never mistake the control stream for audio.

- [ ] Extend the loopback QUIC server and test to deliver split/coalesced reliable records, then a replacement generation, while checking control and DATAGRAM legacy test still runs.
- [ ] Implement incoming stream receive loop, error/EOF handling, generation replacement, and diagnostic events. No per-record synchronous file I/O.
- [ ] Run local Windows tests again. Push the verified commit to the user-authorized `main` and run the existing Swift package and unsigned IPA GitHub Actions jobs; inspect their actual result and fix reported errors. Do not download the IPA automatically.
- [ ] Review final diff for unnecessary scope expansion. Report the Actions artifact/link and that true iPad continuity/acoustic delay still require installation and A/B listening.

## Execution note

The user explicitly requested design and plan followed by development in the current checkout, without step-by-step approvals or an isolated worktree. Implement natively here. Do not overwrite the pre-existing untracked plan. The iPad has no local Swift/Xcode compiler; use GitHub Actions for its compilation and package tests, and distinguish those checks from the user's device listening result.
