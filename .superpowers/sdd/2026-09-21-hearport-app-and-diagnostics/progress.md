# SDD ledger — plan: docs/superpowers/plans/2026-09-21-hearport-app-and-diagnostics.md

Baseline: c2a0508

Ruling: The bundled `sdd-workspace` helper could not initialize under the Windows/MSYS2 shell because its `/c/...` path conversion could not create directories; use this plan-scoped ledger manually in the workspace and keep the same task/commit/test contract.

Pre-flight: Task 1 produces `HearPortDiagnostics` and the diagnostic enums consumed by Task 2 instrumentation and Task 3 UI. Task 2 consumes the logger dependency and safe message names from Task 1. Task 3 produces the `HearPort` app target and `project.yml` consumed by Task 4's XcodeGen/archive job. Task 4 produces the unsigned artifact and run evidence consumed by Task 5's validation ledger. No unresolved interface conflicts found.

Task 1: Ruling: local Swift RED cannot run because `swift` is absent from the Windows PATH; use the existing macOS GitHub Actions package-test job to witness the test-only compile failure before implementing the diagnostics core. Cost if wrong: CI round-trip instead of a local compiler check.

Task 1 complete: test-first commits `34036fb` (RED test) and `4bacb19` (diagnostics core). GitHub Actions run `35594184406` passed on macOS 14: all 15 Swift package tests passed, including 3 diagnostics tests covering redaction, bounded rotation/tail retention, and clear/export state.

Task 2 complete: test-first commit `e28e774` produced the expected RED run `35594628645`; implementation commit `4493bda` plus regression fix `00f7d34` produced GREEN run `35595328996`. All 17 Swift package tests passed, including receiver audio/lifecycle metadata and stable control-message diagnostic-name coverage. Safe metadata excludes PCM contents and retains byte counts.

Task 3 complete: commit `ab23d34` added the SwiftUI diagnostics controls and XcodeGen-described iOS app target; commit `ecbfdc2` resolved the module/type name collision in the app entrypoint. The app target is source-controlled without generated Xcode project output.

Task 4 complete: commits `23c4e6b`, `6105707`, `75b198d`, and `317b6cf` added the macOS package/archive workflow and fixed Xcode 15 project format, iOS audio API compatibility, app-root name resolution, and explicit bundle identifier metadata. Follow-up commit `2f41def` added standard app executable/package metadata and CI assertions. GitHub Actions run `35613821462` passed both jobs and uploaded artifact `HearPort-unsigned-ipa` (ID `10644639467`, 144004 bytes).

Task 5 complete: final GitHub Actions run `35613821462` passed all 18 Swift package tests and the unsigned archive/IPA validation, including `CFBundleExecutable=HearPort` and `CFBundlePackageType=APPL`. Local Python reference suite passed 36/36; Rust `cargo fmt -- --check` and provider tests passed 3/3; native VS 2022 CMake/Ninja build and CTest passed 7/7. Validation matrix and the v1 progress record now include the final CI/artifact evidence and explicit remaining device/runtime boundaries.

Final review: self-review (no subagent tool available). `git diff --check` passed; no generated Xcode project or derived data is tracked; no raw PCM, PIN, credential, SPAKE, MAC, or token values are written by the diagnostics paths; the audio render rebuffer path performs no synchronous diagnostics file I/O.
