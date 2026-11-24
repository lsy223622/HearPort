# Reproducible Offline Transport Simulation

This CI suite replays synthetic network impairments and feedback loops to evaluate playout buffering, dynamic time-stretch, and Reliable replay policies reproducibly.

## Running & Experiment Phases

Trigger the **Offline transport simulation** workflow manually in GitHub Actions, choose a `phase`, and download the `HearPort-offline-transport` artifact. Runs use **30-second** synthetic source timelines without audio files (`endurance` uses **120 seconds**):

| `phase` | Comparison Scope | Seeds | Runs |
| --- | --- | --- | ---: |
| `decomposition` | Baseline policies plus single/combined controller, buffer, and replay ablations | `1–8` | 2400 + 768 |
| `components` | Isolate buffer target, arrival history, time-stretch state, or clock anchor | `1–8` | 336 |
| `sensitivity` | `25` / `50` ms feedback period; `0` / `10` / `25` ms new-stream startup delay | `9–16` | 1440 |
| `timing` | Recovery lead `0` / `15` / `30` / `45` ms with fixed replay freshness budget | `17–24` | 1440 |
| `capacity` | Unbounded or `3.5` / `6` Mbps serialized send capacity (`25` ms feedback, `10` ms startup delay) | `25–32` | 2160 |
| `replay` | No replay, predicted-expiry filtering only, and capacity-capped batches, plus single-loss isolation | `25–32` (isolation: `1`) | 1800 + 15 |
| `projection` | Consumption-rate estimation across two playout feedbacks with ±25% capacity estimation error | `33–40` | 2160 |
| `endurance` | 120-second runs using 75% conservative capacity estimate with ±25% error | `41–44` | 600 |

- Every phase outputs per-run JSON; `decomposition` ablations, `components`, `sensitivity`, `capacity`, and `replay` also emit `.paired.csv` paired by scenario, transport, delay budget, feedback period, startup delay, lead time, send capacity, and seed.
- Baseline runs additionally write `summary.md`, `paired.csv`, and the C++ snapshot audit `recovery.json`.

---

## Baseline Experimental Design

- **Synthetic network traces**: Fixed seeds `1–8` generate 5 network profiles (healthy, jitter, independent loss, weak Wi-Fi stalls + loss, and long outage) over 30 s at 400 packets/s and 120 frames/packet (identical input fingerprints per scenario/seed).
- **Sweep matrix (2,400 baseline runs)**:
  - **4 transport models**: Datagram (independent delivery) and Reliable (assumes single successful retransmission with ordered delivery) across 3 recovery modes: none, legacy feedback loop, and current feedback loop.
  - **3 delay budgets**: target/maximum of `50/100`, `80/160`, and `120/240 ms` with a fixed `11 ms` output reserve.
  - **5 playout policies**: fixed buffer, adaptive buffer, dynamic time-stretch only (±5%), combined buffer + stretch, and a 5th policy adding a deceleration guard (linearly tapers negative rate correction under 15 ms remaining preparation margin and blocks deceleration below 5 ms).
- **Driver implementation**: The Swift harness compiles the production `PlayoutController`, `ProbeConsumer`, and protocol modules; ablations, extra instrumentation, and the deceleration guard are injected only into temporary build copies without altering production code. Every run checks source-frame conservation and deadlines; healthy runs also assert zero missing source frames and zero restarts.
- **Pairing & intervals**: Policy differences are paired per seed before aggregation; bootstrap intervals over the 8 synthetic seeds capture variation within this model, not real-world wireless confidence intervals.

---

## Metrics, Closed-Loop Model & Limitations

### Metric Definitions

- **Source unavailable ratio**: Counts concealed, skipped, and unconsumed source frames (measured against the true source cursor rather than a potentially lagging feedback cursor). Concealed frames are broken down into not delivered by network, expired after queueing, dropped on generation restart without recovery, and expired before queueing. Packets arriving after consumption are tracked separately and **never added** to source-frame metrics.
- **Output gap ratio**: Counts rebuffer waits after initial start, scaled by active rate correction (source skips remain separate). Tracking ends at all source deadlines, excludes initial pre-buffering, and quantizes continuous gaps at **5 ms** resolution. Runs that never start playback report null gap ratio and playout age (never zero gaps) and `100%` source unavailable ratio.
- **Replay & single-loss isolation**: Tracks effective queued replays and peak send-queue wait. Single-loss isolation drops only packet `#400` with a fixed 120 ms retransmission delay and lossless replay, recording feedback, queue, and consumer state for the first 20 recoveries.

### Reliable Closed-Loop & Replay Modeling

- **Feedback & recovery triggers**: Calls the production C++ `ReliableAudioLag` over C FFI. Baseline polls feedback every 50 ms (the 25 ms variant matches production coordinated audio). The return path models 20–40 ms base latency, matching forward stalls, and ordered control delivery. Restarts cancel undelivered older generations; selected fresh replays re-traverse network jitter, loss, stalls, and head-of-line blocking (random draws depend deterministically on seed, sequence, and attempt count).
- **Serialization capacity & replay projection**:
  - Startup-delay experiments defer all sends on a new generation; capacity experiments charge 992 bytes of serialization service time for both primary and replay packets (cancelling an older stream retains at most one in-progress record cost; automatic transport retransmission service time is not modeled separately).
  - Replay-budget experiments assume a 12 ms one-way delivery reserve: candidates already expired at expected arrival are dropped first, and capacity-limited variants retain newer candidates within remaining model capacity (`production` calls the real replay filter directly). Consumption-rate projection extrapolates within the ±5% stretch range across consecutive valid cursors (disabled when discontinuities break cursor continuity, and always paired against no-projection runs).
- **Snapshot audit (`recovery.json`)**: Evaluates `ReliableAudioLag` over a grid of source lag and feedback age to compare direct sequence diffs against time-compensated recovery alignment (restart counts in closed-loop runs remain model outputs, not physical predictions).

### Model Limitations

- Does **not** simulate the music audio ring buffer, WOLA time-stretch, hardware audio output, callback CPU contention, MsQuic congestion control / ACK / PTO, real Wi-Fi air-time contention, failed restarts, or driver/router queues.
- Cancellation is modeled as instantaneous, and capacity parameters represent serialization pacing rather than physical Wi-Fi PHY rates.

> [!WARNING]
> Use these simulations to isolate deterministic controller behavior and test assumptions — never to declare one transport universally superior over real Wi-Fi. Final acoustic quality and real-network gains always require physical device testing.
