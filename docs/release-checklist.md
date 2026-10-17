# HearPort 0.1.0 release checklist

## Recorded evidence

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
