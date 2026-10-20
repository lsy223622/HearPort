# HearPort 0.1.0 release checklist

## Adaptive client recommendation candidate (2026-10-20)

- [x] Matching source `4de8694f96a76537d518556dccff93f849acd149`: Windows Actions [39399070518](https://github.com/lsy223622/HearPort/actions/runs/39399070518), iPad Actions [39399056345](https://github.com/lsy223622/HearPort/actions/runs/39399056345).
- [x] 24 CTest, 28 Python and 194 Swift checks passed; unsigned IPA build 170 archived; CodeQL passed.
- [x] Package hashes, 100 Windows file hashes, matching build identities and unsigned IPA verified. Windows Actions package started and listened on UDP 52137.
- [ ] Install build 170; verify unplugged USB shows the confirmed network codec, latency controls reach round values, and quick testing shows live progress, finishes locally and applies all network parameters.
- [ ] Reconnect and check ordinary audio with the applied recommendation. Physical network variation and codec processing remain separate from the synthetic transport observation.

## Capture-silence recovery fix (2026-10-20)

- [x] Regression reproduced fresh resumed audio rejected as late on the existing stream.
- [x] Actions [39392343378](https://github.com/lsy223622/HearPort/actions/runs/39392343378): 187 Swift checks passed and unsigned IPA archived; CodeQL passed.
- [ ] Install this fixed IPA and check repeated track changes, pause/resume and cable handover. The current Actions Windows sender remains compatible.

## Configurable live compression candidate (2026-10-20)

- [x] Matching source `21b3848312e16aa652c55704991839502698feee`: Windows [39386364549](https://github.com/lsy223622/HearPort/actions/runs/39386364549), iPad [39386215008](https://github.com/lsy223622/HearPort/actions/runs/39386215008).
- [x] Windows Release with 24 CTest / 28 Python checks; iPad with 186 Swift checks, unsigned IPA build 165; CodeQL passed.
- [x] Download/file hashes, IPA identity and licenses verified; Windows Actions package started and listened.
- [ ] Check normal live playback, per-path encoding selection, silence/resume and USB/network handover with the capture-silence fix above.

## Compression test candidate (2026-10-20)

- [x] Matching source commit `53de0cd7eefa0afd9e63f549b50439c023172b51`: Windows Actions [39360465692](https://github.com/lsy223622/HearPort/actions/runs/39360465692), iPad Actions [39360464729](https://github.com/lsy223622/HearPort/actions/runs/39360464729).
- [x] Windows Release build, 23 CTest checks, 28 Python checks, 179 Swift checks, unsigned IPA build 162 and CodeQL passed.
- [x] Download checksums, Windows file hashes, matching IPA identity and bundled Opus license verified; extracted Windows package started and listened on UDP 52137.
- [x] Build 162 physical comparisons: 32 USB and 32 network music rounds completed; repeated wireless results and startup trimming analyzed separately.
- [ ] Verify the new normal-playback encoding settings, silence/resume and USB/network switching on device after installing matching builds.

## Baseline evidence (2026-10-18)

- [x] Windows Actions run [39052133439](https://github.com/lsy223622/HearPort/actions/runs/39052133439): Release build, 22/22 CTest checks and 6/6 package/document checks passed, with test assertions enabled.
- [x] Python suite: 65 checks run, 3 optional checks skipped; release dependency-closure tests passed.
- [x] Windows log rotation bounded to 4 MiB plus three backups; retry backoff and authenticated route switching inspected.
- [x] Release DLL closure inspected: MsQuic and required VC runtime DLLs; no Debug CRT imports.
- [x] Third-party license collection and version alignment at 0.1.0 prepared.
- [x] GitHub Actions run [39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647): 156 Swift package tests passed; unsigned iOS Release IPA build 158 was created with bundled license notices and validated.
- [x] User-observed playback on iPad Pro 11-inch (2020) over USB, including disconnect/reconnect; repeated playback/tests on weak 2.4 GHz Wi-Fi.

- [x] Both Actions artifacts use commit `35f00d8c5adfdb6e27d724daaff6677b0172abfb`; product version 0.1.0. Download checksums, Windows payload hashes and IPA build identity verified.
- [x] Started the Windows program from the downloaded ZIP on the development PC; MsQuic and all three VC runtime DLLs loaded from the extracted package. This does not complete clean-PC acceptance.

## Distribution artifacts

Generate both release packages in GitHub Actions at the same source commit:
`Windows Release package` → `HearPort-windows-release`, and
`iOS receiver package tests` → `HearPort-unsigned-ipa`.
Local build results are development verification, not the distribution source.

## Before distributing

- [ ] Confirm the portable Release ZIP starts and plays on a clean Windows machine without development tools; build and package commands are in the root README.
- [ ] Install the unsigned IPA using the user's chosen signing tool; confirm first-run permissions, discovery/manual endpoint entry, LAN pairing, and remembered reconnect.
- [ ] On the iPad, confirm USB pairing, playback, cable loss/reconnect, and fallback to the remembered LAN endpoint with Apple Windows device support installed and the device trusted.
- [ ] Complete one finite 1–2 hour foreground playback run and check silence/recovery, app background/lock behavior, route interruption, and Windows audio-device reset.
- [ ] Review a diagnostics export for network details before sharing it.

Use the evidence boundary in [`validation-matrix.md`](validation-matrix.md) when recording results. A CI archive or short manual playback does not complete the installation or soak checks above.
