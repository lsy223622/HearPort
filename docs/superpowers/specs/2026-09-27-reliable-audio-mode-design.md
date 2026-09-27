# HearPort reliable-audio comparison mode

## Intent and limits

Add an opt-in **Stability** mode that uses QUIC's reliable, ordered delivery for Windows-to-iPad PCM audio. Keep today's DATAGRAM mode and its buffer choices unchanged as **Low latency**. The experiment tests whether retransmission removes audible isolated-packet artifacts on the user's LAN without accepting unbounded delay. It does not promise glitch-free playback: prior iPad receive gaps reached roughly 250–280 ms, longer than the proposed 160 ms startup buffer. Buffer duration is not measured end-to-end acoustic latency.

This is a protocol extension to `hearport/1`, not a codec, clock-correction, pairing, or diagnostic-upload redesign. Maintain 48 kHz float32 stereo, 120-frame (2.5 ms), 968-byte audio records and the existing lock-free render ring. No custom audio retransmission or FEC.

## Alternatives and decision

1. **Selected: one server-initiated unidirectional reliable audio stream at a time, with bounded epoch restarts.** QUIC retransmits isolated missing bytes. Progress feedback lets the sender abandon a stale stream without implementing packet ACK/retry logic. The receiver retains its existing buffer trimming after delivery catches up.
2. Reliable stream without restarts is smaller initially, but it can accumulate arbitrarily old audio under sustained throughput loss; it fails the user's live-playback requirement.
3. DATAGRAM with selective resend/FEC may ultimately yield better latency, but requires a separate recovery protocol and is outside this comparison.

## Selection and compatibility

The iPad has a persisted mode picker. Low latency remains the default and uses the current user-selected 4–128-packet target. Stability uses a separate 64-packet (160 ms) fixed target for this experiment; no 0.5–1 s buffer is introduced. Mode changes take effect on the next connection.

`ConnectRequest.features` bit 1 (`0x2`) requests reliable audio; `SessionReady.features` echoes it only when the Windows sender accepts it. An old sender therefore remains usable in Low latency mode, but Stability fails clearly if the bit is absent; never silently fall back to DATAGRAM. A new sender uses DATAGRAM when the bit was not requested, including with an old iPad. The existing diagnostics bit (`0x1`) remains independent. Authentication and the existing `StartStream`/`StartStreamAck` gate remain mandatory before any media.

## Reliable audio transport

The Windows sender opens a unidirectional stream after `StartStreamAck`. Its first eight bytes are the current application `stream_id` and an audio-stream `generation`, both big-endian UInt32; the initial generation is 1. Thereafter the byte stream consists of consecutive fixed 968-byte `AudioDatagram` records. QUIC stream read boundaries have no application meaning: the iPad assembles complete records and rejects a trailing partial record, wrong `stream_id`, zero generation, unexpected mode, or older generation. It accepts only the current sender-initiated audio stream; the client-initiated bidirectional control stream is unchanged. A new generation cancels the older receive flow and resets only jitter/render audio buffering, not authentication, speaker session, or the timed diagnostic session. PCM sequence numbers and application `stream_id` continue across generations. The audio render callback never waits on QUIC or a network lock.

MsQuic send buffers are retained until `QUIC_STREAM_EVENT_SEND_COMPLETE`; that event is **not** proof of peer delivery. Stream abort/shutdown completes asynchronously; handles and callback contexts remain valid until shutdown completion. A mode-specific finite queue limit prevents unlimited application-side PCM retention. The current DATAGRAM send path and `lost_discarded` trace semantics do not change.

## Live-edge bound

During Stability playback, the iPad sends one small `AudioProgress(stream_id, generation, latest_received_sequence?)` control message every 100 ms. Sequence is absent before the first audio record of that generation. The sender compares the latest produced audio sequence with the latest received sequence using wrap-safe UInt32 arithmetic. If valid progress reports for the current generation show more than 80 packets (200 ms of source audio) of transport lag twice consecutively, and at least 500 ms has elapsed since the last restart, the sender clears unsent application audio, aborts that generation, opens the next generation, and resumes with the latest capture audio. Stale feedback is ignored. A current-generation report without a received sequence counts as lag only after the sender has produced more than 80 packets in that generation. The sender never restarts merely because the Windows source is silent. Progress writes are coalesced to at most one outstanding control send.

At the iPad, the new generation causes local silent rebuffer and restarts at the first record received, with the 64-packet target. Existing trimming discards excess *delivered* backlog back to target. This can create a short discontinuity; it is preferable to accumulating indefinite delay. The 160 ms target absorbs only disruptions shorter than its remaining fill, not every previously observed gap. A skip threshold is a transport-progress bound, not a guarantee on total capture-to-speaker latency.

## Diagnostics and failures

Log the negotiated mode, reliable stream open/close/generation, send failures, progress lag, skip decision with old/new generation and sequence, receive gaps, local rebuffer/trim/underflow, and timed-session boundaries. Keep per-packet and summary records off the audio render callback. In Stability mode, DATAGRAM send-state loss counters are inapplicable; do not relabel `StreamSend` completion as acknowledgment or loss. Preserve automatic iPad report upload and Windows log-file output. A stream creation or parsing failure fails the connection with a useful diagnostic instead of silently switching modes. On disconnect, cancel timers and stream callbacks so a stale connection cannot affect a newer one.

## Validation

Test both C++ and Swift control codecs, unknown-feature compatibility, fixed-record stream parsing across arbitrary read splits/joins, generation replacement, stale feedback, sequence wrap, threshold/restart policy, and DATAGRAM regression. Build and run relevant Windows tests locally, then the existing GitHub Actions Swift/unsigned-IPA jobs. Runtime success and audible improvement require iPad installation and same-network A/B listening; CI cannot establish those claims. Compare audible artifacts, conceal/trim/underflow, receive gaps, restart count, and measured acoustic latency separately. Do not claim a <=200 ms end-to-end latency without an external measurement.
