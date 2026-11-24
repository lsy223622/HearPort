# HearPort Local Diagnostics

HearPort writes diagnostics strictly as **local JSON Lines (JSONL)** records for debugging one Windows sender and one iPad receiver — there is no diagnostics or telemetry QUIC stream in v1.

---

## Event Logging Contract

- **Schemas**: [`schemas/sender-events.json`](schemas/sender-events.json) and [`schemas/receiver-events.json`](schemas/receiver-events.json).
- **Required fields**: Every JSON line includes `schema_version`, an RFC 3339 `timestamp`, `component` (`sender` or `receiver`), and an event name. Numeric counters are monotonic for the process lifetime unless a new stream explicitly resets a stream-scoped field.
- **Real-time safety**: Logging is best-effort and must never block the WASAPI capture callback or the CoreAudio render callback.
- **Secret exclusion**: Events may record formats, connection state, stream/sequence counters, `DATAGRAM` capability, jitter/render fill, loss/late/duplicate counts, underrun/overflow, resampler ratio, silent-rebuffer state, route/interruption events, capture reset, and auth state — **never** PINs, pair secrets, HMACs, private keys, full certificates, or raw PCM.

> [!WARNING]
> **Strip network details before sharing:** Exported logs can contain local hostnames, IP addresses, audio endpoint names, and operator notes. Sanitize them before sharing publicly.

---

## Tools & Experiment Guides

| File | Purpose |
| --- | --- |
| [`offline-transport.md`](offline-transport.md) | Reproducible CI simulation comparing buffering, time-stretch, and Reliable replay strategies |
| [`usb-probe/README.md`](usb-probe/README.md) | Standalone USB transport feasibility probe (separate from HearPort) |
| [`analyze_automation.py`](analyze_automation.py) | Summarizes iPad App Shortcut & automation stages and timings from exported logs |
| [`analyze_compression_test.py`](analyze_compression_test.py) | Pairs and analyzes synthetic/music PCM vs. Opus compression benchmark runs |
| [`analyze_network_probe.py`](analyze_network_probe.py) | Analyzes network probe sender/receiver logs |
| [`music_plc.py`](music_plc.py) | Offline music packet-loss concealment (PLC) quality & compute-budget benchmark |

---

## Offline Music Concealment Experiments (`music_plc.py`)

With `numpy`, `scipy`, `soundfile`, and `matplotlib` installed, run a local experiment (the `--output` directory must not already exist):

```powershell
python diagnostics/music_plc.py --output out/music-plc/run --seconds 120
```

| Flag | Description |
| --- | --- |
| `--audio <path>` | Input audio file (opens a file picker if omitted; output stays local) |
| `--start <sec>` | Starting offset in seconds |
| `--seconds <dur>` | Excerpt duration to evaluate |
| `--quality-only` | Measures a zero-compute-cost quality ceiling instead of including dispatch/compute/queueing latency |
| `--vendor <dir>` | Optional directory containing official PARCnet `model-32k.py` and `parcnet-32k.ckpt` (requires PyTorch; weights and music are not bundled) |
| `--arrivals <npy>` | Replays a local NumPy array of arrival times in ms per 2.5 ms source packet (`inf` = lost) |
| `--algorithms`, `--seeds`, `--budgets` | Restricts expensive sweeps to selected cases |

> [!NOTE]
> `music_plc.py` evaluates a fixed **2.5 ms** packet-submission baseline with an **11 ms** output reserve, separate from the production adaptive receiver. Neither `--quality-only` nor desktop compute-cost runs establish iPad real-time readiness.
