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
- [x] Focused native verification, final review, docs, Actions builds and artifacts.

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

- Actions final verification: Windows 39386364549 (24 CTest + 28 Python), iPad
  39386215008 (186 Swift, unsigned IPA 165), CodeQL 39386214238: all passed.
- Both packages match 21b3848312e16aa652c55704991839502698feee; hashes and
  notices verified; downloaded Windows package started and endpoints checked.
- First Swift attempts rejected the new diagnostics fixture initializer; it was
  corrected to the actual public API before the passing full run.
- Physical acceptance remains the device checks in the validation matrix.

## Capture-silence follow-up

- User device evidence identified a permanently advanced playback cursor after
  capture stops; reconnecting clears the state. Raw logs remain local.
- Regression 966701d / Actions 39391950466: 20 fresh resumed packets rejected as
  late, resumed-output assertion failed; all other tests passed.
- Fix is limited to the coordinated pump: no source advancement without any
  buffered packet, allowing real ring content to drain into silent rebuffer.
- Fixed Actions 39392343378: 187/187 Swift tests passed, regression RED→GREEN, unsigned IPA archived; CodeQL 39392343011 passed. Desktop sender code is unchanged. Physical acceptance remains pending installation.
