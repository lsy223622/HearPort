# HearPort Realtime Diagnostics and Jitter Tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`-`) syntax for tracking.

**Goal:** Add non-blocking, detailed iOS/Windows audio diagnostics and expose a bounded 4–128 packet jitter-buffer startup setting in the HearPort iPad app without changing the wire protocol.

**Architecture:** Keep the existing synchronous diagnostics API for low-frequency UI, connection, pairing, and lifecycle events. Add a bounded non-blocking async diagnostics queue whose worker performs file/unified-log writes, and add atomic/in-memory realtime counters with one-second reporters. The iOS receiver owns the jitter target and reports receiver/render metrics; the Windows sender owns capture/queue/send metrics and emits summaries from a separate diagnostics thread.

**Tech Stack:** Swift 5.9, Swift Package Manager, SwiftUI, Foundation, `os.Logger`, iOS 16, a small C11/Clang atomic helper inside the package, C++20, MSVC, CMake/CTest, MsQuic, GitHub Actions on `macos-14`, XcodeGen, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-09-23-hearport-realtime-diagnostics-jitter-design.md`

## Global Constraints

- The existing 8-packet target remains the default.
- Supported user targets are exactly 4, 8, 16, 32, 64, and 128 packets.
- At the current 48 kHz / 120-frame packet format, the 128-packet target is approximately 320 ms of startup buffering.
- `JitterBuffer` maximum capacity remains 256 packets; no buffer or diagnostics queue may grow without a bound.
- Audio/capture/render callbacks must not synchronously write files, call console output, or wait for a diagnostic worker.
- `logAsync` queue admission is non-blocking; a full queue drops metadata and increments a dropped counter.
- Raw PCM, authentication material, PINs, credentials, and raw control payloads must never enter a diagnostic entry.
- The protocol, packet format, QUIC control messages, and audio sample format remain unchanged.
- A jitter setting changed during playback applies only to the next connection or stream start.
- The iOS deployment target remains iOS 16.0 and the package remains usable without a third-party Swift dependency.
- GitHub Actions must continue using `actions/checkout@v5` and `actions/upload-artifact@v6`, which are already present in the current workflow and target the Node.js 24 runtime.
- Work directly on the user-authorized `main` checkout; do not create a worktree or reset unrelated changes.

## Review Focus

- **Async queue saturation:** a full diagnostic queue must return immediately, drop only bounded metadata, and expose the drop count; the queue test owns this behavior.
- **Export while async writes are pending:** UI export must flush accepted entries without waiting on an audio callback; the diagnostics test owns `flush`/export ordering.
- **Invalid or extreme jitter configuration:** values outside the six supported targets normalize to 8, while 128 starts only after 128 packets and remains below the 256-packet maximum; the jitter configuration tests own this behavior.
- **Render lock contention:** a busy receiver lock must return silence without waiting and increment a non-blocking counter; the receiver metrics test owns the deterministic counter path.
- **Sender lifecycle restart:** starting/stopping the sender repeatedly must not leave a diagnostics thread behind or emit duplicate summary loops; the Windows service stop/join path and the final build/CTest lifecycle review own this behavior.

---

### Task 1: Add bounded asynchronous diagnostics and lock-free counters

**Files:**
- Modify: `ios/HearPortReceiver/Package.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortAtomics/include/HearPortAtomics.h`
- Create: `ios/HearPortReceiver/Sources/HearPortAtomics/AtomicUInt64.c`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/AtomicUInt64.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/Diagnostics.swift`
- Modify: `ios/HearPortReceiver/Tests/HearPortReceiverTests/DiagnosticsTests.swift`

**Interfaces:**
- Produces `AtomicUInt64` with `load() -> UInt64`, `increment(by:) -> UInt64`, and `exchange(_:) -> UInt64`; each operation uses relaxed C atomics and never waits on an `NSLock`.
- Extends `DiagnosticsSnapshot` with `asyncQueueDepth: Int` and `asyncDroppedCount: UInt64`.
- Extends `HearPortDiagnostics` with:

~~~swift
@discardableResult
public func logAsync(_ level: DiagnosticsLevel,
                     category: DiagnosticsCategory,
                     message: String,
                     fields: [String: String] = [:]) -> Bool

@discardableResult
public func flushAsync(timeout: TimeInterval = 1.0) -> Bool
~~~

- Keeps `log`, `snapshot`, `recentLines`, `export`, and `clear` source-compatible for existing callers.
- The async queue capacity is injected by the initializer with a production default of 512; queue admission uses `NSLock.try()` and never uses a blocking lock on the producer path.
- The configured level is mirrored in an atomic scalar; `logAsync` reads it without taking the file-state lock, while the UI-facing `level` getter/setter may use the existing state lock.

- [ ] **Step 1: Write failing tests for the async contract and atomic exchange**

Add these focused tests to `DiagnosticsTests.swift`:

~~~swift
func testAsyncEntriesDrainBeforeExportAndRemainRedacted() throws {
    let diagnostics = try makeDiagnostics(asyncQueueCapacity: 4)
    diagnostics.level = .debug

    XCTAssertTrue(diagnostics.logAsync(
        .debug,
        category: .realtime,
        message: "async packet summary",
        fields: ["pin": "123456", "stream_id": "7", "packets": "400"]
    ))
    XCTAssertTrue(diagnostics.flushAsync(timeout: 1.0))

    let exported = try String(contentsOf: diagnostics.export(), encoding: .utf8)
    XCTAssertFalse(exported.contains("123456"))
    XCTAssertTrue(exported.contains("stream_id=7"))
    XCTAssertTrue(exported.contains("packets=400"))
}

func testBoundedAsyncQueueDropsWithoutBlocking() throws {
    let queue = DiagnosticsAsyncQueue<Int>(capacity: 1)
    XCTAssertTrue(queue.tryEnqueue(1))
    XCTAssertFalse(queue.tryEnqueue(2))
    XCTAssertEqual(queue.droppedCount, 1)
    XCTAssertEqual(queue.dequeue(), 1)
}

func testAtomicCounterExchangesIntervalValue() {
    let counter = AtomicUInt64(3)
    XCTAssertEqual(counter.increment(by: 4), 7)
    XCTAssertEqual(counter.exchange(0), 7)
    XCTAssertEqual(counter.load(), 0)
}
~~~

`DiagnosticsAsyncQueue` is an internal bounded queue used by `HearPortDiagnostics`; testing it directly makes queue saturation deterministic and does not depend on worker scheduling.

- [ ] **Step 2: Run the focused tests and verify the RED state**

Run:

~~~powershell
swift test --package-path ios/HearPortReceiver --filter DiagnosticsTests
~~~

Expected result: compilation fails because the new atomic target, async queue, `flushAsync`, and snapshot fields do not exist yet.

- [ ] **Step 3: Add the C atomic target and Swift wrapper**

Add the C target to `Package.swift` and make the Swift target depend on it:

~~~swift
.target(name: "HearPortAtomics",
        path: "Sources/HearPortAtomics",
        publicHeadersPath: "include"),
.target(name: "HearPortReceiver", dependencies: ["HearPortAtomics"]),
~~~

Expose these C functions in `HearPortAtomics.h` and implement them using Clang `__atomic_*` builtins:

~~~c
uint64_t hearport_atomic_load_u64(const uint64_t *value);
uint64_t hearport_atomic_fetch_add_u64(uint64_t *value, uint64_t amount);
uint64_t hearport_atomic_exchange_u64(uint64_t *value, uint64_t replacement);
~~~

`AtomicUInt64` owns an aligned heap-allocated `UInt64` slot, calls the C functions, and is marked `@unchecked Sendable` because the C operations provide the synchronization.

- [ ] **Step 4: Implement the bounded async diagnostics path**

Add an internal `DiagnosticsAsyncQueue<Element>` with:

- fixed capacity validated at initialization;
- a `tryEnqueue` path that uses `NSLock.try()` and returns `false` on lock contention or capacity exhaustion;
- `dequeue` and `wait` operations used only by the diagnostics worker;
- a monotonic dropped counter stored in `AtomicUInt64`.

Update `HearPortDiagnostics` so `logAsync` only filters the level, creates one bounded event, and enqueues it. A serial `.utility` worker dequeues events and calls the existing redaction/file/unified-log implementation. Add `flushAsync(timeout:)` for UI/export/test callers; it may wait on the utility worker, but no realtime callback calls it. `export()` calls `flushAsync` before taking its existing file snapshot. Add async queue depth/dropped count to `DiagnosticsSnapshot` and the exported environment/session summary.

Keep synchronous `log` for low-frequency calls. Do not make the async producer call `appendLocked`, `FileHandle`, `Logger`, or `String(data:)`.

- [ ] **Step 5: Run the focused and complete package tests**

Run:

~~~powershell
swift test --package-path ios/HearPortReceiver --filter DiagnosticsTests
swift test --package-path ios/HearPortReceiver
~~~

Expected result: the new tests and all existing diagnostics, receiver, lifecycle, framing, pairing, and resampler tests pass.

- [ ] **Step 6: Commit the diagnostics core**

~~~powershell
git add ios/HearPortReceiver/Package.swift ios/HearPortReceiver/Sources/HearPortAtomics ios/HearPortReceiver/Sources/HearPortReceiver/AtomicUInt64.swift ios/HearPortReceiver/Sources/HearPortReceiver/Diagnostics.swift ios/HearPortReceiver/Tests/HearPortReceiverTests/DiagnosticsTests.swift
git commit -m "feat: add bounded asynchronous diagnostics"
~~~

### Task 2: Add jitter configuration and iOS receiver realtime metrics

**Files:**
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/JitterBufferConfiguration.swift`
- Create: `ios/HearPortReceiver/Sources/HearPortReceiver/RealtimeAudioMetrics.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/JitterBuffer.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/QuicReceiver.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/RenderRingBuffer.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/DriftController.swift`
- Create: `ios/HearPortReceiver/Tests/HearPortReceiverTests/RealtimeDiagnosticsTests.swift`
- Modify: `ios/HearPortReceiver/Tests/HearPortReceiverTests/ReceiverCoreTests.swift`

**Interfaces:**
- Produces this public configuration value type:

~~~swift
public struct JitterBufferConfiguration: Equatable, Sendable {
    public static let supportedStartupPacketCounts = [4, 8, 16, 32, 64, 128]
    public static let defaultStartupPackets = 8
    public let startupPackets: Int
    public let startupLatencyMilliseconds: Int

    public init(startupPackets: Int)
    public static let balanced: JitterBufferConfiguration
}
~~~

  `init(startupPackets:)` normalizes any unsupported value to 8. Latency is computed as `startupPackets * AudioDatagram.framesPerPacket * 1000 / 48_000`.
- `JitterBuffer` exposes `startupPackets` and accepts a `JitterBufferConfiguration` overload while retaining the existing `startupPackets:` initializer for package callers.
- Produces an internal `RealtimeAudioMetrics` accumulator with atomic interval counters and a `RealtimeAudioMetricsSnapshot` containing transport, jitter, render, resampler, and reporter-drop fields.
- `HearPortReceiver` owns a one-second utility reporter and exposes only this test hook to the package test target:

~~~swift
func emitRealtimeDiagnosticsForTesting()
~~~

- [ ] **Step 1: Write failing tests for all jitter targets and 128-packet startup**

Add tests:

~~~swift
func testJitterConfigurationSupportsAllSixTargets() {
    XCTAssertEqual(
        JitterBufferConfiguration.supportedStartupPacketCounts.map {
            JitterBufferConfiguration(startupPackets: $0).startupLatencyMilliseconds
        },
        [10, 20, 40, 80, 160, 320]
    )
}

func testInvalidJitterConfigurationFallsBackToBalanced() {
    XCTAssertEqual(JitterBufferConfiguration(startupPackets: 0).startupPackets, 8)
    XCTAssertEqual(JitterBufferConfiguration(startupPackets: 129).startupPackets, 8)
}

func testJitterBuffer128PacketTargetRemainsBounded() throws {
    var jitter = JitterBuffer(streamID: 1,
                              configuration: JitterBufferConfiguration(startupPackets: 128),
                              maximumPackets: 256)
    let pcm = Data(repeating: 0, count: AudioDatagram.pcmByteCount)
    for sequence in 0..<127 {
        let next = try AudioDatagram(streamID: 1, sequence: UInt32(sequence), pcm: pcm)
        XCTAssertEqual(jitter.insert(next), .inserted)
    }
    XCTAssertFalse(jitter.startIfReady())
    let finalPacket = try AudioDatagram(streamID: 1, sequence: 127, pcm: pcm)
    XCTAssertEqual(jitter.insert(finalPacket), .inserted)
    XCTAssertTrue(jitter.startIfReady())
    XCTAssertEqual(jitter.fillPackets, 128)
    XCTAssertLessThanOrEqual(jitter.fillPackets, 256)
}
~~~

Update existing receiver diagnostic tests to call `flushAsync(timeout:)` before reading the tail/export because realtime entries will now be asynchronous.

- [ ] **Step 2: Run the focused tests and verify the RED state**

Run:

~~~powershell
swift test --package-path ios/HearPortReceiver --filter "RealtimeDiagnosticsTests|ReceiverCoreTests"
~~~

Expected result: compilation fails because `JitterBufferConfiguration`, the configuration initializer, and the receiver metrics hook do not exist.

- [ ] **Step 3: Implement configuration and bounded jitter behavior**

Add the value type with the exact six allowed values and 8 fallback. Change `JitterBuffer` to store the normalized configuration, expose `startupPackets`, and keep `maximumPackets` preconditioned to be at least the target. Preserve stream reset, duplicate, late, concealment, and capacity behavior.

- [ ] **Step 4: Implement the realtime metrics accumulator**

Track these interval counters with `AtomicUInt64`: received bytes/packets, invalid, accepted, old-stream, wrong-stream, inserted, duplicates, late, capacity drops, lost/concealed, render callbacks/frames, underflow/overflow, render lock misses, skipped reporter snapshots, and diagnostics enqueue drops. Track current/min/max jitter and render fill under the existing receiver lock; do not add a blocking lock to `renderFrames` or `receiveDatagram`. Add the current resampler ratio and drift fill error as reporter-updated scalar state.

Extend `RenderRingBuffer` with a safe way to read its existing underflow/overflow counters and extend `DriftController` with a resettable diagnostic snapshot of ratio/fill error without logging from the render callback.

- [ ] **Step 5: Replace high-volume receiver logging with the reporter**

In `QuicReceiver.swift`:

- parse and mutate buffers exactly as before;
- update metrics while the existing receiver lock is held;
- replace per-datagram summary/file calls with one-second reporter fields;
- keep the first accepted datagram as a single `logAsync` metadata event;
- send invalid-datagram and jitter transition events through `logAsync` after releasing the receiver lock;
- on `renderFrames` lock contention, increment the atomic lock-miss counter and return the existing silence result immediately;
- have the reporter use `lock.try()`, emit `realtime_summary` with all fields listed in the spec, and skip the interval if the lock is unavailable;
- cancel the reporter in `deinit`, and reset interval counters on connection/stream reset.

The reporter must not call `diagnostics.log`, read `Data`, or serialize PCM. `emitRealtimeDiagnosticsForTesting()` invokes the exact same snapshot/emission function synchronously from the test thread without waiting for the timer.

- [ ] **Step 6: Run receiver and package tests**

Run:

~~~powershell
swift test --package-path ios/HearPortReceiver --filter "RealtimeDiagnosticsTests|ReceiverCoreTests"
swift test --package-path ios/HearPortReceiver
~~~

Expected result: all tests pass; exported receiver diagnostics contain jitter target/fill, sequence, render, drift, and dropped/skipped fields, while the PCM marker and authentication values remain absent.

- [ ] **Step 7: Commit the receiver metrics and jitter core**

~~~powershell
git add ios/HearPortReceiver/Sources/HearPortReceiver/JitterBufferConfiguration.swift ios/HearPortReceiver/Sources/HearPortReceiver/RealtimeAudioMetrics.swift ios/HearPortReceiver/Sources/HearPortReceiver/JitterBuffer.swift ios/HearPortReceiver/Sources/HearPortReceiver/QuicReceiver.swift ios/HearPortReceiver/Sources/HearPortReceiver/RenderRingBuffer.swift ios/HearPortReceiver/Sources/HearPortReceiver/DriftController.swift ios/HearPortReceiver/Tests/HearPortReceiverTests/RealtimeDiagnosticsTests.swift ios/HearPortReceiver/Tests/HearPortReceiverTests/ReceiverCoreTests.swift
git commit -m "feat: add receiver realtime metrics and jitter targets"
~~~

### Task 3: Instrument render conversion and add the iPad jitter controls

**Files:**
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/QuicReceiver.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/AudioSessionController.swift`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/HearPortApp.swift`
- Modify: `ios/HearPortApp/project.yml`
- Modify: `ios/HearPortReceiver/Tests/HearPortReceiverTests/RealtimeDiagnosticsTests.swift`

**Interfaces:**
- Produces an internal receiver method used by `PlatformAudioOutputController`:

~~~swift
func recordRenderCallback(requestedFrames: Int,
                          renderedFrames: Int,
                          fillFrames: Int,
                          resamplerRatio: Double,
                          fillError: Double)
~~~

  The method updates atomics/scalars only and never writes a diagnostic entry.
- Produces an internal receiver method used by the reporter/audio-session boundary:

~~~swift
func recordAudioOutput(route: String, sampleRate: Double)
~~~

  It updates the latest safe route/sample-rate metadata without writing from the render callback.
- The SwiftUI view persists `@AppStorage("hearport.jitterStartupPackets")`, normalizes it through `JitterBufferConfiguration`, and constructs a receiver with that target for each new connection.

- [ ] **Step 1: Write the failing receiver render-stat test**

Add a test that calls `recordRenderCallback` with `requestedFrames: 480`, `renderedFrames: 480`, `fillFrames: 720`, `resamplerRatio: 1.0002`, and `fillError: -240`, then calls `emitRealtimeDiagnosticsForTesting()` and asserts the exported summary contains `render_callbacks=1`, `rendered_frames=480`, `render_fill_frames=720`, `resampler_ratio=1.0002`, and `drift_fill_error=-240`.

- [ ] **Step 2: Run the test and verify it fails**

Run:

~~~powershell
swift test --package-path ios/HearPortReceiver --filter RealtimeDiagnosticsTests
~~~

Expected result: the test does not compile because the render metrics method and fields are not implemented.

- [ ] **Step 3: Update the audio render callback without adding blocking work**

In `PlatformAudioOutputController`'s source-node render closure, preserve the existing `DriftController` and `StreamingStereoResampler` sequence. After `receiver.renderFrames(...)` and resampler processing, call `recordRenderCallback(...)` with the already-known frame counts, ratio, and fill error. Do not call `HearPortDiagnostics.log`, `FileHandle`, `Logger`, or a blocking lock from the closure. Keep route, sample-rate, start, stop, interruption, and engine errors on the existing non-realtime paths.

- [ ] **Step 4: Add the SwiftUI jitter-buffer section and receiver lifecycle wiring**

Add this persisted setting and picker:

~~~swift
@AppStorage("hearport.jitterStartupPackets") private var jitterStartupPackets = 8
~~~

Render six labels in the picker:

~~~swift
ForEach(JitterBufferConfiguration.supportedStartupPacketCounts, id: \.self) { packets in
    Text("\(packets) packets (\(JitterBufferConfiguration(startupPackets: packets).startupLatencyMilliseconds) ms)")
        .tag(packets)
}
~~~

Show the selected estimated startup delay and the explanation that larger buffers tolerate bursty delivery but increase startup latency. Show “Applies on next connection.” Normalize the stored integer before use. Call `recordAudioOutput(route:sampleRate:)` after the audio session is activated and on route changes so the next background summary contains the safe output route and sample rate.

When `connect()` starts, cancel and stop the previous control/audio objects, create `activeReceiver = HearPortReceiver(startupPackets: normalizedJitter.startupPackets, diagnostics: diagnostics)`, assign it to `@State`, and pass the same `activeReceiver` to `ReceiverControlSession` and `PlatformAudioOutputController`. This avoids closures retaining a receiver with an old target. Do not reset a live buffer merely because the picker changes.

Increment `CURRENT_PROJECT_VERSION` in `ios/HearPortApp/project.yml` from 12 to 13 so the new IPA is distinguishable from the last physical test build.

- [ ] **Step 5: Run package tests and inspect the app-target diff**

Run:

~~~powershell
swift test --package-path ios/HearPortReceiver
git diff --check
~~~

Expected result: package tests pass; the app target contains the six selectable values, the 8-packet default, and build 13. The iOS-only SwiftUI compilation is reserved for the GitHub Actions archive job.

- [ ] **Step 6: Commit the render/UI change**

~~~powershell
git add ios/HearPortReceiver/Sources/HearPortReceiver/QuicReceiver.swift ios/HearPortReceiver/Sources/HearPortReceiver/AudioSessionController.swift ios/HearPortReceiver/Sources/HearPortReceiver/HearPortApp.swift ios/HearPortApp/project.yml ios/HearPortReceiver/Tests/HearPortReceiverTests/RealtimeDiagnosticsTests.swift
git commit -m "feat: expose adjustable iOS jitter buffer"
~~~

### Task 4: Move Windows audio summaries to a dedicated diagnostics thread

**Files:**
- Create: `windows/include/hearport/windows/audio_metrics.h`
- Create: `windows/src/audio_metrics.cpp`
- Create: `windows/tests/audio_metrics_tests.cpp`
- Modify: `windows/CMakeLists.txt`
- Modify: `windows/include/hearport/windows/sender_service.h`
- Modify: `windows/src/sender_service.cpp`

**Interfaces:**
- Produces a pure C++ `SenderAudioMetrics` with atomic interval counters and:

~~~cpp
struct SenderAudioMetricsSnapshot {
  std::uint64_t capture_callbacks;
  std::uint64_t capture_frames;
  std::uint64_t normalized_frames;
  std::uint64_t packetized_packets;
  std::uint64_t queued_packets;
  std::uint64_t sent_packets;
  std::uint64_t dropped_packets;
  std::uint64_t send_failures;
  std::uint64_t capture_resets;
  std::size_t queue_depth;
  std::size_t queue_high_watermark;
  std::uint32_t stream_id;
  std::uint32_t last_sequence;
  std::size_t datagram_max_payload;
  bool datagram_ready;
  PcmFormat capture_format;
};

class SenderAudioMetrics {
 public:
  void record_capture(std::size_t bytes, const PcmFormat& format);
  void record_normalized_frames(std::size_t frames);
  void record_packetized(std::uint32_t stream_id, std::uint32_t sequence);
  void record_queued();
  void record_sent();
  void record_dropped(bool send_failure);
  void record_capture_reset();
  void set_queue_state(std::size_t depth, bool datagram_ready,
                       std::size_t datagram_max_payload);
  void set_stream(std::uint32_t stream_id);
  SenderAudioMetricsSnapshot exchange_interval();
};
~~~

- `SenderService` owns `std::thread diagnostics_thread_`, a stop flag, and a condition variable; `Start` starts exactly one diagnostics thread and `Stop` wakes and joins it.

- [ ] **Step 1: Write the failing CTest for atomic interval exchange**

Create `windows/tests/audio_metrics_tests.cpp` with a deterministic test:

~~~cpp
int main() {
  hearport::windows::SenderAudioMetrics metrics;
  const hearport::windows::PcmFormat format{};
  metrics.record_capture(480 * sizeof(float) * 2, format);
  metrics.record_normalized_frames(240);
  metrics.record_packetized(7, 11);
  metrics.record_queued();
  metrics.record_dropped(true);

  const auto first = metrics.exchange_interval();
  assert(first.capture_callbacks == 1);
  assert(first.capture_frames == 480);
  assert(first.normalized_frames == 240);
  assert(first.packetized_packets == 1);
  assert(first.queued_packets == 1);
  assert(first.dropped_packets == 1);
  assert(first.send_failures == 1);
  assert(metrics.exchange_interval().capture_callbacks == 0);
  return 0;
}
~~~

- [ ] **Step 2: Configure and run the new test to verify the RED state**

Run from the existing Visual Studio developer shell:

~~~powershell
cmake --build out/build/vs2022-x64-msquic-vs --parallel 4
ctest --test-dir out/build/vs2022-x64-msquic-vs -R hearport_windows_audio_metrics_tests --output-on-failure
~~~

Expected result: configuration/build fails because the metrics header, source, target, and test are not present.

- [ ] **Step 3: Implement `SenderAudioMetrics` and its focused test target**

Use `std::atomic<std::uint64_t>` for interval counters and atomic scalar snapshots for stream/sequence/format metadata. `exchange_interval()` uses `exchange(0)` for interval counters and reads the latest queue/connection state. Compute capture frames from `bytes / (channels * bytes_per_sample)` for `float32`, `int16`, `int24`, and `int32`; do not include raw samples.

Add `src/audio_metrics.cpp` to `hearport_windows_platform` and add a `hearport_windows_audio_metrics_tests` executable to `windows/CMakeLists.txt` under `BUILD_TESTING`.

- [ ] **Step 4: Integrate metrics with capture, packetization, queue, and send paths**

In `SenderService`:

- call `record_capture` and `record_normalized_frames` from `HandleCapturePacket`;
- call `record_packetized` before `EnqueueAudio`;
- call `record_queued` only after a packet enters the queue;
- call `record_dropped(false)` for queue-full/datagram-unavailable drops and `record_dropped(true)` for `SendAudio` failures;
- call `record_capture_reset` from `HandleCaptureReset`;
- call `set_queue_state` from the existing datagram-ready callbacks and after queue depth/high-water updates;
- call `set_stream` from `BeginStream` and record the latest sequence.

Remove `LogAudioSummaryIfDueLocked`. No `std::cerr` call may remain in `EnqueueAudio` or `AudioWorker`, and `SendAudio` must not be called while the queue mutex is held.

- [ ] **Step 5: Implement the dedicated one-second diagnostics thread**

Add `LogAudioSummary()` that exchanges metrics, obtains a short queue-state snapshot under `queue_mutex_`, releases the mutex, and only then writes one line:

~~~text
quic_audio_summary interval_ms=... capture_callbacks=... capture_frames=... normalized_frames=... packetized_packets=... queued_packets=... sent_packets=... dropped_packets=... send_failures=... capture_resets=... queue_depth=... queue_high_watermark=... stream_id=... last_sequence=... datagram_ready=... max_datagram_payload=... capture_sample_rate=... capture_channels=... capture_format=...
~~~

The thread waits on its own condition variable for one second, wakes immediately during `Stop`, and never holds the audio queue mutex across output. Preserve the existing total `dropped_audio_packets()` behavior.

- [ ] **Step 6: Run focused and complete Windows tests**

Run:

~~~powershell
cmake --build out/build/vs2022-x64-msquic-vs --parallel 4
ctest --test-dir out/build/vs2022-x64-msquic-vs -R "hearport_windows_audio_metrics_tests|hearport_windows_audio_tests|hearport_reference_protocol_constants" --output-on-failure
~~~

Expected result: the new metrics test and existing selected tests pass; no protocol fixture changes are required.

- [ ] **Step 7: Commit the Windows diagnostics thread**

~~~powershell
git add windows/include/hearport/windows/audio_metrics.h windows/src/audio_metrics.cpp windows/tests/audio_metrics_tests.cpp windows/CMakeLists.txt windows/include/hearport/windows/sender_service.h windows/src/sender_service.cpp
git commit -m "feat: move sender audio summaries off the worker"
~~~

### Task 5: Run cross-platform validation and produce the new IPA

**Files:**
- Verify: `.github/workflows/ios-receiver.yml`
- Modify: `docs/validation-matrix.md`
- Modify: `.github/workflows/ios-receiver.yml` only if the action versions or artifact validation have regressed from the current `checkout@v5` / `upload-artifact@v6` state.

**Interfaces:**
- The package test job must compile `ios/HearPortReceiver` including the atomic C target and run all XCTest cases.
- The unsigned IPA job must compile the SwiftUI app with build 13, validate bundle identifier `com.lsy223622.HearPort`, and upload `HearPort-unsigned.ipa`.
- The validation matrix records package tests, Windows CTest, Actions archive, and the still-manual iPad audio/network test as separate evidence classes.

- [ ] **Step 1: Add validation-matrix rows for the new evidence**

Update `docs/validation-matrix.md` with rows that distinguish:

~~~text
Swift package: async queue, jitter targets, receiver metrics, redaction
Windows CTest: atomic sender metrics exchange and existing audio tests
GitHub Actions: Swift package plus unsigned iOS archive/IPA build 13
Manual iPad test: real Wi-Fi burst tolerance at 4/8/16/32/64/128 packets
~~~

Mark only the first three as automatable in this run; leave physical iPad stutter/latency as a manual evidence item rather than claiming it from a build.

- [ ] **Step 2: Verify the workflow action versions and test path filters**

Run:

~~~powershell
rg -n "actions/(checkout|upload-artifact)@|ios/HearPortReceiver|ios/HearPortApp" .github/workflows/ios-receiver.yml
~~~

Expected output includes `actions/checkout@v5`, `actions/upload-artifact@v6`, both iOS path filters, and the unsigned archive job. Do not change the workflow if those exact values are present.

- [ ] **Step 3: Run the local repository regressions**

Run:

~~~powershell
python -m unittest discover -s tests -p "test_*.py" -v
cmake --build out/build/vs2022-x64-msquic-vs --parallel 4
ctest --test-dir out/build/vs2022-x64-msquic-vs --output-on-failure
git diff --check
git status --short
~~~

Expected result: Python reference tests, Windows build/CTest, and whitespace validation pass. If the Swift toolchain is available locally, also run:

~~~powershell
swift test --package-path ios/HearPortReceiver
~~~

The required iOS-only archive verification remains the Actions job below.

- [ ] **Step 4: Commit documentation and push the implementation**

~~~powershell
git add docs/validation-matrix.md .github/workflows/ios-receiver.yml
git commit -m "docs: record realtime diagnostics validation"
git push origin main
~~~
- [ ] **Step 5: Watch the GitHub Actions workflow**

Run:

~~~powershell
gh run list --workflow ios-receiver.yml --branch main --limit 3 --json databaseId,status,conclusion,url,headSha
gh run watch <run-id> --exit-status --interval 10
~~~

Expected result: both `swift-package` and `ios-unsigned-ipa` complete successfully. If a job fails, run `gh run view <run-id> --log-failed`, fix only the diagnosed source/project/workflow issue, commit, push, and repeat the same verification.

- [ ] **Step 6: Download and validate the new IPA artifact**

Run:

~~~powershell
$artifactDir = ".artifacts/actions/<run-id>"
New-Item -ItemType Directory -Force $artifactDir | Out-Null
gh run download <run-id> -n HearPort-unsigned-ipa -D $artifactDir
Get-FileHash "$artifactDir/HearPort-unsigned.ipa" -Algorithm SHA256
~~~

Use a ZIP listing command available on the host to verify exactly one `Payload/HearPort.app/Info.plist`, `CFBundleIdentifier=com.lsy223622.HearPort`, and build `13` in the downloaded artifact. Report the hash and artifact path without claiming device playback until the user tests it on the iPad.

- [ ] **Step 7: Inspect the final diff and record evidence**

Run:

~~~powershell
git diff --stat 318a9c2..HEAD
git diff --check
git status --short --branch
~~~

Confirm no generated Xcode project, IPA, certificate, private key, PCM dump, or diagnostic export was accidentally committed. Record the Actions run URL, IPA SHA-256, local CTest result, and Swift test result in `docs/validation-matrix.md`.

- [ ] **Step 8: Commit the final validation evidence**

~~~powershell
git add docs/validation-matrix.md
git commit -m "docs: record final diagnostics validation evidence"
git push origin main
~~~
