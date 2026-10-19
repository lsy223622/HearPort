# Compression transport comparison

## Goal

Determine whether smaller payloads and lower packet rates improve delivery on the user's actual path, then verify real Opus music playback. Compare paired repetitions rather than attributing changing Wi-Fi conditions to a codec. Audio, personal paths and raw reports stay local.

## Experiments

The existing network diagnostic runs ten synthetic profiles: timed wire bytes/rate `(992,400)`, `(512,400)`, `(112,400)`, `(192,200)`, `(352,100)`, `(92,400)`, `(152,200)`, `(272,100)`, `(112,200)`, `(112,100)`. These represent Float32, PCM16, CBR Opus equivalents and constant-size frequency controls. Both transports, two counterbalanced repetitions, 30 seconds per round, five-second drains: 40 rounds. Automatic parameter recommendation retains its existing candidates.

The existing music diagnostic runs eight profiles: Float32/120 frames; PCM16/120; Opus 192 and 256 kbps, each at 120/240/480 frames. All use the same 48 kHz stereo excerpt and adaptive controller; both transports and two seeded counterbalanced repetitions produce 32 rounds. Duration remains selectable 60–300 seconds, default 120. UI states count, encoding and remaining time before/while running. Normal playback remains unchanged.

## Codec and wire

Pin official libopus 1.6.1 source by SHA256. Use restricted-low-delay, music, complexity 5, CBR, no DTX or FEC; measure lookahead via API. Keep the 32-byte timed header, add explicit Opus/PCM16 kinds, retain source-frame and logical 120-frame sequence coordinates. Music v4 manifest declares profile, repeat, frame duration, bitrate and measured lookahead. A negotiated capability rejects old peers before starting. Reliable music v4 uses existing length-prefixed probe framing; legacy audio framing stays unchanged.

Encode only after the simulated frame has been collected; never pre-encode the excerpt. Source timestamps account for codec lookahead, so framing, compute, transit and receiver buffering spend the existing total budget. Do not add an extra independent codec buffer. Decode Opus in sequence, bounded by the playout deadline; reorder late packets until the latest decode start, advance codec state for missing frames, reject stale generations, and distinguish concealed/missing audio from successful original delivery. Split decoded output into existing 120-frame internal PCM packets.

## Evidence

Record source frames, actual bytes, sender acceptance/rejections, capture-to-send timing, codec creation/first/warm encode/decode durations, missing source duration, late packets and receiver outcome. Compare matching profile/transport/repeat/budget/path; incomplete pairs are excluded and clearly reported. Two repetitions expose disagreement but do not establish statistical significance. Synthetic payload results do not count as real codec evidence, and desktop/macOS timing never counts as iPad timing validation.

## Delivery

Focused codec/protocol/order/deadline/analysis regression tests, then consolidated Windows and Swift tests in Actions and unsigned IPA/portable Windows artifacts. Licenses accompany both artifacts. Physical weak-signal testing remains a separate user run after installing matching builds.
