# HearPort 0.1.0 release checklist

## Recorded evidence

- [x] Windows VS 2022 x64 Release build and 22/22 CTest checks passed, with test assertions enabled.
- [x] Python suite: 65 checks run, 3 optional checks skipped; release dependency-closure tests passed.
- [x] Windows log rotation bounded to 4 MiB plus three backups; retry backoff and authenticated route switching inspected.
- [x] Release DLL closure inspected: MsQuic and required VC runtime DLLs; no Debug CRT imports.
- [x] Third-party license collection and version alignment at 0.1.0 prepared.
- [x] GitHub Actions run [39042423876](https://github.com/lsy223622/HearPort/actions/runs/39042423876): 156 Swift package tests passed; unsigned iOS IPA archive was created and validated.
- [x] User-observed playback on iPad Pro 11-inch (2020) over USB, including disconnect/reconnect; repeated playback/tests on weak 2.4 GHz Wi-Fi.

## Before distributing

- [ ] Confirm the portable Release ZIP starts and plays on a clean Windows machine without development tools; build and package commands are in the root README.
- [ ] Install the unsigned IPA using the user's chosen signing tool; confirm first-run permissions, discovery/manual endpoint entry, LAN pairing, and remembered reconnect.
- [ ] On the iPad, confirm USB pairing, playback, cable loss/reconnect, and fallback to the remembered LAN endpoint with Apple Windows device support installed and the device trusted.
- [ ] Complete one finite 1–2 hour foreground playback run and check silence/recovery, app background/lock behavior, route interruption, and Windows audio-device reset.
- [ ] Review a diagnostics export for network details before sharing it.

Use the evidence boundary in [`validation-matrix.md`](validation-matrix.md) when recording results. A CI archive or short manual playback does not complete the installation or soak checks above.
