# HearPort Realtime Diagnostics and Adjustable Jitter Design

## Goal

Make the remaining audio-stutter investigation evidence-driven without putting file I/O, console I/O, or diagnostic serialization on an audio or network hot path. Add a user-facing jitter-buffer startup target that can be selected from 4 through 128 packets, while keeping the current balanced default of 8 packets.

## User intent and constraints

- HearPort must retain detailed diagnostics for Windows capture/send and iPad receive/render behavior.
- Statistics and high-volume diagnostic entries must never synchronously write files, call console output, or wait for a diagnostic worker from an audio/capture/render callback.
- Raw PCM, authentication material, PINs, credentials, and raw control payloads remain excluded from logs.
- The setting is for troubleshooting real network jitter and bursty delivery; it must be understandable from the iPad UI.
- The existing protocol and audio packet format remain unchanged.
- The existing 8-packet target remains the default.
- The user may select 4, 8, 16, 32, 64, or 128 startup packets. At the current 48 kHz / 120-frame packet format these correspond to approximately 10, 20, 40, 80, 160, and 320 ms of startup buffering.
- The change must be testable locally where possible and through the macOS GitHub Actions package-test and unsigned-IPA jobs.

## Alternatives considered

### Direct logging from callbacks

Keep calling the existing synchronous diagnostics API from receive/render/capture callbacks. This is the smallest diff, but it allows file rotation, `os.Logger`, console output, and lock contention to affect timing. It cannot distinguish an audio problem from a logger-induced stall, so it is rejected.

### One unbounded background queue

Move all diagnostics to a background queue but let the queue grow without a limit. This removes synchronous file I/O but allows a bad connection or verbose debug mode to build unbounded memory and increasingly stale logs. It is rejected.

### Bounded asynchronous sink plus realtime counters (recommended)

Keep hot-path counters in memory, use lock-free/atomic increments for counters touched by callbacks, snapshot state without waiting for the receiver lock, and send only bounded metadata events to a dedicated utility-priority diagnostics worker. If the queue is full, the producer drops the diagnostic item and increments a dropped-item counter. A once-per-second reporter writes a compact structured summary from a background context. This preserves timing and still gives enough information to locate capture pacing, send queue pressure, network burstiness, jitter loss, render underflow, and drift correction.

## Architecture

### Diagnostics sink

Extend `HearPortDiagnostics` with an asynchronous path in addition to its existing synchronous path for low-frequency lifecycle actions:

- `log(...)` remains available for UI, connection, pairing, route, and error events that are not executed from an audio callback.
- `logAsync(...)` accepts an already-bounded metadata event and returns immediately.
- The async queue has a fixed capacity. Enqueue uses a non-blocking admission check; a full queue drops the item and increments `diagnostics_dropped`.
- One serial utility queue owns async file writes, rotation, in-memory-tail updates, and unified-log emission for accepted async items.
- The worker drains before shutdown when the owner explicitly closes a session; it is not awaited by audio/render callbacks.
- The existing redaction rules apply to both paths before an entry can reach the file or unified log.

The async API is used for periodic summaries and high-volume realtime transitions. No packet payload or PCM buffer is passed to either API.

### iOS realtime metrics

Add a receiver-side metrics accumulator associated with a receiver instance. Updates that already occur under the receiver state lock remain in that critical section without acquiring a second blocking lock. Callback-only counters, such as a render lock miss, use atomic storage. The reporter reads atomic counters and attempts a non-blocking receiver-state snapshot; if the state lock is busy, that interval is marked as a skipped snapshot rather than waiting.

The iOS reporter runs once per second on a utility queue and emits one `realtime` summary only while a stream is active or while a recent connection has diagnostic state worth reporting. It resets interval counters on stream reset and retains monotonic totals for the exported session summary.

The summary includes:

- transport: received, accepted, invalid, old-stream, wrong-stream, and rejected datagrams;
- jitter: inserted, duplicate, late, capacity-drop, sequence-gap/lost, concealed, mode, target, current/min/max fill, and last/expected sequence;
- render: current/min/max ring fill, underflow, overflow, callback count, rendered frames, and lock misses;
- conversion: current resampler ratio and drift/fill error;
- session: stream ID, lifecycle state, output route, sample rate, and diagnostic items dropped/skipped.

Low-frequency transitions remain individually logged: stream reset, jitter mode change, silent rebuffer, underflow/overflow onset, route/interruption change, output restart, and transport failure.

### Windows sender metrics

Add a sender metrics accumulator whose counters are updated with `std::atomic` from capture and audio worker code. A dedicated diagnostics thread wakes once per second, exchanges interval counters, reads queue and stream snapshots, and writes the summary outside the capture/audio queue lock.

The Windows summary includes capture format, capture/normalized/packetized frames, queued/sent/dropped packets, send failures, capture resets, current and high-water queue depth, datagram capability/max payload, stream ID, and the last sequence. Existing low-frequency connection and error messages remain, but per-packet statistics no longer print through `std::cerr` while holding an audio queue lock.

### Jitter configuration

Introduce a small value type for the startup target and validate it against the supported values:

```text
4, 8, 16, 32, 64, 128 packets
```

`JitterBuffer` continues to have a finite maximum capacity of 256 packets. The setting changes the number of packets required by `startIfReady`; it does not make the buffer unbounded and does not alter the wire protocol. A target of 128 therefore increases startup tolerance to approximately 320 ms but still leaves bounded memory and a bounded maximum queue.

The receiver is constructed with the selected target when a connection is started. A setting changed during playback takes effect on the next connection or stream start, avoiding an implicit buffer reset in a live audio callback.

### iOS UI

Add a `Jitter buffer` section to the existing SwiftUI form:

- a picker with Low latency (4), Balanced (8), Stable (16), Strong stability (32), Very stable (64), and Maximum stability (128);
- the estimated startup buffer in milliseconds;
- a short explanation that larger values tolerate bursty delivery but increase startup latency;
- a note that the value applies on the next connection.

Persist the selection using `@AppStorage`, clamp an invalid stored value to 8, and pass the normalized value to the receiver created by `connect()`.

## Data flow

```text
WASAPI capture callback ──> atomic capture counters ──> bounded audio queue
                                       │
                                       └──────────────> audio worker ──> QUIC datagram

QUIC receive callback ──> parse + receiver state ──> realtime counters
                                      │                    │
Audio render callback ──> render state ───────────────────┘
                                      │
                 utility reporter (1 s, no hot-path wait)
                                      │
                         bounded async diagnostics sink
                                      │
                         file rotation + unified log
```

The protocol remains unchanged; only local metrics, logging, and the receiver startup target change.

## Testing and acceptance criteria

### iOS package tests

- Verify all six jitter target values are accepted and latency estimates are correct.
- Verify invalid persisted/configured values normalize to the 8-packet default.
- Verify a 128-packet target does not start before 128 packets and the finite maximum remains 256.
- Verify receiver diagnostics contain jitter target, fill, sequence, render, drift, and dropped/skipped fields without PCM or authentication values.
- Verify async diagnostics enqueue returns promptly when the bounded queue is full and records a dropped-item count; no test may depend on wall-clock scheduling for correctness.
- Preserve existing redaction, rotation, receiver-core, lifecycle, and resampler tests.

### Windows tests

- Add focused coverage for the metrics snapshot/exchange behavior if the existing CTest structure exposes a suitable pure unit boundary.
- Build and run existing CTest without changing the audio protocol tests.
- Confirm the sender diagnostics summary is emitted from the diagnostics thread and no audio queue lock is held across diagnostic output.

### GitHub Actions

- Keep Swift package tests and unsigned IPA generation as required jobs.
- Update the checkout and artifact actions to Node.js 24-compatible major versions so the existing Node.js 20 deprecation annotations disappear.
- Ensure the iOS archive compiles the new UI and diagnostics code, and the IPA layout remains valid for local AltStore/AltServer processing.

### Acceptance

The change is complete when a fresh iOS package test run, Windows build/CTest run, and successful GitHub Actions unsigned-IPA run all pass; the app exposes the six jitter targets; and exported diagnostics can show whether a future stutter is caused by capture pacing, sender queue pressure, bursty delivery, jitter loss/rebuffer, render underflow, lock misses, or drift correction without logging sensitive data.

## Non-goals

- No protocol or packet-format change.
- No raw audio, PCM, packet payload, PIN, key, or credential dump.
- No unlimited buffer or unlimited diagnostics queue.
- No live buffer reset while audio is actively rendering.
- No unrelated UI redesign or discovery-service work.
