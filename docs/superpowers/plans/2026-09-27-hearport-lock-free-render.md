# HearPort Lock-Free Render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate receiver-local render silence caused by contention with QUIC packet insertion while retaining bounded buffering and sequence diagnostics.

**Architecture:** A preallocated C SPSC stereo PCM ring provides acquire/release publication and a generation-reset handshake. Swift's QUIC-side producer keeps the existing sequence-aware jitter buffer and pumps a bounded reserve into that ring; the AVAudioSourceNode callback only reads the ring, atomic state, and existing resampler.

**Tech Stack:** Swift 5.9, C11 atomics via compiler builtins, SwiftPM/XCTest, GitHub Actions macOS/iOS builds.

**Spec:** `docs/superpowers/specs/2026-09-27-hearport-lock-free-render-design.md`

## Global Constraints

- Preserve `hearport/1`, 48 kHz stereo Float32, 120-frame audio datagrams, and fixed user targets `[4, 8, 16, 32, 64, 128]`.
- No network/shared-state lock, packet parsing, log write, or packet/jitter allocation in the audio callback.
- Bound total jitter-plus-ring lead to the selected target; do not add FEC/adaptive targets/new wire telemetry.
- Preserve the pre-ACK audio rejection and existing sender/iPad diagnostics; distinguish local ring underflow from network concealment.
- User explicitly authorized implementation directly on `main`; preserve untracked `docs/superpowers/plans/2026-09-26-hearport-audio-root-cause.md`.

## Review Focus

- Reset during a concurrent pop must never output previous-stream samples after acknowledgment; Task 1 reset-race test.
- Receive pause with packets still in jitter must keep playing until that reserve is exhausted; Task 2 receive-gap test.
- 4-packet target with a 1,024-frame callback must not silently add latency; Task 2 small-target test.
- Pending-stream audio before ACK must not enter the PCM ring; Task 2 integration test.
- An output interruption and immediate new stream must converge on the newest generation; Task 2 lifecycle test.

---

### Task 1: Preallocated SPSC PCM ring and generation barrier

**Files:**
- Create: `ios/HearPortReceiver/Sources/HearPortAtomics/AudioRing.c`
- Modify: `ios/HearPortReceiver/Sources/HearPortAtomics/include/HearPortAtomics.h`
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/RenderRingBuffer.swift`
- Create: `ios/HearPortReceiver/Tests/AudioRingCTests.c`
- Modify: `.github/workflows/ios-receiver.yml`

**Interfaces:**
- Produces `RenderRingBuffer(capacityFrames:)`, `fillFrames`, `requestReset()`, `isResetAcknowledged`, `push(_:) -> Int`, `pop(frames:) -> (samples: [Float], renderedFrames: Int)`; only producer calls `requestReset`/`push`, only consumer calls `pop`.
- C ring uses opaque handle, monotonic read/write cursors, release/acquire publication, and requested/acknowledged generation counters. A push returns zero while a reset is unacknowledged; pop zeros missing frames and zeros its entire result if reset races with copying.

- [ ] **Step 1: Write the failing C regression test.** Assert FIFO/wrap, bounded push, exact partial underflow, no stale samples after reset, repeated reset convergence, and concurrent producer/consumer values with no duplication or torn frames. Expected literals are hand-derived.
- [ ] **Step 2: Run the C test against current sources.** `C:\msys64\mingw64\bin\gcc.exe -std=c11 -O2 -pthread ...` must fail because the ring API is not yet defined.
- [ ] **Step 3: Implement the C ring and Swift wrapper.** Add only the required functions to the existing atomics target; use compiler `__atomic` acquire/release operations, not the current relaxed diagnostic atomic wrapper. Preserve ring storage for the receiver lifetime.
- [ ] **Step 4: Run the C test.** Same compile command followed by the test executable must pass; run with `-O0` and `-O2` to cover optimization-sensitive publication.
- [ ] **Step 5: Add a focused C test invocation before `swift test` in the macOS workflow and commit only Task 1 files.**

### Task 2: Producer-side jitter pump and nonblocking output callback

**Files:**
- Modify: `ios/HearPortReceiver/Sources/HearPortReceiver/{QuicReceiver,JitterBuffer,AudioSessionController}.swift`
- Modify: `ios/HearPortReceiver/Tests/HearPortReceiverTests/{ReceiverCoreTests,RealtimeDiagnosticsTests}.swift`

**Interfaces:**
- Consumes Task 1 `RenderRingBuffer` API.
- Produces receiver `renderFillFrames` and `renderFrames(_:)` without acquiring the shared `NSLock`; `isRenderActive` is an atomic snapshot for drift validity.
- `JitterBuffer.insert(_:stagedFrames:)` bounds running jitter fill by selected target less occupied ring packet equivalents, while initial `startIfReady()` still requires the selected target. Producer pump stages no more than two 1,024-frame quanta, configured capacity, or target less one packet. A 5 ms producer timer drains jitter during receive gaps.

- [ ] **Step 1: Write failing receiver tests.** Assert sample order across a 1,024-frame callback while new packets arrive; fixed 4/128 targets' combined fill; receive-gap reserve; pending-ACK rejection; reset/interruption and quick restart; absence of callback lock misses even while state lock is held; active-only underflow accounting.
- [ ] **Step 2: Run available local checks and record the Swift limitation.** Windows has no Swift/Xcode; use Task 1 C test locally and run the Swift tests in GitHub Actions at the first buildable push. Do not claim a Swift RED run occurred locally.
- [ ] **Step 3: Move packet consumption/concealment/PCM decode to producer under the existing state lock.** Pump on receive and 5 ms timer, but do not hold the lock on the audio callback. Keep exact conceal/trim sequence decisions and bounded metrics. On lifecycle/connection/stream reset request a ring generation; producer waits for callback acknowledgment rather than blocking.
- [ ] **Step 4: Convert render callback state and fill reads to atomics and ring pop.** Preserve existing resampler/output-format conversion; freeze drift without valid media; keep lock-miss counter for comparison but do not generate misses in the render path.
- [ ] **Step 5: Review the changed Swift files for data races and total-buffer accounting, then commit Task 2 files.**

### Task 3: CI, device comparison, and final audit

**Files:**
- Change only directly relevant code/tests if verification exposes a defect.

**Interfaces:**
- Consumes Task 1/2 implementation and existing GitHub Actions `swift-package` and `ios-unsigned-ipa` jobs.
- Produces a successful run ID, unsigned IPA artifact, and explicit device comparison with build 74 or a stated verification limitation.

- [ ] **Step 1: Run focused local C ring and Windows sender checks; inspect `git diff --check` and the entire diff.** Rebuild sender only if its source changed; otherwise preserve the existing binary.
- [ ] **Step 2: Push the implementation commit to `origin/main` to run Actions, then verify Swift tests, QUIC interop, and unsigned IPA artifact.** The user authorized continuous GitHub Actions testing and direct main work; announce the push before doing it.
- [ ] **Step 3: Ask the user to install the new IPA and run the same 128-packet listening test.** Compare active-only render lock misses, underflow frames, trims, concealments, packet send states and audible timing against build 74; keep packet loss a separate hypothesis.
- [ ] **Step 4: Inspect the final diff once more and remove unrelated changes.** Report exact tests/run IDs, artifact identity, measured improvement or residual issue, and device-test status without claiming acoustic latency from software timestamps.
