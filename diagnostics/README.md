# HearPort local diagnostics

HearPort diagnostics are local JSON Lines records. They are intended for the
operator who is debugging one Windows sender and one iPad receiver; there is no
diagnostics or telemetry QUIC stream in v1.

The event schemas are intentionally small and reject secrets. A sender or
receiver may record endpoint/source format, connection state, stream and
sequence counters, DATAGRAM capability, jitter/render fill, loss/late/duplicate
counts, underrun/overflow, resampler ratio, silent-rebuffer state, route and
interruption events, capture reset, and authentication state. It must not
record PINs, pair secrets, HMAC values, private keys, full certificates, or
raw PCM.

Each JSON line must contain `schema_version`, an RFC 3339 `timestamp`, a
component (`sender` or `receiver`), and an event name. Numeric counters are
monotonic for the lifetime of the local process unless a new stream explicitly
resets a stream-scoped field. Logs are best-effort and must never block the
WASAPI callback or the Audio Unit render callback.

Before sharing a log, remove hostnames, IP addresses, endpoint names, and any
operator-supplied diagnostic message that may identify a local network.

## Local music concealment experiments

With NumPy, SciPy, SoundFile and Matplotlib installed, run
`python diagnostics/music_plc.py --output out/music-plc/run --seconds 120` and
select a local audio file. `--start` selects the starting time in seconds;
`--audio` optionally supplies the file instead of opening the selector.
Outputs remain local. The output directory must be new.

This is a fixed 10 ms submission reference with an 11 ms output reserve,
separate from the production adaptive receiver. The current algorithm is an
instantaneous packetwise quality baseline. Other candidates include measured
worker dispatch, computation and queueing; `--quality-only` instead measures a
zero-compute-cost quality ceiling. Neither establishes iPad real-time readiness.
`--vendor` optionally selects a local directory containing the original official
PARCnet `model-32k.py` and `parcnet-32k.ckpt` files; PyTorch is required. The
third-party implementation, weights and music are not bundled here.
