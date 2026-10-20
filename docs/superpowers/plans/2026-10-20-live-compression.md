# Configurable live audio compression

The user approved extending the tested codec path into normal playback, with
network defaulting to Opus and USB defaulting to PCM. Work stays in the main checkout.

## Design

- Per-path preferences: network Opus 256 kb/s / 5 ms, USB Float32 PCM. Each can
  explicitly select PCM or Opus; Opus supports 192/256 kb/s and 2.5/5/10 ms.
- Negotiate the format in AudioSetup before acknowledging stream start. A new
  capability identifies the extended fields. Diagnostics keep their own matrix.
- Keep 120-frame logical sequence units and existing deadline/output budget.
  Opus collects 1/2/4 units, includes codec lookahead in capture timestamps, and
  uses the existing bounded variable record transport for both delivery modes.
- Decode to the existing PCM playback pipeline. Reorder only within the existing
  deadline, bound pending state, and do not advance indefinitely during silence.
- Fix synthetic test transitions to drain before replacing streams, flush the
  final playback accumulation, and let delayed decoded startup use its remaining
  preparation window instead of requiring another full startup buffer.
- Changes apply on the next connection. Show negotiated encoding in details.

## Execution

- [x] Protocol, settings model, live encoder and meaningful regression tests.
- [x] Sender negotiation/capture/send and receiver decode/transport integration.
- [x] Playback settings, diagnostics, deadline-aware startup and test finalization.
- [ ] Focused native verification, final review, docs, Actions builds and artifacts.

Validation covers malformed negotiation, codec/frame combinations, sequence and
lookahead accounting, loss/reordering, silence/resume, bounded pending state,
per-path persistence, deadline startup, and final diagnostic accounting. iOS
compilation/tests and release packages run in GitHub Actions. Physical listening
and USB/Wi-Fi switching remain device checks, not inferred from compilation.

## Verification ledger

- Native protocol test observed RED (format fields lost), then GREEN.
- Native encoder tests cover all three frame sizes, native Opus decode, logical
  sequence alignment, lookahead, dropped units and a silence timestamp jump.
- Final local Release build and 24 CTest checks passed; 17 report analyzer and
  4 release-package Python checks passed.
- Swift/iOS compile and runtime checks require the Actions runners.
- Final review performed inline to honor the user's request to avoid costly agents.
