# Continuous Canvas Implementation Plan

**Goal:** Implement the approved continuous canvas iPad design with system light/dark appearance.

**Architecture:** Keep the existing connection coordinator and audio pipeline. A presentation stage resolves terminal/report/recovery precedence. A small observational quality tracker consumes receiver snapshots once per second; SwiftUI renders a persistent status symbol and animates the connection list and playback summary on the same canvas.

**Spec:** User-approved continuous canvas preview, 2026-10-17. Network arcs represent recent audio delivery quality, not Wi-Fi RSSI. USB uses a curved cable.

## Constraints

- Work in the main checkout; execute continuously without another design gate.
- Preserve pairing, USB preference, diagnostic pinning, transport, latency and playback behavior.
- Use semantic system colors, reduced-motion support, accessible text and controls.
- Do not claim measured end-to-end latency; show target and ceiling as configuration.
- Keep personal data out of tracked artifacts. Use GitHub Actions for Swift tests and iOS archive.

## Tasks

1. Add focused regression tests for presentation precedence, recovery, quality warmup, degradation, delayed recovery, stale data and stream reset. Run these against the missing feature in CI, then implement the pure presentation/quality model and receiver snapshot.
2. Replace the home/status layout with a persistent canvas and animated symbol. Keep current PC visible through route recovery; show reporting until PC acknowledgement and explicit completed state. Consolidate matching remembered/discovered targets without guessing PC identities.
3. Separate playback preferences, connection details, diagnostics and About. Localize new copy. Follow system appearance and reduced motion, allow large text and narrow layouts.
4. Run focused/full Swift tests and iOS archive in Actions, review the complete diff, fix material findings, download the unsigned IPA and verify metadata.

## Review focus

- Report completion must outrank stale reporting/test state.
- Recovery must preserve the active computer without showing the idle connection list.
- Silent/no fresh samples must never appear as a stable link.
- Stream/counter resets must not create negative rates or retain old quality.
- Opening settings must not stop playback; manual disconnection and test completion must retain their existing stop intent.

## Progress

- Approved design and main-checkout execution confirmed by user.
- Local Windows environment has no Swift toolchain; use the established macOS Actions workflow for behavioral tests and iOS compilation. Layout changes receive build/review validation; unit tests cover derived state and quality behavior.
