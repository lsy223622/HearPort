# HearPort lock-free render path design

## Intent and evidence

The iPad should continue to render audio when the QUIC receive queue is inserting a packet. In a 140-second build-74 listening run with timed packet capture disabled, the receiver recorded 15 render lock misses and 155 trims. All 15 lock-miss seconds also had 6–9 trims; 119 trims occurred in those seconds. One failed 1,024-frame callback replaces about 21 ms of sound with silence, and the following trims skip approximately the same amount of source audio. The user's report of more small timing jumps later in the run coincides with more lock misses. This is a confirmed receiver-local failure class. Packet concealment and transport delay remain independent possible causes of other artifacts.

Success for this change is zero render-versus-receive lock misses by construction, no new callback blocking on network or diagnostics, no unbounded latency growth, and no loss of existing stream/sequence diagnostics. It does not claim zero network loss or measured 20–40 ms acoustic latency.

## Scope and constraints

- Keep `hearport/1`, 48 kHz stereo Float32, 120-frame audio datagrams, one reliable control stream, fixed user-selected jitter targets `[4, 8, 16, 32, 64, 128]`, and the existing remembered-authentication flow.
- Preserve a separate sequence-aware jitter stage and continuous PCM render ring. Do not add FEC, adaptive target latency, or a new telemetry wire channel.
- The AVAudioSourceNode callback must not acquire a lock shared with network/control code, wait on that code, perform packet parsing, write a log, or allocate new packet/jitter state. Existing resampling and output formatting remain in scope only where needed to read the new ring.
- Use a preallocated single-producer/single-consumer PCM ring. The QUIC-side audio path alone writes PCM; the audio callback alone reads PCM. Publish samples before advancing the write cursor (release) and observe that cursor before reading samples (acquire). The existing relaxed diagnostic atomics must not be reused for data publication without correct ordering.
- Keep the selected target a bound on the intended *combined* jitter-plus-ring media lead; moving frames between stages must not silently add the ring capacity to the selected latency target. A callback quantum larger than the smallest target is a physical output constraint to measure and disclose, not a reason to claim those profiles meet a 10–20 ms acoustic target.
- In callback underflow, output local silence and count exact frames; do not block or replay old-stream PCM. On network bursts, retain bounded buffers and trim only when needed to remain at the fixed real-time position.

## Data flow and ownership

`NWConnectionGroup` continues to deliver datagrams on its serial QUIC queue. The receiver validates stream identity and inserts packets into `JitterBuffer` under the existing non-realtime state synchronization. A producer-side pump consumes the next sequence, records conceal/trim decisions with exact sequence IDs, decodes PCM, and stages samples in the bounded ring when the combined fill and ring capacity permit. It never writes past unread ring frames. The render callback reads only the ring and atomic fill/state snapshots, then runs the existing resampler and writes the output buffer. The callback no longer calls `JitterBuffer.consumeNext`, `concealMissing`, or `decodePCM`, and never takes the receiver's shared lock.

The ring is a private implementation detail, not an additional user latency profile. Startup waits for the selected target in the jitter stage, then moves at most two typical 1,024-frame callback quanta (subject to configured ring capacity and leaving one packet in jitter) into the ring. Thereafter the jitter trim limit is reduced by the ring's occupied packet equivalents, so the two stages together remain near the selected target. A producer-side 5 ms pump also moves already-buffered packets during a receive gap; receive callbacks alone cannot sustain playback from the jitter reserve when the network pauses. At targets smaller than one callback quantum, output can underflow: disclose that constraint rather than adding hidden latency or claiming measured acoustic latency.

## Stream and lifecycle transitions

`StartStream`, connection reset, interruption, route change, and explicit silent-rebuffer each request a new media generation. Under the producer state lock, a reset stops ring writes and publishes a generation request. The render callback observes it without taking that lock, advances its own read cursor to the acquired write cursor, clears any output prepared during a racing reset, and acknowledges the flush with release ordering. The producer resumes new-generation writes only after that acknowledgment; successive reset requests can supersede each other. If the output engine is stopped, the producer waits for its next callback rather than blocking. Pending-stream AUDIO is still rejected before `StartStreamAck` is written. Audio output remains active in silent-rebuffer, and drift correction freezes while no valid media is available.

## Diagnostics and acceptance

Keep the current sender trace and iPad receive/jitter decision records. Per-second summaries must still show receive counts, selected target, jitter and render fill, conceal/trim sequence counts, ring underflow/overflow, output route/rate, and resampler ratio. The render lock-miss metric should remain available for comparison but become zero for the network/shared-state lock path; do not relabel an underflow as a lock miss. All metric updates from capture/render paths remain bounded and nonblocking, and raw PCM/private session logs stay local.

Tests cover ring ordering and acquire/release publication under concurrent producer/consumer use; capacity/underflow; generation reset while reading/writing and rapid resets; pending-stream rejection; jitter reorder/conceal/trim and UInt32 wrap; fixed target profiles including a callback larger than a small target; and drift freeze during silent-rebuffer. After focused Swift tests and the existing QUIC interop check, build an unsigned IPA through GitHub Actions. Compare a same-profile 128-packet device run against build 74 using active-only lock misses, silenced/underflow frames, trims, concealment, route, and listening notes. Network loss may persist and must be reported separately.
