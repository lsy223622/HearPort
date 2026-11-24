# HearPort 0.1.0 Validation Matrix

> [!NOTE]
> **Evidence boundary:** Automated tests and CI builds do not prove physical-device playback, background behavior, or long-session reliability. User-observed runs are recorded separately from repeatable test evidence, and signed-install or soak acceptance is never inferred from an unsigned archive or short spot check.

---

## Requirement Matrix

| ID | Requirement | Evidence type | Evidence | Status |
|---|---|---|---|---|
| protocol-control | Control framing and canonical ControlEnvelope field layout | automated | `python -m unittest tests.reference.test_wire_codec tests.reference.test_control_messages -v` | passed |
| protocol-audio | 968-byte AUDIO payload, big-endian header, non-zero stream id | automated | `python -m unittest tests.reference.test_wire_codec -v` | passed |
| session-gating | Pending stream, matching ACK, old stream and reset behavior | automated | `python -m unittest tests.reference.test_session_state -v` | passed |
| windows-capture | Shared-mode WASAPI Loopback and endpoint reset | native-build | Windows Release Actions [39052133439](https://github.com/lsy223622/HearPort/actions/runs/39052133439) passed all 22 CTest checks; ordinary playback was observed on the user's iPad; endpoint-reset runtime remains unverified | 22 Release CI tests passed; endpoint-reset check pending |
| windows-quic | MsQuic TLS/ALPN/DATAGRAM transport and 968-byte send capability | native-build | VS 2022 x64 MsQuic build/startup smoke initialized the configured certificate and bound UDP 52137; Windows Release Actions [39052133439](https://github.com/lsy223622/HearPort/actions/runs/39052133439) passed all 22 CTest checks; the extracted Actions package started with app-local runtime DLLs; USB playback/reconnect was user-observed; LAN playback and complete diagnostics were also observed in repeated weak-Wi-Fi sessions | build/startup, local tests and user-observed LAN/USB sessions passed; clean Release install pending |
| ios-quic | Network.framework QUIC client, one control stream and one DATAGRAM flow | automated | GitHub Actions [run 39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647) on macOS 14: all 156 Swift package tests passed; iPad-device and live Windows/LAN interoperability remain separate | Swift package tests passed; LAN/USB sessions user-observed; final package acceptance pending |
| ios-audio | AVAudioSession stereo playback, local silence and render callback | native-build | GitHub Actions [run 39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647) archived the iOS app unsigned; Swift package tests passed; USB playback and cable reconnect were user-observed on an iPad Pro 11-inch (2020) | unsigned archive and short playback observed; route, interruption, and soak checks pending |
| ios-app-archive | HearPort app target and standard unsigned IPA packaging | native-build | GitHub Actions [run 39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647) generated the Xcode project, archived the app with signing disabled, validated app metadata, and uploaded unsigned Release IPA build 158 with license resources | CI artifact created; user signing and install from release bundle pending |
| security-pairing | PIN scalar, SPKI identity, SPAKE2 point/key/confirmation and failure handling | automated | Python vectors, Rust provider tests, and native `hearport_security_tests` under VS 2022; included in the 22-test Windows Release Actions run | automated checks passed |
| security-remembered | One-shot nonce, HMAC, peer-id and SPKI pinning | automated | Python vectors and native `hearport_security_tests` under VS 2022; included in the 22-test Windows Release Actions run | automated checks passed |
| diagnostics | Local sender/receiver event schema and export behavior | automated | JSON Schemas under `diagnostics/schemas/`, bounded asynchronous diagnostics, receiver and render metrics, and tests for export, redaction, rotation, and clearing | automated checks passed; review an exported report before sharing because it may contain network details such as a hostname, IP address, or port |
| network-impairment | Jitter, reorder, burst loss and outage recovery | real-device | Repeated weak 2.4 GHz Wi-Fi playback/tests were user-observed; paired offline replay and real-session reports exist; these are not a controlled validation of every impairment scenario | real Wi-Fi and paired offline evidence recorded; final Release soak pending |
| clock-drift | Bounded slow correction for +/- ppm producer/consumer mismatch | automated | `python -m unittest tests.reference.test_realtime_core -v` | passed for reference |
| foreground-soak | Two-hour foreground active-playback stability | real-device | Short playback and USB reconnect were user-observed on iPad Pro 11-inch (2020); no timed two-hour result is recorded | observed playback; two-hour soak pending |
| silent-playback | Windows capture idle, local zero output, then rebuffer and resume | real-device | Requires a foreground run that observes capture idle, silence, and recovery on a signed or otherwise launchable iPad | pending device run |
| background-lock-screen | Audio session behavior after lock/background transition | real-device | No signed-release lock-screen or background result is recorded | pending device run |
| route-interruption | Route change and audio interruption return to live rebuffer | real-device | No measured headphones/Bluetooth route-change or interruption result is recorded | pending device run |
| capture-reset | WASAPI endpoint reset starts a new stream without replaying stale audio | real-device | No connected-iPad endpoint-reset result is recorded | pending device run |

---

## User-Observed Manual Runs

- **iPad Pro 11-inch (2020) over USB & weak Wi-Fi**: User observed live playback over USB (including cable unplug/replug recovery) and repeated playback/diagnostic tests over weak 2.4 GHz Wi-Fi. Does not replace a timed 2-hour soak, all-route lock-screen check, clean-machine install, or final Release acceptance.
- **Locked-idle continuation (2026-10-21)**: Installed app remained idle on a locked iPad for several hours and later played Windows audio without waking the screen (exact build, route, and duration unrecorded; not a continuous-music soak).

---

## WinUI 3 desktop and variable PCM (2026-11-16)

- Merged source `4b0ec90fd6e46092f525d04a9b2793d27f89c558` introduces the WinUI 3 main window and tray flyout.
- **CI & local tests**: Windows [Release CI](https://github.com/lsy223622/HearPort/actions/runs/43739678400) passed portable packaging and GUI smoke checks (navigation, capture-source selection, flyout open/dismiss); local Release run passed 26/26 CTest. Matching [iOS CI](https://github.com/lsy223622/HearPort/actions/runs/43739678393) passed receiver package tests (including variable PCM and mixed fixed/variable reliable stream framing) and archived the unsigned IPA.
- **Development observations**: User confirmed Windows controlled iPad system volume during playback and while locked, and checked light mode and Windows display scaling.

## Background playback recovery and system media controls (2026-11-07)

- Source `39ce86132fbe4b439d47fe3882d3f4c35a1bce61` adds a non-renewing background recovery window capped at **20 seconds** on eligible playback disconnects (ends on recovery, manual stop, auth rejection, diagnostics/calibration, or OS expiry), interruption recovery via `shouldResume`, media-service reset rebuild, and Now Playing play/pause/stop controls (disabled during diagnostics).
- Delivery commit `161fa3f12a55ef5b221f0ccf4332bfcb68f5764a` migrates iOS jobs from retired `macos-14` to `macos-15`.
- **CI**: iOS Actions [42263118206](https://github.com/lsy223622/HearPort/actions/runs/42263118206) passed 227 Swift/QUIC tests and archived unsigned build **196** (Xcode 16.4; `UIBackgroundModes = audio`; no signature/profile; SHA-256 `55f2b856acc7f3151d96f851dc96fce52051c4e37d5dcf4ced8508df397b9a45`); 4 local shortcut/analysis checks and CodeQL [42263117529](https://github.com/lsy223622/HearPort/actions/runs/42263117529) passed.
- **Pending device checks**: Locked playback across brief outages, manual stop during recovery, lock-screen/Control Center/headset play & stop, interruption resume, and post-media-reset playback.

## Connection modes and shortcut acceptance (2026-11-05)

- Source `3526f3246e23d8b622dfd0eb968586cd85ef2772` shares persisted `Automatic` / `Network only` / `USB only` routing across playback settings, manual/recovery connects, and connection shortcuts (route change while active restarts connection; calibration stays LAN-only without overwriting playback mode).
- **CI**: iOS Actions [42002798864](https://github.com/lsy223622/HearPort/actions/runs/42002798864) passed 222 Swift/QUIC tests and archived unsigned build **194** (7 intents/shortcuts, 3 routes, IPA SHA-256 `9fde16f93a7f8724df14b3a63b72c30ea5e0a6ed8656400bffeecf67711dcd20`); Windows Actions [42002798733](https://github.com/lsy223622/HearPort/actions/runs/42002798733) & CodeQL [42002798328](https://github.com/lsy223622/HearPort/actions/runs/42002798328) passed; 7 local shortcut/analyzer/doc checks passed.
- **Device observations**: Audio playback intents connected without presenting the UI (even with no app-switcher card), foreground intent opened the app, Network-only stayed on LAN on USB plug-in, and USB-only waited on unplug. Full acceptance guide: [connection-automation.md](connection-automation.md).

---

<details>
<summary><strong>Historical verification logs (2026-10-18 – 2026-11-05)</strong></summary>

### Live home-canvas observation (2026-11-05)

- Build 192 device logs recorded `ui_disconnected` at `08:21:09 UTC` while audio played until foreground transitions refreshed the UI. Source `32333ff12d82341af539567689e666926c4c4002` gives deferred `GeometryReader` content its own view observing `ReceiverRuntime` and `ReceiverConnectionCoordinator`.
- iOS Actions [41995708805](https://github.com/lsy223622/HearPort/actions/runs/41995708805) (221 Swift tests, unsigned build **193**, SHA-256 `42676125f6b531b646eaee06421ae0bc5f46f9d2adc0d88d93bcb292d1b9b69b`) & CodeQL [41995707864](https://github.com/lsy223622/HearPort/actions/runs/41995707864) passed. Pending device check: live foreground connect/disconnect/LAN-USB transitions without app-switching.

### Rust cryptographic dependency security update (2026-10-26)

- Source `d8d6e78f22cf3b950056e03d70a683256eaa3b47` updates `crypto-bigint` `0.7.5` → `0.7.9` and `ctutils` `0.4.2` → `0.4.5` in the 47-package `Cargo.lock` (MSRV Rust 1.87). See [security-implementation.md](security-implementation.md#dependency-security-and-reproducible-builds) for reachability details and limits.
- `cargo audit` 0.22.2 (`21d909e4c8bd4e14c7aea58bf980c881a0053ab1`): old lockfile reported RUSTSEC-2026-0385 and RUSTSEC-2026-0387 (exit 1); updated lockfile reported zero vulnerabilities (exit 0).
- `cargo +1.87.0 test --locked` passed all 3 provider tests (including RFC 9382 vector); 5/5 Python security vectors, 26/26 CTest, and 8 old/new Windows DLL FFI interop cases passed.
- Windows Actions [40250312957](https://github.com/lsy223622/HearPort/actions/runs/40250312957), iOS Actions [40250312902](https://github.com/lsy223622/HearPort/actions/runs/40250312902) (221 Swift tests, IPA build **192**), and CodeQL [40250312835](https://github.com/lsy223622/HearPort/actions/runs/40250312835) passed. No machine-code constant-time proof is claimed.

### Chinese UI font selection (2026-10-25)

- Sandbox GDI font-link entries for Segoe UI were missing; Simplified Chinese UI now selects Microsoft YaHei UI directly (English keeps Segoe UI).
- Source `caf35c4fd39efdf994e4e198a4688d18b983e8ec`: Windows Actions [40196291192](https://github.com/lsy223622/HearPort/actions/runs/40196291192) (26 CTest including non-skipped Chinese glyph test, 29 Python checks, app-local DLL & GUI paint checks) & CodeQL [40196290928](https://github.com/lsy223622/HearPort/actions/runs/40196290928) passed; verified in the user's Sandbox.

### Portable runtime loading regression (2026-10-22)

- Pinned `msquic.dll` sets `DependentLoadFlags=0x0800` (System32-only imports), causing `0xC0000135` without a System32 CRT; sender executables now `/DELAYLOAD:msquic.dll` after loading the app-local CRT.
- Source `5a1e5a2fe763ef2a52fafc2e5413649636a1e788`: Windows Actions [39788168226](https://github.com/lsy223622/HearPort/actions/runs/39788168226) (25 CTest, 29 Python, DLL path & GUI checks) & CodeQL [39788187759](https://github.com/lsy223622/HearPort/actions/runs/39788187759) passed; repeated no-system-CRT Sandbox startup & UDP `52137` check passed.

### Connection automation verification (2026-10-22)

- Source `8ba6d9ab9e7335f72a5122b166d66d320f1e0493`: Windows Actions [39748549052](https://github.com/lsy223622/HearPort/actions/runs/39748549052) (25 CTest, 28 Python, GUI), iPad Actions [39748549005](https://github.com/lsy223622/HearPort/actions/runs/39748549005) (221 Swift, 4 Python shortcut checks, unsigned build **191** with 10 intent/shortcut entry points; audio entries require iPadOS 17.2), & CodeQL [39748548777](https://github.com/lsy223622/HearPort/actions/runs/39748548777) passed.
- 5 generated URL shortcut sources failed macOS CI signing for missing iCloud login; built-in App Shortcuts do not need file import ([connection-automation.md](connection-automation.md)).

### Pairing safety & interaction recovery (2026-10-21)

- Source `e59628ab0f34fd6a8f9a8293d5c5d20e4ed03078`: Windows [39593250742](https://github.com/lsy223622/HearPort/actions/runs/39593250742) (24 CTest, 28 Python, GUI), iPad [39593250802](https://github.com/lsy223622/HearPort/actions/runs/39593250802) (216 Swift, build **184**), CodeQL [39593251795](https://github.com/lsy223622/HearPort/actions/runs/39593251795) passed. Added explicit auth rejection pause without credential deletion, authenticated `SessionEnd` reason 3 unpair notice, and 500 ms close grace.

### Independent network & USB latency settings (2026-10-21)

- Menu summary `1e15f44e2d502afb27a9374a24ba5fc29c41bbb2` ([39586833423](https://github.com/lsy223622/HearPort/actions/runs/39586833423), 214 Swift, build **183**) and route budgets `3370ee2c55083328c1d0d3c66ebc111a674e7af1` ([39583024058](https://github.com/lsy223622/HearPort/actions/runs/39583024058), 214 Swift, build **182**) & CodeQL passed. Preserves upgraded shared budgets on Network audio; USB starts at 50/100 ms; recommendations update Network only.

### iPad row actions, launch layout & connection address (2026-10-21)

- Source `2bebb701a278d94fbbc6876b6397777021e18c50`: iPad [39544315416](https://github.com/lsy223622/HearPort/actions/runs/39544315416) (211 Swift, build **181**) & CodeQL passed; 5 user-supplied dark-mode screenshots confirmed startup form/layout without clipping.

### Automatic-test startup & diagnostic size display (2026-10-21)

- Source `ea1683110ccd80181d6205716bc35b163c8e95c4`: Windows [39478078837](https://github.com/lsy223622/HearPort/actions/runs/39478078837) (24 CTest, 28 Python, GUI) & iPad [39478078798](https://github.com/lsy223622/HearPort/actions/runs/39478078798) (209 Swift, build **180**) & CodeQL passed. Clarified 2,000-entry preview vs ~4/128 MiB disk logs and gated readiness on both `ReceiverReady` and `StartStreamAck`.

### Connection actions & Windows painting (2026-10-21)

- Windows `3e8543a8bcea881d7bfb066a5080c6f9932af8c0` ([39473183485](https://github.com/lsy223622/HearPort/actions/runs/39473183485)), iPad `9f45c551e44456996aaf242d425d32f28a11e1f2` ([39473786709](https://github.com/lsy223622/HearPort/actions/runs/39473786709), 205 Swift, build **179**), & CodeQL passed. Fixed child clipping/paint order and added context-menu test/unpair actions.

### iPad menu presentation (2026-10-20)

- Source `d8977fa9d6b3bb9946baa1f1724cac3b1cbc28ec`: Actions [39440168724](https://github.com/lsy223622/HearPort/actions/runs/39440168724) (204 Swift, build **177**) & CodeQL passed.

### Transport comparison & route settings (2026-10-20)

- Source `2571b1b29a160617d71a087b8c48018687269c3a`: Windows [39425040006](https://github.com/lsy223622/HearPort/actions/runs/39425040006) (24 CTest, 28 Python, GUI smoke), iPad [39425055397](https://github.com/lsy223622/HearPort/actions/runs/39425055397) (204 Swift, build **176**), regression [39422781309](https://github.com/lsy223622/HearPort/actions/runs/39422781309), & CodeQL passed. Added ABBA transport comparisons with repeat-variation tolerances and ~4/128 MiB log retention.

### USB recovery & extended diagnostics (2026-10-20)

- Source `82bdaee35a7d32a72a6edfabc3abe56491e40bd8`: Windows [39417771470](https://github.com/lsy223622/HearPort/actions/runs/39417771470), iPad [39417768450](https://github.com/lsy223622/HearPort/actions/runs/39417768450) (197 Swift, build **173**), & CodeQL passed.

### Adaptive client recommendations (2026-10-20)

- Source `4de8694f96a76537d518556dccff93f849acd149`: Windows [39399070518](https://github.com/lsy223622/HearPort/actions/runs/39399070518), iPad [39399056345](https://github.com/lsy223622/HearPort/actions/runs/39399056345) (194 Swift, build **170**), & CodeQL passed.

### Live compression & capture-silence recovery (2026-10-20)

- Capture-silence fix: regression [39391950466](https://github.com/lsy223622/HearPort/actions/runs/39391950466) → fixed Actions [39392343378](https://github.com/lsy223622/HearPort/actions/runs/39392343378) (187 Swift) & CodeQL passed.
- Configurable live compression `21b3848312e16aa652c55704991839502698feee`: Windows [39386364549](https://github.com/lsy223622/HearPort/actions/runs/39386364549), iPad [39386215008](https://github.com/lsy223622/HearPort/actions/runs/39386215008) (186 Swift, build **165**), & CodeQL passed.

### Compression test candidate evidence (2026-10-20)

- Source `53de0cd7eefa0afd9e63f549b50439c023172b51`: Windows [39360465692](https://github.com/lsy223622/HearPort/actions/runs/39360465692) (23 CTest, 28 Python), iPad [39360464729](https://github.com/lsy223622/HearPort/actions/runs/39360464729) (179 Swift, build **162**), & CodeQL passed.
- Physical build 162 completed 32 USB + 32 LAN music rounds (target 225 ms / max 300 ms, 60 s/round, zero decode failures, iPad Opus p99 decode <0.50 ms; raw reports remain local; procedure: [compression-tests.md](compression-tests.md)).

### Baseline release candidate (2026-10-18)

- Source `35f00d8c5adfdb6e27d724daaff6677b0172abfb`: Windows [39052133439](https://github.com/lsy223622/HearPort/actions/runs/39052133439) (22 CTest, 6 package checks) & iPad [39052135647](https://github.com/lsy223622/HearPort/actions/runs/39052135647) (156 Swift, unsigned build **158**) passed; extracted Windows package loaded all 4 runtime DLLs locally on the dev PC.

</details>
