# HearPort 0.1.0 release checklist

## Portable runtime loading fix (2026-10-22)

- [x] Reproduced the old package's `0xC0000135` startup failure in a fresh Windows Sandbox, with local VC runtime files present and no System32 VC runtime. Confirmed MsQuic's System32-only import flags and successful local-runtime preload control.
- [x] Source `5a1e5a2fe763ef2a52fafc2e5413649636a1e788`: Windows Actions [39788168226](https://github.com/lsy223622/HearPort/actions/runs/39788168226) and CodeQL [39788187759](https://github.com/lsy223622/HearPort/actions/runs/39788187759) passed. Verified published hashes, all 100 runtime files and actual application-local module paths. The downloaded Actions package also started and bound UDP 52137 in the same Sandbox without installing a runtime.
- [ ] iPad build 191 installation and automation device acceptance await the user's AltStore recovery; this Windows loader fix does not require an iPad update.

## Connection automation candidate (2026-10-22)

- [x] Matching application source `8ba6d9ab9e7335f72a5122b166d66d320f1e0493`: Windows Actions [39748549052](https://github.com/lsy223622/HearPort/actions/runs/39748549052) passed 25 CTest, 28 Python checks and packaged startup/paint checks; iPad Actions [39748549005](https://github.com/lsy223622/HearPort/actions/runs/39748549005) passed 221 Swift tests, four shortcut/analysis checks and archived unsigned build 191; CodeQL [39748548777](https://github.com/lsy223622/HearPort/actions/runs/39748548777) passed.
- [x] Verified archive hashes, all 100 Windows runtime files, matching embedded source/build identities and unsigned IPA packaging. Metadata contains ten distinct intent/shortcut entry points, three route choices, the audio-starting protocol and foreground flags. The Actions Windows executable was launched locally, responded and listened on UDP 52137.
- [x] One independent review identified delayed old-session stop handling; the active session ID/identity gate and path-promotion regression now cover it. Local combined Python checks: 32 passed.
- [x] Generated five URL shortcut sources and attempted signing on macOS CI. All five were refused because the runner was not signed into iCloud; no importable signed file is claimed. Built-in App Shortcuts do not require importing these files.
- [ ] Install iPad build 191 and check shortcut discovery, first manual invocation, background/locked/force-quit triggers, selected Wi-Fi and charger automation, delayed USB recognition and repeated invocation. Record actual audible playback separately from engine/received-render evidence. Procedure: [connection-automation.md](connection-automation.md).
- [ ] Check normal PC stop/restart recovery, manual-disconnect pause, credential refusal without deletion and re-pairing. Confirm route settings and existing recommendation actions still update normally after the shared-runtime migration.

## Pairing safety and interaction recovery candidate (2026-10-21)

- [x] Matching source `e59628ab0f34fd6a8f9a8293d5c5d20e4ed03078`: Windows Actions [39593250742](https://github.com/lsy223622/HearPort/actions/runs/39593250742) passed 24 CTest, 28 Python checks and packaged startup/paint checks; iPad Actions [39593250802](https://github.com/lsy223622/HearPort/actions/runs/39593250802) passed 216 Swift tests and archived unsigned build 184; CodeQL [39593251795](https://github.com/lsy223622/HearPort/actions/runs/39593251795) passed. Downloaded hashes, all 100 Windows files, matching embedded build identities and unsigned IPA packaging verified. The Actions Windows executable was launched locally, responded and listened on UDP 52137.
- [ ] Install iPad build 184 with the new Windows package. Check connected unpair in each direction, offline unpair followed by a stopped authentication attempt, retained credentials after ordinary transport interruption, and re-pairing.
- [ ] Check edited manual address, immediate Start after numeric editing, in-page PC selection with settings retained, and audio-output retry feedback.

## Independent route latency candidate (2026-10-21)

- [x] Menu summary follow-up: Actions [39586833423](https://github.com/lsy223622/HearPort/actions/runs/39586833423), 214 Swift tests, unsigned build 183 and CodeQL passed. IPA hash, source/build identity and unsigned packaging verified.
- [ ] Check encoding and independent target/maximum summaries on both route rows, including light and dark appearance.
- [x] Source `3370ee2c55083328c1d0d3c66ebc111a674e7af1`: iPad Actions [39583024058](https://github.com/lsy223622/HearPort/actions/runs/39583024058) passed 214 Swift tests and archived unsigned build 182. CodeQL [39583022167](https://github.com/lsy223622/HearPort/actions/runs/39583022167) passed. Downloaded IPA SHA-256, embedded source/build identity and unsigned packaging were verified.
- [ ] Install build 182; confirm the previous network delay values survive upgrade and USB starts at 50/100 ms. Set different budgets in each route page, insert/remove USB and check the active negotiated values. Applying a network recommendation must preserve USB settings.

## iPad row actions and launch layout candidate (2026-10-21)

- [x] iPad source `2bebb701a278d94fbbc6876b6397777021e18c50`: Actions [39544315416](https://github.com/lsy223622/HearPort/actions/runs/39544315416), 211 Swift tests, unsigned build 181 and CodeQL passed. IPA hash, source/build identity and unsigned packaging verified.
- [x] Recorded the user's several-hour locked-idle continuation/resumption observation, with unknown exact build/path/duration; it does not replace the finite continuous-playback soak.
- [x] User confirmed startup layout appears in place; supplied dark-mode screenshots confirm compact connection forms, settings/recommendation layout and No connection selected wording.
- [ ] Tap whitespace in the blue action rows; check numeric connected IP/port on LAN and light-mode appearance.

## Automatic-test startup candidate (2026-10-21)

- [x] Matching source `ea1683110ccd80181d6205716bc35b163c8e95c4`: Windows Actions [39478078837](https://github.com/lsy223622/HearPort/actions/runs/39478078837), iPad Actions [39478078798](https://github.com/lsy223622/HearPort/actions/runs/39478078798), 24 CTest, 28 Python, 209 Swift checks, unsigned IPA build 180 and CodeQL passed.
- [x] Archive hashes, matching source identities, 100 Windows file hashes and unsigned IPA packaging verified. Actions Windows package passed the local window check and was started.
- [x] Local Windows Release, 24 CTest, 28 Python checks and real-window regression checks passed.
- [ ] Install build 180; start a quick test from the home context menu with USB available and without USB. Check that stream readiness does not reject the request.
- [ ] Check ordinary music startup, retained-report recovery, compact pairing and its blue Connect action, one Windows pairing action, and changing total log size beyond the 2,000-entry preview.

## Connection actions and repaint candidate (2026-10-21)

- [x] Windows source `3e8543a8bcea881d7bfb066a5080c6f9932af8c0`: Actions [39473183485](https://github.com/lsy223622/HearPort/actions/runs/39473183485), 24 CTest, 28 Python checks and packaged GUI startup/clipping/order/unchanged-status checks passed.
- [x] Windows archive/source and 100 file hashes verified. Downloaded Actions package passed the local window check and listened on UDP 52137.
- [x] Final iPad source `9f45c551e44456996aaf242d425d32f28a11e1f2`: Actions [39473786709](https://github.com/lsy223622/HearPort/actions/runs/39473786709), 205 Swift tests, unsigned build 179 and CodeQL passed. IPA hash, source/build identity and unsigned packaging verified.
- [ ] Install build 179; check context-menu testing both with and without saved pairing, wrong-PIN cancellation, test completion/resumed playback, and no stale test on the next ordinary connection.
- [ ] Check both local unpair actions and subsequent pairing. Check foreground keep-awake, connection-action placement, blue USB readiness and green test progress.
- [ ] Observe Windows during an iPad-started test without switching tabs; inspect frames/icon, negotiated format on return to playback, system theme and DPI changes.

## iPad menu presentation candidate (2026-10-20)

- [x] iPad source `d8977fa9d6b3bb9946baa1f1724cac3b1cbc28ec`: Actions [39440168724](https://github.com/lsy223622/HearPort/actions/runs/39440168724), 204 Swift tests and unsigned build 177 archive passed. CodeQL passed.
- [x] IPA hash, source/build identity and unsigned packaging verified. Existing validated Windows package remains compatible.
- [ ] Install build 177; inspect label/value rows, timestamp, visible segment duration and ceiling, blue text actions and larger profile segments in light/dark mode.
- [ ] Check settings/details sheet width, dismissal, navigation, clear-log confirmation and network/USB stable colors on iPad.

## Transport comparison and settings candidate (2026-10-20)

- [x] Matching source `2571b1b29a160617d71a087b8c48018687269c3a`: Windows Actions [39425040006](https://github.com/lsy223622/HearPort/actions/runs/39425040006), iPad Actions [39425055397](https://github.com/lsy223622/HearPort/actions/runs/39425055397).
- [x] 24 CTest, 28 Python and 204 Swift checks passed; unsigned build 176 archived; CodeQL passed.
- [x] Packaged Windows GUI startup checked in Actions. Download hashes, all 100 Windows file hashes, unsigned IPA and matching identities verified. Final Actions Windows program started and listened on UDP 52137.
- [x] Ordinary/detailed retention policies and pruning tested; detailed recommendation measurements export locally. Actual ordinary Windows runtime files pruned to one active file and three backups, each at most 1 MiB.
- [ ] Install build 176; check independent route transport preferences, direct numeric delay editing, primary action visibility in light/dark mode and a fresh local recommendation with detailed logging enabled.
- [ ] Confirm normal playback and USB/network handover on the physical iPad. Network variation remains separate from automated algorithm regressions.

## USB recovery and runtime log candidate (2026-10-20)

- [x] Matching source `82bdaee35a7d32a72a6edfabc3abe56491e40bd8`: Windows Actions [39417771470](https://github.com/lsy223622/HearPort/actions/runs/39417771470), iPad Actions [39417768450](https://github.com/lsy223622/HearPort/actions/runs/39417768450).
- [x] 24 CTest, 28 Python and 197 Swift checks passed; unsigned build 173 archived; CodeQL passed.
- [x] Release hashes, 100 Windows packaged-file hashes and matching IPA identity verified; Actions Windows executable started and listened on UDP 52137.
- [x] That candidate validated approximately 128 MiB retention per endpoint; background streamed iPad export includes USB state.
- [ ] Install build 173 and observe USB priority after extended use, foreground return and cable reconnect. The original physical listener transition was not retained in build 170's export.

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
- [x] Windows log rotation, retry backoff and authenticated route switching inspected.
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
