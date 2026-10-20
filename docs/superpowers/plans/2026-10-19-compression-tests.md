# Compression test implementation plan

**Goal:** Deliver reproducible synthetic and real-codec comparisons in the existing diagnostics.

**Architecture:** Reuse timed records, length-prefixed reliable probes, existing playout budget and local report transfer. Keep normal playback independent.

**Spec:** docs/superpowers/specs/2026-10-19-compression-tests-design.md

## Tasks

- [x] Pin/fetch Opus, add C bridge and codec tests, configure Windows/macOS/iPad linkage and notices; Windows build verified, Apple builds use the final Actions gate below.
- [x] Add seeded synthetic profiles with strict manifest validation and paired analysis tests.
- [x] Add music policy/manifest/wire tests, then implement real-time framed encoding and timing summaries.
- [x] Add ordered bounded decoding, deadline/cancellation/generation tests, receiver summaries and progress labels.
- [x] Review framing, source timestamps, report completeness, final-round drain and no-arrival behavior; run focused tests and consolidated Actions gates.
- [x] Update user instructions and verification evidence, deliver matching Actions artifacts without claiming physical validation.

## Review focus

Out-of-order Opus packets must never mutate decoder state in arrival order. Lost first/final packets need complete accounting. Late/expired original frames must not appear as successful delivery. Lookahead and packet collection must spend the same source-age budget as PCM. Changing transport/round must reject stale callbacks and preserve bounded memory. Summaries must distinguish sent/received/played/concealed and incomplete reports.

## Execution

Implementation and independent review used the main workspace. Batch validation; no live network conclusions until matching devices run the experiment.

## Local evidence

- VS 2022 x64 Release build and 23 CTest checks passed.
- 28 focused Python checks passed (17 analysis checks plus source fetch safety, notices, package and validation-document contracts).
- All six actual Opus profiles round-trip with the expected CBR packet lengths; this is desktop verification, not iPad timing acceptance.
- Independent review corrected early original-packet rejection, reliable length framing, diagnostic sampling across the full sequence range, durable round summaries, source/output unit separation and aborted-test status.
- Final commit `53de0cd7eefa0afd9e63f549b50439c023172b51`: Windows Actions 39360465692 passed 23 CTest and 28 Python checks; iPad Actions 39360464729 passed 179 Swift checks and archived unsigned IPA build 162; CodeQL 39360464054 passed.
- Both downloaded artifacts, runtime file hashes, IPA identity and Opus notices verified; the Actions Windows package started and listened on UDP 52137. No physical-device compression result is claimed.
