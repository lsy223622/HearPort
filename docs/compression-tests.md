# Audio Encoding Settings & Compression Benchmarks

## Daily Playback Encoding Settings

In iPad **Settings → Playback**, **Network audio** and **USB audio** store independent transport, codec, and delay profiles:

| Route | Default Transport | Default Codec & Frame Duration | Supported Options |
| --- | --- | --- | --- |
| **Network audio** | Datagram | Opus 256 kbps · 5 ms | PCM or Opus (`192` / `256` kbps at `2.5` / `5` / `10` ms) |
| **USB audio** | Reliable | Float32 PCM · 2.5 ms | PCM or Opus (`192` / `256` kbps at `2.5` / `5` / `10` ms) |

- Changes take effect on the **next connection**; connection details show the active negotiated parameters.
- Packet collection, Opus lookahead, encode/decode time, and output reserve all share your existing **total delay budget** — enabling compression does not add a separate buffer.
- Compression lowers application payload bandwidth, which does not guarantee gap-free playback under every wireless condition. Automatic tuning currently picks transport and delay budgets while preserving your chosen codec settings.
- The diagnostic suites below run their own fixed matrices independent of your daily playback settings (routing still prefers authenticated USB, so verify connection details show the LAN route when benchmarking Wi-Fi).

---

## Diagnostic Benchmark Entry Points

Make sure Windows and iPad run **matching versions** (older iPad builds prompt for an update). Launch either test from the Windows **Diagnostics** tab — iPad connects once, sweeps all profiles automatically, and uploads the report back to Windows:

1. **Network test → Compression traffic comparison (40 rounds)**  
   Sends paced random test payloads with **no audio encoder and no audio output**. Runs 10 payload profiles × Datagram / Reliable × 2 repeats, 30 s per round with 5 s gaps and a 10 s tail (~**23 min 25 s** total).
2. **Music compression test**  
   Selects a local audio file, start offset, and round duration (`60–300` s) for **live end-to-end encode/decode playback** across 8 formats × 2 transports × 2 repeats = **32 rounds** replaying the same excerpt:
   - Default `120` s/round: ~**66 min 45 s** (plus negotiation & report upload)
   - `60` s/round: ~**34 min 45 s**

> [!NOTE]
> Both suites use iPad's currently negotiated playout budget. The ceiling and round-duration controls under Network Settings apply to automatic tuning; synthetic compression traffic runs fixed 30 s rounds.

---

## Benchmark Matrix & Encoder Parameters

### Synthetic Load Matrix (40 Rounds)

Payload sizes below include the 32-byte timed header and exclude QUIC, TLS, UDP/IP, and ACK overhead (Reliable streams add a 2-byte length prefix per record):

| Traffic Profile | Bytes / Packet | Packets / Second | Factor Isolated |
| --- | ---: | ---: | --- |
| Float32 baseline | 992 | 400 | Baseline raw PCM payload |
| PCM16 baseline | 512 | 400 | Half payload size at identical packet rate |
| Opus 256 equivalent | 112 / 192 / 352 | 400 / 200 / 100 | Constant bitrate across `2.5` / `5` / `10` ms packetization |
| Opus 192 equivalent | 92 / 152 / 272 | 400 / 200 / 100 | Lower target bitrate across frame durations |
| Packet-rate control | 112 / 112 | 200 / 100 | Fixed packet size while lowering packet rate |

### Music Compression Live Codec Profile

Music benchmarks decode the chosen excerpt via Media Foundation and encode/decode in real time (not pre-encoded files):

- **Codec settings**: Official `libopus 1.6.1`, 48 kHz stereo, `restricted-low-delay`, `music` signal hint, complexity `5`, CBR, with DTX and in-band FEC disabled.
- **Format sweep**: Float32 PCM (`2.5` ms), PCM16 (`2.5` ms), and Opus `192` / `256` kbps at `2.5` / `5` / `10` ms each.
- **Timing & loss handling**: Frame accumulation, queried codec lookahead, compute, and queueing all count against the source-age budget. Out-of-order packets decode in sequence order; missing packets that arrive before their latest decode deadline still replace concealment; PLC advances decoder state on lost packets and does **not** count as original audio delivered.

---

## Analysis Rules & Local Reports

### Interpretation Boundaries

- **Order randomization & pairing**: Round order is seeded deterministically from the stream ID, reversed in repeat 2, and interleaved across transports to reduce drift bias. Keep iPad placement, foreground/background state, delay budgets, and PC load constant, and analyze USB vs. Wi-Fi runs separately.
- **Separate frame axes**: In music summaries, `missing_frames` (`missing_measurement_source=source_preparation`) counts **source frames** that failed to reach the output chain, whereas `playout_expired_output_frames` counts time-stretched **output frames** — never add these two metrics together as one percentage. Evaluate missing source duration, late rate, playout expiry, sender rejections, and codec timings together rather than packet delivery rate alone.
- **Two-repeat limits**: Compare every profile against the PCM baseline across **both** repeats. Opposing directions across repeats cannot establish a compression improvement, and even consistent direction across two repeats does not prove statistical significance or future network behavior.

### Local Output Files & Analysis Command

To keep long runs from rotating early evidence out of disk logs, music tests write dedicated per-round summaries:

- **Windows session directory**: `compression-summary.jsonl`, `sender-trace.jsonl`, `sender.log`
- **iPad report**: Contains the `compression_summary_json_v1` summary block
- **Bounded packet traces**: Detailed per-packet traces are sampled using the reported `sequence_stride` (sender) / `trace_sequence_stride` (iPad). Unsampled gaps are **not** packet loss; authoritative totals always come from per-round summaries.

Run the local analyzer (keep raw logs and reports local — never commit them to a public repository):

```powershell
python diagnostics/analyze_compression_test.py <session-dir>/compression-summary.jsonl <session-dir>/ipad-report.txt > out/compression-analysis.json
```

For synthetic compression traffic runs, pass that run's `sender.log` and `ipad-report.txt` instead.

> [!NOTE]
> Compilation and desktop loopback tests verify implementation correctness; only real-device iPad runs establish whether codec CPU cost fits inside your latency budget on hardware.
