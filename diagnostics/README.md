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
